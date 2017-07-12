package Pingmachine::Order;

# This module represents a single Pingmachine order description.
# It also responsible for creating/updating the corresponding RRD file

use Any::Moose;
use Any::Moose '::Util::TypeConstraints';
use IO::Socket;
use AnyEvent::Util qw(fh_nonblocking);
use AnyEvent;
use Log::Any qw($log);
use RRDs;
use File::Path;
use File::Temp qw(tempfile);
use File::Copy qw(move);
use YAML::XS qw(LoadFile);
use InfluxDB::LineProtocol qw(data2line);

use Pingmachine::Config;
use Pingmachine::Order::FPing;
use Pingmachine::Order::SSH;

has 'id' => (
    isa => 'Str',
    is  => 'ro',
    required => 1
);

has 'user' => (
    isa => 'Str',
    is  => 'ro',
    required => 1
);

has 'step' => (
    isa => 'Int',
    is  => 'ro',
    required => 1
);

has 'pings' => (
    isa => 'Int',
    is  => 'ro',
    required => 1
);

has 'probe' => (
    isa => 'Str',
    is  => 'ro',
    required => 1
);

has 'rrd_template' => (
    isa => 'Str',
    is  => 'ro',
    default => sub { return "smokeping" },
    # other values: norrd
);

has 'order_file' => (
    isa => 'Str',
    is => 'ro',
    required => 1,
);

has 'telegraf_file' => (
    isa => 'Str',
    is => 'ro',
);

has 'telegraf' => (
    isa => 'HashRef',
    is => 'ro',
    default  => sub { return {} },
);

has 'my_output_dir' => (
    isa => 'Str',
    is => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;
        return Pingmachine::Config->output_dir . '/' . $self->id
    },
);

has 'my_archive_dir' => (
    isa => 'Str',
    is => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;
        return Pingmachine::Config->archive_dir . '/' . $self->id
    },
);

has 'is_archived' => (
    isa => 'Bool',
    is => 'ro',
    writer => '_set_is_archived',
    default => sub { return 0 },
);

class_type 'Pingmachine::Order::FPing';
coerce 'Pingmachine::Order::FPing', from 'HashRef',
    via { Pingmachine::Order::FPing->new(%$_) };

has 'fping' => (
    isa => 'Pingmachine::Order::FPing',
    is  => 'ro',
    coerce => 1,
);

class_type 'Pingmachine::Order::SSH';
coerce 'Pingmachine::Order::SSH', from 'HashRef',
    via { Pingmachine::Order::SSH->new(%$_) };

has 'ssh' => (
    isa => 'Pingmachine::Order::SSH',
    is  => 'ro',
    coerce => 1,
);


sub BUILD {
    my $self = shift;
    my $step = $self->step;
    my $pings = $self->pings;

    # Check parameters
    ($step / $pings) >= 1 or
        die "step / pings must be > 1 (step: $step, pings: $pings)";

    # If the order exists in the archive directory, then restore it
    my $archive_dir = $self->my_archive_dir;
    if(-d $archive_dir) {
        $self->unarchive();
    }

    my $outdir = $self->my_output_dir;
    mkpath($outdir) unless -d $outdir;

    $self->_rrd_create() unless $self->rrd_template eq 'norrd';
};

sub nice_name {
    my ($self) = @_;
    if($self->probe eq 'fping') {
        return $self->id . ' (user: ' . $self->user . ', fping: ' . $self->fping->host . ')';
    }
    elsif($self->probe eq 'ssh') {
        return $self->id . ' (user: ' . $self->user . ', ssh: ' . $self->ssh->host . ')';
    }
    else {
        return $self->id . ' (user: ' . $self->user . ')';
    }
}

# This value is used to assign orders to probes. Same key, same probe.
sub probe_instance_key {
    my ($self) = @_;
    my @keys = ( $self->probe, $self->pings, $self->step );
    if($self->probe eq 'fping') {
        push @keys, $self->fping->probe_instance_key;
    }
    if($self->probe eq 'ssh') {
        push @keys, $self->ssh->probe_instance_key;
    }
    return join('|', @keys);
}

sub rrd_filename {
    my ($self) = @_;
    return $self->my_output_dir . '/main.rrd';
}

sub _rrd_create {
    my ($self) = @_;
    my $id = $self->id;
    my $dir = $self->my_output_dir;

    my $rrdfile = $self->rrd_filename;
    return if -f $rrdfile;

    # This is all very Smokeping-inspired
    my $now = int(AnyEvent->now);
    RRDs::create(
        $rrdfile,
        '--start', $now - $now % $self->step - $self->step,
        '--step', $self->step,
        "DS:loss:GAUGE:".(2*$self->step).":0:".$self->pings,
        "DS:median:GAUGE:".(2*$self->step).":0:180",
        (map { "DS:ping${_}:GAUGE:".(2*$self->step).":0:180" } 1..$self->pings),
        (map { "RRA:".(join ":", @{$_}) } @{Pingmachine::Config->rras($self->rrd_template, $self->step)})
    );
     my $ERR=RRDs::error;
     $log->error("error while updating $rrdfile: $ERR") if $ERR;
}

sub add_results {
    my ($self, $rrd_time, $results) = @_;

    if($self->is_archived) {
        $log->debug($self->id.": discarding results for archived order");
        return;
    }

    $log->debug($self->id.": add results") if $log->is_debug();

    $self->_update_telegraf($rrd_time, $results);
    $self->_update_rrd($rrd_time, $results);
    $self->_update_last_results_file($rrd_time, $results);
}

sub _update_rrd {
    my ($self, $rrd_time, $results) = @_;

    return if $self->rrd_template eq 'norrd';

    # This is all very Smokeping-inspired
    my @rtts    = @{$results->{rtts}};
    my $entries = scalar @rtts;
    my $loss    = $self->pings - $entries;
    my $median  = $rtts[int($entries/2)]; defined $median or $median = 'U';
    my $lowerloss = int($loss/2);
    my $upperloss = $loss - $lowerloss;
    @rtts = ((map {'U'} 1..$lowerloss),@rtts, (map {'U'} 1..$upperloss));
    my $rrdfile = $self->rrd_filename;
    RRDs::update($rrdfile, "$rrd_time:${loss}:${median}:".(join ":", @rtts));
    my $ERR=RRDs::error;
    if ( $ERR ) {
        if ( $ERR =~ m/main\.rrd\'\sis\snot\san\sRRD\sfile/xms ) {
            # special case:
            #  RRD file is corrupted

            # new filename to store the corrupted version for later analysis
            my $corrupted = $rrdfile;
            $corrupted     =~ s/main\.rrd/corrupted_main\.rrd/;

            move( $rrdfile, $corrupted )
              or $log->error("could not move corrupted $rrdfile: $!");

            # create a new rrd file
            $self->_rrd_create();

            $log->info("detected corrupted RRD file $rrdfile and moved it to create a new RRD file.");
        }
        else {
            # default error handling: just report it
            $log->error("error while updating $rrdfile: $ERR");
        }
    }
}

sub _update_last_results_file {
    my ($self, $rrd_time, $results) = @_;

    # Also add a file with the raw last results
    my $fh;
    my $last_results_file = $self->my_output_dir . '/last_result';
    my $tmpfile = $last_results_file . '.tmp';
    open($fh, '>', $tmpfile) or do {
        $log->error("can't write $tmpfile: $!");
        return;
    };

    my $now = int(AnyEvent->now);
    my @rtts    = @{$results->{rtts}};
    my $entries = scalar @rtts;
    my $loss    = $self->pings - $entries;
    my $median = defined $rtts[int($entries/2)] ? $rtts[int($entries/2)] : '~';
    my $min = defined $rtts[0] ? $rtts[0] : '~';
    my $max = defined $rtts[$entries-1] ? $rtts[$entries-1] : '~';

    print $fh "time: $rrd_time\n".
              "updated: ".$now."\n".
              "step: ".$self->step."\n".
              "pings: ".$self->pings."\n".
              "loss: ".$loss."\n".
              "min: ".$min."\n".
              "median: ".$median."\n".
              "max: ".$max."\n";
    close($fh);
    unlink($last_results_file);
    rename($tmpfile, $last_results_file) or do {
        $log->error("can't rename $tmpfile to $last_results_file: $!\n");
        return;
    };
}

# Sends messages to telegraf
sub _update_telegraf {
    my ($self, $rrd_time, $results) = @_;

    my @rtts    = @{$results->{pings}};
    my @sorted_rtts    = @{$results->{rtts}};
    my $all_pings = scalar @rtts;
    my $successful_pings = scalar @sorted_rtts;
    my $loss    = 100.0*($all_pings - $successful_pings)/$all_pings;
    my $median = $rtts[int($successful_pings/2)]; # will be undef if empty
    my $min = $sorted_rtts[0]; # will be undef if empty
    my $max = pop @sorted_rtts; # will be undef if empty
    my $step = $self->step;

    if ($self->telegraf->{'measurement_name'} && Pingmachine::Config->get_telegraf) {
        my ($telegraf_host, $telegraf_port) = Pingmachine::Config->get_telegraf;
        my $measurement_name = $self->telegraf->{'measurement_name'};
        my $tags = $self->telegraf->{'tags'};

        # Create the socket.
        my $telegraf_socket = new IO::Socket::INET(
            PeerAddr => $telegraf_host,
            PeerPort => $telegraf_port,
            Proto    => 'udp',
            Type     => IO::Socket::SOCK_DGRAM,
            Blocking => 0,
        )  or die("Can't open UDP socket: $@");

        # set our socket to non blocking mode
        AnyEvent::Util::fh_nonblocking($telegraf_socket, 1);

        my $result_rrd_time = sprintf("%d%09d", $rrd_time , ($rrd_time - int($rrd_time)) * 1_000_000_000); # nanoseconds time conversion required by InfluxDB::LineProtocol

        # undef will be casted to empty string which will mess up the influx schema definition
        # so only select the defined fields
        my $fields = {};
        $fields->{median_rtt} = sprintf("%f", $median) if defined $median;
        $fields->{min_rtt}    = sprintf("%f", $min)    if defined $min;
        $fields->{max_rtt}    = sprintf("%f", $max)    if defined $max;
        $fields->{loss}       = sprintf("%f",$loss)    if defined $loss;

        my $influx_line = data2line($measurement_name, $fields, $tags, $result_rrd_time);
        $telegraf_socket->send($influx_line,0) or die("Cannot send message");

        for my $i (0..$all_pings-1) {
            my $time = $rrd_time + $step * $i / $all_pings;
            my $result_time = sprintf("%d%09d", $time , ($time - int($time)) * 1_000_000_000);

            next if (! $rtts[$i]);
            $influx_line = data2line($measurement_name, { individual_rtt => $rtts[$i]}, $tags, $result_time);

            $telegraf_socket->send($influx_line,0) or die("Cannot send message");
        }
    }
}


sub archive {
    my ($self) = @_;
    return if $self->is_archived();
    $self->_set_is_archived(1);

    my $archive_dir = $self->my_archive_dir;
    rename($self->my_output_dir, $archive_dir) or
        $log->error("can't archive output to directory $archive_dir: $!");
}

sub unarchive {
    my ($self) = @_;
    $self->_set_is_archived(0);
    my $archive_dir = $self->my_archive_dir;
    -d $archive_dir or return;

    # revive output directory
    if(! -d $self->my_output_dir) {
        if(rename($archive_dir, $self->my_output_dir)) {
            $log->info("revived archived order: ".$self->nice_name);
        }
        else {
            $log->error("can't restore output directory from $archive_dir to ".
                        $self->my_output_dir.": $!");
        }
    }
    else {
        $log->error("can't restore output directory from $archive_dir to ".
                    $self->my_output_dir.": directory exists");
    }
}

#sub DEMOLISH {
#    my ($self) = @_;
#    $log->debug("order garbage collected: ".$self->id);
#}

__PACKAGE__->meta->make_immutable;

1;

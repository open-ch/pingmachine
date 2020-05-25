package Pingmachine::Probe::PPing;

use Any::Moose;
use AnyEvent;
use AnyEvent::Util;
use Log::Any qw($log);
use List::Util qw(shuffle);

my $SCION_DIR = $ENV{'SC'} // '/home/scion/go/src/github.com/scionproto/scion';
my $PPING_BIN = "$SCION_DIR/bin/pingpong";

my $TIMEOUT   = 3000; # -t option (in ms)
my $MIN_WAIT  =    1; # -i option (is ms)

has 'name' => (
    is => 'ro',
    isa => 'Str',
    default => sub { "pping" },
);

has 'max_orders' => (
    is => 'ro',
    isa => 'Int',
    default => 1000,
);

has 'results' => (
    is => 'ro',
    isa => 'HashRef',
    default => sub { {} },
);

has 'current_job' => (
    is => 'rw',
    isa => 'HashRef',
);

has 'interval' => (
    is => 'ro',
    isa => 'Int',
);

has 'source_ip' => (
    is  => 'ro',
    isa => 'Str',
);

has 'flags' => (
    is  => 'ro',
    isa => 'Str',
);

has 'interface' => (
    is  => 'ro',
    isa => 'Str',
);

has 'ipv6' => (
    is  => 'ro',
    isa => 'Bool',
    default => 0,
);

with 'Pingmachine::Probe';

sub _start_new_job {
    my ($self) = @_;

    # We want to distribute the samples as homogeneously as possible in the
    # available $step time (to increase the probability of detecting periodic
    # problems and to decrease the network peak load).
    # - We wait for at least 1 seconds for each ping ($interval).
    # - We can instruct pping to distribute the pings (pping -interval parameter).
    #   That parameter also determines the maximal wait time, so we
    #   can have at most $step/$interval pings if we ping a single
    #   host.
    # - If multiple hosts are pinged, then we need also to consider the $MIN_WAIT
    #   (pping -timeout) parameter.
    # - The total time needed by pping is (assuming $hostcount*MIN_WAIT < $interval):
    #     ($pings-1)*interval + *$hostcount*$MIN_WAIT + $TIMEOUT

    my $step  = $self->step;
    my $pings = $self->pings;
    my $hostcount = $self->order_list->count;

    return unless $hostcount;

    # Determine $interval (pping -interval)
    my $interval; # interval applies only to periods between pings in series (pping -interval, -c != 1)
    if($self->interval) {
        $interval = $self->interval;
    }
    else {
        $interval = int(($step * 1000 * 0.8 - $hostcount*$MIN_WAIT - $TIMEOUT) / $pings);
        $interval >= 1000 or
            die "pping: calculated interval too small: $interval (step = $step, pings = $pings)\n";
    }


    # Make sure that we can process all hosts
    if($interval / $hostcount < $MIN_WAIT) {
        die "pping: step * 1000 / (pings * hostcount) must be at least 10 (step=$step, pings=$pings, hostcount=$hostcount\n";
    }

    # Prepare job
    my %job = (
        host2order => {},
        output     => '',
        effective_cmd => '',
        pid        => '',
    );
    for my $order ($self->order_list->get_all) {
        my $host = $order->pping->host;
        push @{$job{host2order}{$host}}, $order;
    }
    $job{hostlist} = join("\n", shuffle keys %{$job{host2order}}) . "\n",
    $self->current_job(\%job);

    # Run pingpong
    my $single_host = substr $job{hostlist}, 0, -1;
    $log->info("single_host: ".$single_host);
    my @cmd = [
        $PPING_BIN,
        '-id', 'pingpong_client',
        '-mode', 'client',
        '-interval', $interval.'ms',
        '-count', $pings,
        '-timeout', $TIMEOUT.'s',
        '-format', '"%[3]s : %[5]s"',
        '-remote', $single_host,
        '-local', $self->source_ip,
        '-aggregate',
    ];
    # Policy and performance flags
    push @cmd, $self->flags;
    #
    my $cmd_string = "cd $SCION_DIR && ".join(' ', @cmd);
    my $effective_cmd = [ 'su', 'scion', '-c', $cmd_string ];
    $job{effective_cmd} = join(' ', @$effective_cmd);
    $log->debug("starting: @cmd (step: $step, pings: $pings, offset: ".$self->time_offset().")") if $log->is_debug();

    my $cv = run_cmd $effective_cmd,
        '2>', '/dev/null',
        '>', \$job{output},
        '$$', \$job{pid};

    # Install pping exit callback
    $cv->cb(
        sub {
            my $cbv = shift;
            $job{pid} = undef;
            my $exit = $cbv->recv;
            $exit = $exit >> 8;
            if($exit and $exit != 1 and $exit != 2) {
                # exit 1 means that some hosts aren't reachable
                # exit 2 means "any IP addresses were not found"
                $log->warning("pping seems to have failed (exit: $exit, stderr: ".$job{output}.")");
                return;
            }

            $log->debug("finished: @cmd (step: $step, pings: $pings, offset: ".$self->time_offset().")") if $log->is_debug();

            $self->_collect_current_job();

            $log->debug("collected: @cmd (step: $step, pings: $pings, offset: ".$self->time_offset().")") if $log->is_debug();
        }
    );
}

sub _kill_current_job {
    my ($self) = @_;

    # Kill pping, if still running
    my $job = $self->current_job;
    my $job_pid = $job->{pid};
    if($job_pid) {
        # Check that we are killing the process we started and not an innocent bystander
        my $cmd_match = 0;
        if (open(proc_fh, "/proc/${job_pid}/cmdline")) {
            $cmd_match = (join('', readline(proc_fh)) eq $job->{effective_cmd});
            close(proc_fh);
        }
        if($cmd_match && kill(0, $job->{pid})) {
            $log->warning("killing unfinished pping process (step: ".$self->step.", pings: ".$self->pings.", offset: ".$self->time_offset().")");
            kill 9, $job->{pid};
            $job->{pid} = undef;
        }
        elsif($job->{output}) {
            $log->warning("pping has finished, but we didn't notice... collecting (step: ".$self->step.", pings: ".$self->pings.", offset: ".$self->time_offset.")");
            $self->_collect_current_job();
        }
        else {
            $log->warning("pping has finished, but we didn't notice... no output found (?)");
        }
    }
}

sub _collect_current_job {
    my ($self) = @_;

    my $job = $self->current_job;
    $self->current_job({});
    my %results;

    # Do nothing, if pping didn't run yet or if job has been already collected
    return unless $job->{output};

    # Parse pping report
    my $text = $job->{output};
    $log->info("Output to parse: text: ".$text."--");
    while($text !~ /\G\z/gc) {
        if($text =~ /\G(\S+)[ \t]+:/gc) {
            my $host = $1;
            my @data;
            while($text =~ /\G[ \t]+([-\d\.]+)/gc) {
                push @data, $1;
            }
            # raw ping times
            my @pings = map {$_ eq '-' ? undef : $_ / 1000} @data;
            $results{$host}{pings} = \@pings;
            # sorted rtt times
            my @rtts = map {sprintf "%.6e", $_ / 1000} sort {$a <=> $b} grep /^\d/, @data;
            $results{$host}{rtts} = \@rtts;
            $log->info("adding results: rtts: ".join(" ", @rtts));
        }

        # discard any other output on the line (ICMP host unreachable errors, etc.)
        $text =~ /\G.*\n/gc;
    }

    $log->debug("adding results") if $log->is_debug();

    # Add results (to RRD)
    if(scalar keys %results) {
        my $now = int(AnyEvent->now);
        my $step = $self->step;
        my $rrd_time = $now - $step - $now%$step;
        for my $host (keys %results) {
            my $h2o = $job->{host2order}{$host};
            unless ($h2o) {
                $log->warning("pping produced results for unknown host (host: $host, step: $step)");
                next;
            }
            for my $order (@{$h2o}) {
                $order->add_results($rrd_time, $results{$host});
            }
        }
    }

    $log->debug("adding results finished") if $log->is_debug();
}


sub run {
    my ($self) = @_;

    $self->_kill_current_job();
    $self->_start_new_job();
}

__PACKAGE__->meta->make_immutable;

1;

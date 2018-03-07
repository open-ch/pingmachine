package Pingmachine::Probe::SSH;

# NOTE: this probe is a bit special because:
# 1. It doesn't support pings values > 1
# 2. It doesn't measure RTT (only loss)
# Improvements welcome...

use Any::Moose;
use AnyEvent;
use AnyEvent::Util;
use Log::Any qw($log);
use List::Util qw(shuffle);
use XML::Simple;

my $NMAP_BIN    = '/bin/nmap';
my $SSH_TIMEOUT = 20;

has 'name' => (
    is => 'ro',
    isa => 'Str',
    default => sub { "ssh" },
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

has 'key_type' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

with 'Pingmachine::Probe';


sub _start_new_job {
    my ($self) = @_;

    # Prepare job
    my %job = (
        host2order => {},
        pid    => '',
        stderr => '',
        stdout => '',
    );
    for my $order ($self->order_list->get_all) {
        my $host = $order->ssh->host;
        push @{$job{host2order}{$host}}, $order;
    }
    $job{hostlist} = join("\n", shuffle keys %{$job{host2order}}) . "\n",
    $self->current_job(\%job);

    # Run nmap
    my $cmd = [
        $NMAP_BIN,
        '-sT',          # TCP connect() scanning
        '-v',           # verbose mode to see if host is down
        '-n',           # disable DNS resolution
        '-PN',          # disable host discovery (assume all hosts online)
        '-p',22,
        '--max_rtt_timeout',$SSH_TIMEOUT,
        '-oX','-',      # XML output format
        '-iL','-',      # use stdin to input list
        '-sV',          # enable version detection
        '--version-intensity',4,    # speed up version detection (lower => faster but more inaccurate)
    ];
    $log->debug("starting: @$cmd") if $log->is_debug();

    $job{cmd_cv} = run_cmd $cmd,
        '<', \$job{hostlist},
        '2>', \$job{stderr},
        '>',  \$job{stdout},
        '$$', \$job{pid};

    # Install exit callback
    $job{cmd_cv}->cb(
        sub {
            my $cbv = shift;
            $job{pid} = undef;
            my $exit = $cbv->recv;
            $exit = $exit >> 8;
            if($exit) {
                $log->warning("nmap seems to have failed (exit: $exit, stderr: $job{stderr})");
                return;
            }

            $self->_collect_results();
        }
    );
}

sub _kill_current_job {
    my ($self) = @_;

    # Kill ssh-keyscan, if still running
    my $job = $self->current_job;
    if($job->{pid}) {
        $log->warning("killing unfinished nmap process");
        $job->{killed} = 1;
        kill 9, $job->{pid};
        $job->{pid} = undef;
    }
}

sub _collect_results {
    my ($self) = @_;

    my $job = $self->current_job;

    # Do nothing, if the job was killed (we might miss some entries)
    return if $job->{killed};

    # Do nothing, if ssh-keyscan didn't run yet or if job has been already collected
    my $stdout = $job->{stdout};
    return unless defined $stdout;

    my $xml_ref = XMLin($stdout);

    # Process XML output
    my %results;
    foreach my $host (@{$xml_ref->{host}}) {
        my $address = $host->{address}{addr};
        my $status  = $host->{ports}{port}{state}{state}  // $host->{status}{state};
        my $product = $host->{ports}{port}{service}{product};

        if( $status eq 'open' && $product && $product =~ /SSH/i ) {
            my $ping = $host->{times}{srtt}/1000000;     # convert ns to ms
            $results{$address}{rtts} = [$ping]; # sorted rtts
            $results{$address}{pings} = [$ping]; # raw ping values
        }
        else {
            $results{$address}{pings} = [undef];
            $results{$address}{rtts} = [];
        }
    }

    # Add results
    my $now = int(AnyEvent->now);
    my $step = $self->step;
    my $rrd_time = $now - $step - $now%$step;
    for my $host (keys %{$job->{host2order}}) {
        my $h2o = $job->{host2order}{$host};
        for my $order (@{$h2o}) {
            $order->add_results($rrd_time, $results{$host});
        }
    }

    $job->{stdout} = undef;
}

sub run {
    my ($self) = @_;

    $self->_kill_current_job();
    $self->_start_new_job();
}

sub BUILD {
    my $self = shift;
    my $args = shift;

    if($self->pings != 1) {
    	$log->warning("The 'ssh' probe currently only supports pings=1. Other values will be ignored");
    }

}

__PACKAGE__->meta->make_immutable;

1;

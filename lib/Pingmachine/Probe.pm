package Pingmachine::Probe;

# A probe represents a "pinging" job with a given step. Multiple orders
# with the same probe name and step will be managed by the same probe
# object.

use Any::Moose 'Role';
use Log::Any qw($log);

use Pingmachine::OrderList;
use Pingmachine::Order;

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

has 'time_offset' => (
    isa => 'Int',
    is  => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;
        return int(rand($self->step / ($self->pings+1)));
    },
);

has 'order_list' => (
    isa     => 'Pingmachine::OrderList',
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my $ol = Pingmachine::OrderList->new();
        return $ol;
    },
    handles => {
        add_order => 'add_order',
        remove_order_id => 'remove_order_id',
    }
);

# AnyEvent watchers
has 'run_ae_w' => (
    isa     => 'Object',
    is      => 'rw',
);

requires 'name';
requires 'run';
requires 'max_orders';

# returns the amount of seconds to wait for the next scheduled run
sub _get_next_run_after {
    my $self = shift;

    my $now = AnyEvent->now;
    my $step = $self->step;
    my $time_offset = $self->time_offset;
    my $now_mod = $now % $step;
    if($now_mod < $time_offset) {
        return $time_offset - $now_mod;
    }
    else {
        return $time_offset - $now_mod + $step;
    }
}

sub _schedule_next_run {
    my ($self) = @_;

    $self->run_ae_w(
        AnyEvent->timer (
            after => $self->_get_next_run_after(),
            cb => sub {
                $self->_schedule_next_run();
                $self->run();
            }
        )
    );
}

around 'add_order' => sub {
    my $orig = shift;
    my $self = shift;

    # check that the order has the same step value
    my $order = $_[0];
    defined $order or die "Pingmachine::Probe: must pass order object as argument\n";
    $order->isa('Pingmachine::Order') or die "Pingmachine::Probe: order must be a Pingmachine::Orger object\n";
    $order->step == $self->step or
        die "Pingmachine::Probe: order must have step: ".$order->step."\n";
    $order->pings == $self->pings or
        die "Pingmachine::Probe: order must have pings: ".$order->pings."\n";

    $self->$orig(@_);
};

sub start {
    my $self = shift;

    $self->_schedule_next_run();
    $log->info("started ".$self->name." probe (time offset: ".$self->time_offset.", step: ".$self->step.")");
}

1;

package Pingmachine::OrderList;

use Any::Moose;
use Log::Any qw($log);

# An OrderList object contains orders and is responsible for the correct
# book-keeping. It is filled by OrdersWatcher.

# Note: we don't use a native trait here, because it doesn't perform well :-(
has '_orders' => (
    isa      => 'HashRef',
    is       => 'ro',
    default  => sub { return {} },
);

has '_add_order_cb' => (
    traits   => ['Array'],
    isa      => 'ArrayRef[CodeRef]',
    is       => 'ro',
    default  => sub { return [] },
    handles  => {
        register_add_order_cb => 'push',
    },
);

has '_remove_order_cb' => (
    traits   => ['Array'],
    isa      => 'ArrayRef[CodeRef]',
    is       => 'ro',
    default  => sub { return [] },
    handles  => {
        register_remove_order_cb => 'push',
    },
);

sub has_order {
    my ($self, $order_id) = @_;
    return exists $self->{_orders}{$order_id};
}

sub count {
    my ($self) = @_;
    return scalar keys %{$self->{_orders}};
}

sub list {
    my ($self) = @_;
    return keys %{$self->{_orders}};
}

sub get_all {
    my ($self) = @_;
    return values %{$self->{_orders}};
}

sub get_order {
    my ($self, $order_id) = @_;
    return $self->{_orders}{$order_id};
}

sub add_order {
    my ($self, $order) = @_;
    my $order_id = $order->id;

    # Skip, if already known
    if($self->has_order($order_id)) {
        return;
    }
    
    # Store order
    $self->{_orders}{$order_id} = $order;

    # Run callbacks
    for my $cb (@{$self->_add_order_cb}) {
        $cb->($order);
    }
}

sub remove_order_id {
    my ($self, $order_id) = @_;

    my $order = $self->get_order($order_id);
    return unless defined $order;

    delete $self->{_orders}{$order_id};

    # run callbacks
    for my $cb (@{$self->_remove_order_cb}) {
        $cb->($order);
    }
}

__PACKAGE__->meta->make_immutable;

1;

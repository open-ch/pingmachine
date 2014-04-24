package Pingmachine::Order::FPing;

use Any::Moose;

has 'host' => (
    isa => 'Str',
    is  => 'ro',
    required => 1,
);

has 'source_ip' => (
    isa => 'Str',
    is  => 'ro',
);

has 'interface' => (
    isa => 'Str',
    is  => 'ro',
);

has 'interval' => (
    isa => 'Int',
    is  => 'ro',
);

sub probe_instance_key {
    my ($self) =@_;

    my @keys;
    push (@keys, "interval:$self->fping->interval")   if ($self->interval);
    push (@keys, "source_ip:$self->fping->source_ip") if ($self->source_ip);
    push (@keys, "interface:$self->fping->interface") if ($self->interface);
    scalar @keys or @keys = ('');

    return join('|', @keys);
}

__PACKAGE__->meta->make_immutable;

1;

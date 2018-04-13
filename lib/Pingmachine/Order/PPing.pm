package Pingmachine::Order::PPing;

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

has 'ipv6' => (
    isa => 'Bool',
    is  => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;
        return $self->host =~ /^[:0-9a-f]+$/i;
    },
);

sub probe_instance_key {
    my ($self) =@_;

    my @keys;
    push (@keys, "interval:".$self->interval)   if ($self->interval);
    push (@keys, "source_ip:".$self->source_ip) if ($self->source_ip);
    push (@keys, "interface:".$self->interface) if ($self->interface);
    push (@keys, "v6:".$self->ipv6) if ($self->ipv6);
    scalar @keys or @keys = ('');

    return join('|', @keys);
}

__PACKAGE__->meta->make_immutable;

1;

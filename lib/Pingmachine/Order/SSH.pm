package Pingmachine::Order::SSH;

use Any::Moose;

has 'host' => (
    isa => 'Str',
    is  => 'ro',
    required => 1,
);

has 'key_type' => (
    isa => 'Str',
    is  => 'ro',
    required => 1,
);

sub probe_instance_key {
    my ($self) = @_;
    return $self->key_type;
}

__PACKAGE__->meta->make_immutable;

1;

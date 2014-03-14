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

__PACKAGE__->meta->make_immutable;

1;

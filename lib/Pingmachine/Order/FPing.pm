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

has 'interval' => (
    isa => 'Int',
    is  => 'ro',
);

__PACKAGE__->meta->make_immutable;

1;

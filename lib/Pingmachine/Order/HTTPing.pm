package Pingmachine::Order::HTTPing;

use Any::Moose;

has 'url' => (
    isa => 'Str',
    is  => 'ro',
    required => 1,
);

has 'interval' => (
    isa => 'Int',
    is  => 'ro',
);

has 'user_agent' => (
    isa => 'Str',
    is  => 'ro',
);

has 'proxy' => (
    isa => 'Str',
    is  => 'ro',
);

sub probe_instance_key {
    my ($self) =@_;

    my @keys;
    push (@keys, "interval:".$self->interval)       if ($self->interval);
    push (@keys, "user_agent:".$self->user_agent)   if ($self->user_agent);
    push (@keys, "proxy:".$self->proxy)             if ($self->proxy);
    return join('|', @keys);
}

__PACKAGE__->meta->make_immutable;

1;

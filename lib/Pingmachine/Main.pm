package Pingmachine::Main;

# This modules encapsulates the main program logic.

use Any::Moose;
use Carp;
use AnyEvent;
use Log::Any qw($log);
use Fcntl qw(:flock);
use File::Path;

use Pingmachine::OrderList;
use Pingmachine::OrdersDirWatcher;
use Pingmachine::ProbeList;

# AnyEvent condvar: "Quit now"
has 'ae_quit_cv' => (
    isa     => 'AnyEvent::CondVar',
    is      => 'ro',
    lazy    => 1,
    default => sub { AnyEvent->condvar },
);

# AnyEvent watchers
has 'ae_watchers' => (
    traits  => ['Array'],
    isa     => 'ArrayRef',
    is      => 'ro',
    default => sub { [] },
    handles => {
        add_ae_watcher => 'push',
    },
);

has 'order_list' => (
    isa     => 'Pingmachine::OrderList',
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my $ol = Pingmachine::OrderList->new();
        $ol->register_add_order_cb(sub {
            $self->add_order_cb($_[0]);
        });
        $ol->register_remove_order_cb(sub {
            $self->remove_order_cb($_[0]);
        });
        return $ol;
    },
);

has 'probe_list' => (
    isa    => 'Pingmachine::ProbeList',
    is     => 'ro',
    lazy   => 1,
    default => sub {
        my $self = shift;
        my $ol = Pingmachine::ProbeList->new();
        return $ol;
    },
);

has 'orders_dir_watcher' => (
    isa    => 'Pingmachine::OrdersDirWatcher',
    is     => 'ro',
    writer => '_set_orders_dir_watcher',
);

has 'lock' => (
    is   => 'ro',
    isa  => 'FileHandle',
    lazy => 1,
    default => sub {
        my $lock_fh;
        my $basedir = Pingmachine::Config->base_dir;
        my $lockfile = $basedir . '/' . '.lock';
        open($lock_fh, '>', $lockfile) or
            log_die("can't write lock file $lockfile: $!\n");
        flock($lock_fh, LOCK_NB | LOCK_EX) or
            log_die("can't lock base directory $basedir. Is pingmachine running already?\n");
        return $lock_fh;
    },
);

# log_die: we need this to properly log before the event loop starts
sub log_die {
    $log->fatal("$_[0]");
    exit(1);
}

sub _create_dir_structure {
    # Create needed directories:
    # - orders
    my $orders_dir = Pingmachine::Config->orders_dir;
    mkpath($orders_dir) unless -d $orders_dir;
    # - telegraf
    my $telegraf_dir = Pingmachine::Config->telegraf_dir;
    mkpath($telegraf_dir) unless -d $telegraf_dir;
    # - output
    my $output_dir = Pingmachine::Config->output_dir;
    mkpath($output_dir) unless -d $output_dir;
    # - archive
    my $archive_dir = Pingmachine::Config->archive_dir;
    mkpath($archive_dir) unless -d $archive_dir;
}

sub run {
    my ($self) = @_;

    # Lock
    $self->lock;

    # Create basedir structure
    $self->_create_dir_structure;

    # Install signal watchers for SIGINT and SIGTERM
    $self->add_ae_watcher(
        AnyEvent->signal(signal => "INT",  cb => sub { $self->ae_quit_cv->send() })
    );
    $self->add_ae_watcher(
        AnyEvent->signal(signal => "TERM", cb => sub { $self->ae_quit_cv->send() })
    );

    # Create OrdersDirWatcher object (watches /orders)
    $self->_set_orders_dir_watcher(
        Pingmachine::OrdersDirWatcher->new(order_list => $self->order_list)
    );

    # Log that we started
    $log->info("pingmachine started");
    $self->update_process_name();

    # Enter event loop
    $self->ae_quit_cv->recv();

    # Log that we stopped
    $log->info("pingmachine stopped");
}

sub add_order_cb {
    my ($self, $order) = @_;

    $log->info("new order: ".$order->nice_name);
    $self->probe_list->add_order($order);
    $self->update_process_name();
}

sub remove_order_cb {
    my ($self, $order) = @_;

    $log->info("removed order: ".$order->nice_name);
    $self->probe_list->remove_order($order);
    $self->update_process_name();
}

sub update_process_name {
    my ($self) = @_;
    $0 = "pingmachine [orders: ".$self->order_list->count."]";
}

__PACKAGE__->meta->make_immutable;

1;

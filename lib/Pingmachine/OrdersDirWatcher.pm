package Pingmachine::OrdersDirWatcher;

# This module is responsible for monitoring the /orders directory and
# adding/removing orders, as necessary.

### NOTE NOTE NOTE: The fancy inotify support is disabled for now, because I presume stability
###                 issues to be related to it (being so fancy and all :-))
###                 The consequence is that new order get noticed with up to 30 seconds delay
###                 -- dws@open.ch, 2012-01-17

use Any::Moose;
use AnyEvent;
use Log::Any qw($log);
use Try::Tiny;
use YAML::XS qw(LoadFile);

use Pingmachine::Config;
use Pingmachine::Order;
use Pingmachine::OrderList;

my $RESCAN_PERIOD = 30; # full rescan every 30 seconds (just to be sure, shouldn't be needed..)
my $ORDER_NAME_RE = qr|^([0-9a-f]+/?)+$|; # one or more hex dirs separated by '/'

has 'orders_dir' => (
    isa      => 'Str',
    is       => 'ro',
    default  => sub {
        return Pingmachine::Config->orders_dir;
    },
);

has 'telegraf_dir' => (
    isa      => 'Str',
    is       => 'ro',
    default  => sub {
        return Pingmachine::Config->telegraf_dir;
    },
);

has 'order_list' => (
    isa      => 'Pingmachine::OrderList',
    is       => 'ro',
    required => 1,
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

sub BUILD {
    my $self = shift;
    my $args = shift;

    $self->_scan_orders_directory();
    #$self->_setup_orders_inotify_watcher();
    $self->_setup_timed_rescan();
}

# scan /orders directory and:
# - remove obsolete orders
# - add new orders
sub _scan_orders_directory {
    my ($self) = @_;
    my %in_directory; # used to track deleted orders
    my $orders_dir = $self->orders_dir;
    my $now = int(AnyEvent->now);

    $self->_scan_orders_directory_recursively($orders_dir, '', $now, \%in_directory);

    for my $order_id ($self->order_list->list) {
        if (not defined $in_directory{$order_id}) {
            $self->_remove_order($order_id);
        }
    }

    return;
}

sub _scan_orders_directory_recursively {
    my ($self, $dir, $order_id_prefix, $now, $in_directory) = @_;
    my $dh;
    opendir($dh, $dir) or die "can't open $dir: $!";
    while (my $file_relative = readdir($dh)) {
        next if $file_relative eq '.' or $file_relative eq '..';

        my $order_id = $order_id_prefix ? "$order_id_prefix/$file_relative" : $file_relative;
        my $file = "$dir/$file_relative";
        if (-d $file) {
            $self->_scan_orders_directory_recursively($file, $order_id, $now, $in_directory);
            next;
        }

        # Archive file if too old
        my ($mtime) = (lstat($file))[9];
        defined $mtime or do {
            $log->warn("can't stat $file: $!");
            next;
        };
        my $timediff = $now - $mtime;
        my $max_age = Pingmachine::Config->orders_max_age;
        if($timediff > $max_age) {
            $log->info("archiving old order: $order_id (age: ${timediff}s)");
            if($self->order_list->get_order($order_id)) {
                $self->_remove_order($order_id);
            }
            else {
                my $order = $self->_parse_order($order_id, $self->orders_dir . '/' . $order_id, $self ->telegraf_dir . '/' . $order_id);
                $order->archive($order_id) if $order;
            }
            unlink($file);
            next;
        }

        # Add order
        $self->_add_order($order_id);
        $in_directory->{$order_id} = 1;
    }

    closedir($dh);
    return;
};


sub _parse_order {
    my ($self, $order_id, $order_file, $telegraf_file) = @_;

    my $order;
    try {
        my $order_def = LoadFile($order_file);
        $order_def->{id} = $order_id;
        $order_def->{order_file} = $order_file;
        if (-e $telegraf_file) {
            $order_def->{telegraf_file} = $telegraf_file;
            try {
                $order_def->{telegraf} = LoadFile($telegraf_file);
            }
            catch {
                my $error = $_;
                chomp $error;
                unlink $telegraf_file;
                $log->warning("unable to load telegraf file $telegraf_file ($error). It has been deleted as it was most likely corrupt.");
            }
        }
        $order = Pingmachine::Order->new($order_def);
    }
    catch {
        my $error = $_;
        chomp $error;
        unlink $order_file;
        $log->warning("unable to load order file $order_file ($error). It has been deleted as it was most likely corrupt.");
    };
    return $order;
}

sub _add_order {
    my ($self, $order_id) = @_;

    # Skip it, if already known
    return if $self->order_list->has_order($order_id);

    # Skip it, if it doesn't look like a order file
    $order_id =~ $ORDER_NAME_RE or do {
    $log->notice("skipping file in orders directory: $order_id");
    return;
    };

    # Parse
    my $order = $self->_parse_order($order_id, $self ->orders_dir . '/' . $order_id, $self ->telegraf_dir . '/' . $order_id);
    return unless $order;

    # Add order to list
    $self->order_list->add_order($order);
}


sub _remove_order {
    my ($self, $order_id) = @_;

    my $order = $self->order_list->get_order($order_id);
    return unless defined $order;

    # Archive order
    $order->archive();

    # Remove from list
    $self->order_list->remove_order_id($order_id);
}

## watch /orders directory for added/deleted files
#sub _setup_orders_inotify_watcher {
#    my ($self) = @_;
#
#    my $inotify = new Linux::Inotify2
#        or die "unable to create new inotify object: $!";
#    $inotify->watch(
#        $self->orders_dir,
#        IN_CLOSE_WRITE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO,
#        sub {
#            my $e = shift;
#            if($e->IN_CLOSE_WRITE or $e->IN_MOVED_TO) {
#                $self->_add_order($e->name) if -f $self->orders_dir . '/' . $e->name;
#            }
#            elsif($e->IN_DELETE or $e->IN_MOVED_FROM) {
#                $self->_remove_order($e->name);
#            }
#        }
#    );
#
#    $self->add_ae_watcher(
#        AnyEvent->io(
#            fh => $inotify->fileno,
#            poll => 'r',
#            cb => sub { $inotify->poll }
#        )
#    );
#}

# we don't trust inotify completely, so schedule a full directory scan
# every once in a while
sub _setup_timed_rescan {
    my ($self) = @_;

    $self->add_ae_watcher(
        AnyEvent->timer(
            after => $RESCAN_PERIOD,
            interval => $RESCAN_PERIOD,
            cb => sub {
                $self->_scan_orders_directory();
            }
        )
    );
}

__PACKAGE__->meta->make_immutable;

1;

#!/usr/bin/perl -w

# This example scripts shows how to use Pingmachine so that you get an immediate feedback
# about ping results (to react as soon as possible)
#
# Note that it is rather complicated, because of that requirements (immediate
# notification). You shouldn't do this, unless you need to...

use strict;
use AnyEvent;
use EV;
use Linux::Inotify2;
use Digest::MD5 qw(md5_hex);
use YAML::XS qw(LoadFile);
use POSIX qw(strftime);

my $step = 1; # write results every $step interval
my $ping_ip = '8.8.8.8';

my $orders_dir  = '/var/lib/pingmachine/orders';
my $output_base = '/var/lib/pingmachine/output';

### write_order: Write the Pingmachine order file
###
my $order_w; # We would use 'state' for this, if we had Perl >= 5.10...
my $order_id;
sub write_order {
    # Write order file
    my $order = <<END;
user: example
task: $ping_ip
step: $step
pings: 1
probe: fping
fping:
    host: $ping_ip
END
    $order_id = md5_hex($order);
    my $order_file = $orders_dir . "/$order_id";
    my $fh;
    open($fh, '>', $order_file) or
        die "ERROR: can't write $order_file: $!\n";
    print $fh $order;
    close($fh);

    # Schedule a rewrite of the file
    # (so that pingmachine doesn't delete it)
    $order_w = AnyEvent->timer(
        after => 300,
        cb => sub { write_order(); }
    );

    return $output_base . "/$order_id";
}

### remove_order: Remove the order file, when we quit
###   (note that Pingmachine removes it for us after one hour that we didn't
###   refresh it, but we do it anyway for neatiness)
###
sub remove_order {
    unlink $orders_dir . "/$order_id";
}

### watch_output: Watch output directory for new "last_result" file.
###   (note that Pingmachine creates a tempory file and then
###   renames (moves) it to "last_results")
my $watch_output_w;
sub watch_output {
    my ($output_dir) = @_;
    my $inotify = Linux::Inotify2->new() or
        die "ERROR: Unable to create new inotify object: $!";
    $inotify->watch("$output_dir",
        IN_MOVED_TO,
        sub {
            my $e = shift;
            $e->name eq 'last_result' or return;
            read_result($e->fullname);
        }
    );
    $watch_output_w = AnyEvent->io(
        fh => $inotify->fileno,
        poll => 'r',
        cb => sub { $inotify->poll }
    );
}

### read_result: Called when last_result has been updated by Pingmachine
###
sub read_result {
    my ($file) = @_;
    my $results = LoadFile($file);

    printf("%-15s %-15s %s\n",
        strftime("%H:%M:%S", localtime($results->{updated})),
        strftime("%H:%M:%S", localtime(time)),
        $results->{median}
    );
}

### main: Main routine
###   (because I don't like having things in the root scope)
###
sub main {
    my $output_dir = write_order();

    # Install signal watchers for SIGINT and SIGTERM 
    my $quit_cv = AnyEvent->condvar;
    my $w1 = AnyEvent->signal(signal => "INT",  cb => sub { $quit_cv->send() });
    my $w2 = AnyEvent->signal(signal => "TERM",  cb => sub { $quit_cv->send() });

    # Install output directory watcher
    watch_output($output_dir);

    # Write header
    printf("%-15s %-15s %s\n", "Sample time", "Now", "RTT");

    # Start event loop 
    $quit_cv->recv;

    # Quitting -> remove order file
    remove_order();
}

main;

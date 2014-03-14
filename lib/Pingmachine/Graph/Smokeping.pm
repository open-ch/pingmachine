package Pingmachine::Graph::Smokeping;

# Parts of this code are derived from Smokeping, with the
# following license text:
#
# This program is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public
# License as published by the Free Software Foundation; either
# version 2 of the License, or (at your option) any later
# version.
# 
# This program is distributed in the hope that it will be
# useful, but WITHOUT ANY WARRANTY; without even the implied
# warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
# PURPOSE.  See the GNU General Public License for more
# details.
# 
# You should have received a copy of the GNU General Public
# License along with this program; if not, write to the Free
# Software Foundation, Inc., 675 Mass Ave, Cambridge, MA
# 02139, USA.


use strict;
use RRDs;
use Params::Validate qw(validate);
use Smokeping::Colorspace;

# helper package to produce Smokeping-like graphs

sub _get_loss_colors {
    my ($pings) = @_;
    return {
        0          => ['0',   '#26ff00'],
        1          => ["1/$pings",  '#00b8ff'],
        2          => ["2/$pings",  '#0059ff'],
        3          => ["3/$pings",  '#5e00ff'],
        4          => ["4/$pings",  '#7e00ff'],
        int($pings/2)  => [int($pings/2)."/$pings", '#dd00ff'],
        $pings-1       => [($pings-1)."/$pings",    '#ff0000'],
    };
}

sub _get_loss_bg_colors {
    my ($pings) = @_;
    my $lc = _get_loss_colors($pings);
    my %lcback;
    foreach my $key (keys %$lc) {
        if ($key == 0) {
            $lcback{$key} = "";
            next;
        }
        my $web = $lc->{$key}[1];
        my @rgb = Smokeping::Colorspace::web_to_rgb($web);
        my @hsl = Smokeping::Colorspace::rgb_to_hsl(@rgb);
        $hsl[2] = (1 - $hsl[2]) * (2/3) + $hsl[2];
        @rgb = Smokeping::Colorspace::hsl_to_rgb(@hsl);
        $web = Smokeping::Colorspace::rgb_to_web(@rgb);
        $lcback{$key} = $web;
    }
    return \%lcback;
}

sub _findmax {
    my ($rrd, $timespan) = @_;

    # fetch max of median ping
    my ($graphret,$xs,$ys) = RRDs::graph(
        "dummy",
        '--start', -$timespan,
       "DEF:maxping=${rrd}:median:AVERAGE",
       'PRINT:maxping:MAX:%le'
    );
    my $ERR=RRDs::error; die "Error while graphing $rrd: $ERR\n" if $ERR;
    my $val = $graphret->[0];
    $val = 0 if $val =~ /nan/i;

    return $val * 1.3; # leave about 20% space above the maximum median, so
                       # that we have some room to show the smoke
}

sub _smokecol {
    my $count = shift;
    return [] unless $count > 2;
    my $half = $count/2;
    my @items;
    my $itop=$count;
    my $ibot=1;
    for (; $itop > $ibot; $itop--,$ibot++){
        my $color = int(190/$half * ($half-$ibot))+50;
        push @items, "CDEF:smoke${ibot}=cp${ibot},UN,UNKN,cp${itop},cp${ibot},-,IF";
        push @items, "AREA:cp${ibot}";
        push @items, "STACK:smoke${ibot}#".(sprintf("%02x",$color) x 3);
    };
    return \@items;
}

sub _graph_all {
    my ($p, $max) = @_;

    my $lc = _get_loss_colors($p->{pings});
    my $lcback = _get_loss_bg_colors($p->{pings});

    my @g;
    my @aftersmoke;

    # Median value
    push @g, "VDEF:avmed=median,AVERAGE";
    push @g, 'GPRINT:median:LAST:Median RTT   Current\: %.1lf %ss\t';
    push @g, 'GPRINT:median:MAX:Max\: %.1lf %ss\t';
    push @g, 'GPRINT:avmed:Average\: %.1lf %ss\l';
    push @g, "LINE1:median#202020";

    # Loss value
    push @g, "CDEF:ploss=loss,$p->{pings},/,100,*";
    push @g, 'GPRINT:ploss:LAST:Packet Loss  Current\: %.2lf %%\t';
    push @g, 'GPRINT:ploss:MAX:Max\: %.2lf %%\t';
    push @g, 'GPRINT:ploss:AVERAGE:Average\: %.2lf %% \l';
    push @g, 'COMMENT:Packet Loss';

    my $last = -1;
    foreach my $loss (sort {$a <=> $b} keys %$lc){
        next if $loss >= $p->{pings};
        my $lvar = $loss; $lvar =~ s/\./d/g ;

        # Median color (loss)
        my $yscale = $max / $p->{height};
        push @aftersmoke, "CDEF:me$lvar=loss,$last,GT,loss,$loss,LE,*,1,UNKN,IF,median,*";
        push @aftersmoke, "CDEF:meL$lvar=me$lvar,$yscale,-";
        push @aftersmoke, "CDEF:meH$lvar=me$lvar,0,*,$yscale,2,*,+";
        push @aftersmoke, "AREA:meL$lvar";
        push @aftersmoke, "STACK:meH$lvar$lc->{$loss}[1]:$lc->{$loss}[0]";

        # Background color (loss)
        push @g, "CDEF:lossbg$lvar=loss,$last,GT,loss,$loss,LE,*,INF,UNKN,IF";
        push @g, "AREA:lossbg$lvar$lcback->{$loss}";

        push @aftersmoke,
            "CDEF:lossbgs$lvar=loss,$last,GT,loss,$loss,LE,*,cp2,UNKN,IF";
        push @aftersmoke,
            "AREA:lossbgs$lvar$lcback->{$loss}";

        $last = $loss;
    }


    # Smoke
    my $smoke = $p->{pings} >= 3 ? _smokecol $p->{pings} :
      [ 'COMMENT:(Not enough pings to draw any smoke.)\s', 'COMMENT:\s' ];
    push @g, @$smoke;

    # Finish background color
    push @g, @aftersmoke;

    push @g, 'COMMENT: \l';

    return @g;
}

sub graph {
    my $class = shift;
    
    # Validate and extract parameters
    my %p = validate(@_, {
        rrd => 1,
        img => 1,
        timespan => 1,
        pings => 1,
        width => 1,
        height => 1,
        title => 0,
    });

    # Do some needed calculations
    my $max = _findmax($p{rrd}, $p{timespan});

    # Base RRDs::graph parameters
    my @g = (
        '--width', $p{width},
        '--height', $p{height},
        '--alt-y-grid',
        '--rigid',
        '--lower-limit','0',
        '--upper-limit', $max,
        '--start', "-$p{timespan}s",
        '--color', 'SHADEA#ffffff',
        '--color', 'SHADEB#ffffff',
        '--color', 'BACK#ffffff',
        '--color', 'CANVAS#ffffff',
        '--units-exponent', -3,
        "DEF:median=$p{rrd}:median:AVERAGE",
        "DEF:loss=$p{rrd}:loss:AVERAGE",
        (map {"DEF:ping${_}=$p{rrd}:ping${_}:AVERAGE"} 1..$p{pings}),
        (map {"CDEF:cp${_}=ping${_},$max,LT,ping${_},INF,IF"} 1..$p{pings}),
    );
    push @g, '--title', $p{title} if $p{title};

    # Loss
    push @g, _graph_all(\%p, $max);

    # Do the graph
    RRDs::graph(
        $p{img},
        @g,
    );
    my $ERR=RRDs::error; die "Error while graphing $p{rrd}: $ERR\n" if $ERR;
}

1;

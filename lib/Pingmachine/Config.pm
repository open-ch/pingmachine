package Pingmachine::Config;

use strict;

use Log::Any qw($log);

my $_base_dir    = '/var/lib/pingmachine';
my $_orders_dir  = $_base_dir . '/orders';
my $_output_dir  = $_base_dir . '/output';
my $_archive_dir = $_base_dir . '/archive';
my $_orders_max_age = 3660; # 1 hour plus some margin

sub orders_dir     { return $_orders_dir; }
sub output_dir     { return $_output_dir; }
sub archive_dir    { return $_archive_dir; }
sub orders_max_age { return $_orders_max_age; }

sub base_dir {
    my ($class, $value) = @_;
    if(defined $value) {
        $_base_dir    = $value;
        $_orders_dir  = $_base_dir . '/orders';
        $_output_dir  = $_base_dir . '/output';
        $_archive_dir = $_base_dir . '/archive';
    }
    return $_base_dir;
}

sub rras {
    my ($class, $rrd_template, $step) = @_;

    if($rrd_template eq 'smokeping' and $step < 300) {
        return [
            [ 'AVERAGE',  0.5,   1,  900 ],
            
            [ 'AVERAGE',  0.5,   300/$step,  864 ], # 72 hours, 5 min. resolution (day)
            [     'MIN',  0.5,   300/$step,  864 ],
            [     'MAX',  0.5,   300/$step,  864 ],

            [ 'AVERAGE',  0.5,  1800/$step,  480 ], # 10 days, 30 min. resolution (week)
            [     'MIN',  0.5,  1800/$step,  480 ],
            [     'MAX',  0.5,  1800/$step,  480 ],

            [ 'AVERAGE',  0.5,  3600/$step, 960 ], #  40 days, 60 min. resolution (month)
            [     'MIN',  0.5,  3600/$step, 960 ],
            [     'MAX',  0.5,  3600/$step, 960 ],

            [ 'AVERAGE',  0.5,  12*3600/$step, 800 ], # 400 days, 12 h. resolution (year)
            [     'MAX',  0.5,  12*3600/$step, 800 ],
            [     'MIN',  0.5,  12*3600/$step, 800 ],

            [ 'AVERAGE',  0.5, 7*24*3600/$step, 520 ], # 3600 days, 7 d. resolution (10 years)
            [     'MAX',  0.5, 7*24*3600/$step, 520 ],
            [     'MIN',  0.5, 7*24*3600/$step, 520 ],
        ];
    }
    elsif($rrd_template eq 'smokeping' and $step == 300) {
        # tuned RRAs for step 300
        return [
            [ 'AVERAGE',  0.5,   1,  864 ], # 72 hours, 5 min. resolution (day)

            [ 'AVERAGE',  0.5,   6,  480 ], # 10 days, 30 min. resolution (week)
            [     'MIN',  0.5,   6,  480 ],
            [     'MAX',  0.5,   6,  480 ],

            [ 'AVERAGE',  0.5,   12, 960 ], # 40 days, 60 min. resolution (month)
            [     'MIN',  0.5,   12, 960 ],
            [     'MAX',  0.5,   12, 960 ],

            [ 'AVERAGE',  0.5,  144, 800 ], # 400 days, 12 h. resolution (year)
            [     'MAX',  0.5,  144, 800 ],
            [     'MIN',  0.5,  144, 800 ],

            [ 'AVERAGE',  0.5, 2016, 520 ], # 3600 days, 7 d. resolution (10 years)
            [     'MAX',  0.5, 2016, 520 ],
            [     'MIN',  0.5, 2016, 520 ],
        ];
    }
    else {
        $log->warning("Unknown rrd_template/step, using Smokeping defaults (rrd_template: $rrd_template, $step)");
        # Smokeping standard
        return [
            [ 'AVERAGE',  0.5,   1,  1008 ],
            [ 'AVERAGE',  0.5,  12,  4320 ],
            [     'MIN',  0.5,  12,  4320 ],
            [     'MAX',  0.5,  12,  4320 ],
            [ 'AVERAGE',  0.5, 144,   720 ],
            [     'MAX',  0.5, 144,   720 ],
            [     'MIN',  0.5, 144,   720 ],
        ];
    }
};

1;

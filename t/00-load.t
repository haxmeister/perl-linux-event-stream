use strict;
use warnings;
use Test::More tests => 1;
ok(eval { require Linux::Event::Stream; 1 }, 'require Linux::Event::Stream') or diag $@;

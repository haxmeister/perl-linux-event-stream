use v5.36;
use strict;
use warnings;

use Test2::V0;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Linux::Event;
use Linux::Event::Stream;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";

my $loop = Linux::Event->new;

my $got = '';
my $closed = 0;

my $sa = Linux::Event::Stream->new(
  loop => $loop,
  fh   => $a,
  on_read => sub ($s, $bytes, $data) {
    $got .= $bytes;
    if (length($got) >= 5) {
      $s->close;
    }
  },
  on_close => sub ($s, $data) {
    $closed++;
  },
);

# Drain data written by Stream from the other end.
my $drain = '';
my $wb = $loop->watch($b,
  read => sub ($w, $fh, $data) {
    while (1) {
      my $buf = '';
      my $n = sysread($fh, $buf, 8192);
      last if !defined($n) && ($!+0 == 11 || $!+0 == 35 || $!+0 == 10035);
      last if !defined($n);
      last if $n == 0;
      $drain .= $buf;
    }
    # once we see all bytes, stop loop by closing stream
    if (length($drain) >= 5) {
      $sa->close;
    }
  },
);

ok($sa->write("hello"), 'write returns true');

$loop->run;

is($drain, 'hello', 'peer received bytes');
ok($sa->is_closed, 'stream is closed');
is($closed, 1, 'on_close fired once');

done_testing;

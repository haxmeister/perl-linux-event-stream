use v5.36;
use strict;
use warnings;

use Test2::V0;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Linux::Event;
use Linux::Event::Stream;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";

my $loop = Linux::Event->new;

# Very low watermarks to make the test fast.
my $s = Linux::Event::Stream->new(
  loop => $loop,
  fh   => $a,
  high_watermark => 1024,
  low_watermark  => 256,
);

ok(!$s->is_write_blocked, 'starts unblocked');

# Write enough to exceed high watermark.
my $payload = 'x' x 4096;
ok($s->write($payload), 'write large payload');

ok($s->is_write_blocked, 'becomes blocked above high watermark');

my $drain = '';
$loop->watch($b, read => sub ($w, $fh, $data) {
  while (1) {
    my $buf = '';
    my $n = sysread($fh, $buf, 8192);
    last if !defined($n) && ($!+0 == 11 || $!+0 == 35 || $!+0 == 10035);
    last if !defined($n);
    last if $n == 0;
    $drain .= $buf;
  }
  # Stop the loop once drained enough that Stream should drop below low watermark.
  if (length($drain) >= length($payload)) {
    $s->close;
  }
});

$loop->run;

ok(!$s->is_write_blocked, 'unblocked after draining below low watermark');
is(length($drain), length($payload), 'all bytes drained');

done_testing;

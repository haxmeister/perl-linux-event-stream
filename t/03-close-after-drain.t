use v5.36;
use strict;
use warnings;

use Test2::V0;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Linux::Event;
use Linux::Event::Stream;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";

my $loop = Linux::Event->new;

my $closed = 0;
my $s = Linux::Event::Stream->new(
  loop => $loop,
  fh   => $a,
  on_close => sub ($s, $data) { $closed++ },
);

my $payload = 'y' x 200_000;
$s->write($payload);
$s->close_after_drain;

ok($s->is_closing || !$s->is_closed, 'closing requested');

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
});

$loop->run;

ok($s->is_closed, 'stream closed after drain');
is($closed, 1, 'on_close fired once');
is(length($drain), length($payload), 'peer received full payload');

done_testing;

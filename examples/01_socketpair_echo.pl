#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Linux::Event;
use Linux::Event::Stream;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";

my $loop = Linux::Event->new;

my $sa = Linux::Event::Stream->new(
  loop => $loop,
  fh   => $a,
  on_read => sub ($s, $bytes, $data) {
    print "A got: $bytes";
  },
  on_error => sub ($s, $errno, $data) {
    warn "A error: $errno\n";
  },
  on_close => sub ($s, $data) {
    print "A closed\n";
  },
);

my $sb = Linux::Event::Stream->new(
  loop => $loop,
  fh   => $b,
  on_read => sub ($s, $bytes, $data) {
    print "B got: $bytes";
    # echo back
    $s->write($bytes);
  },
);

$sa->write("hello from A\n");
$loop->run;

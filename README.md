# Linux::Event::Stream

[![CI](https://github.com/haxmeister/perl-linux-event-stream/actions/workflows/ci.yml/badge.svg)](https://github.com/haxmeister/perl-linux-event-stream/actions/workflows/ci.yml)

Buffered, backpressure-aware I/O for Linux::Event.

## Overview

Linux::Event::Stream wraps a nonblocking file descriptor and provides:

- Write buffering
- High/low watermark backpressure (hysteresis latch)
- Graceful close-after-drain
- Optional read throttling

It does **not** create sockets, implement protocols, or modify the event loop.
It is a small policy layer over a file descriptor.

Designed for use with **Linux::Event 0.007+**.

---

## Basic Example

```perl
use v5.36;
use Linux::Event;
use Linux::Event::Stream;

my $loop = Linux::Event->new;

my $stream = Linux::Event::Stream->new(
  loop => $loop,
  fh   => $socket,

  on_read => sub ($stream, $bytes) {
    print "Received: $bytes";
  },

  on_error => sub ($stream, $errno) {
    warn "I/O error: $errno";
  },

  on_close => sub ($stream) {
    print "Connection closed\n";
  },

  high_watermark => 1_048_576,
  low_watermark  =>   262_144,
);

$stream->write("hello\n");

$loop->run;

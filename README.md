# Linux::Event::Stream

[![CI](https://github.com/haxmeister/perl-linux-event-stream/actions/workflows/ci.yml/badge.svg)](https://github.com/haxmeister/perl-linux-event-stream/actions/workflows/ci.yml)

Buffered, backpressure-aware I/O for established nonblocking filehandles.

## Linux::Event Ecosystem

The Linux::Event modules are designed as a composable stack of small,
explicit components rather than a framework.

Each module has a narrow responsibility and can be combined with the others
to build event-driven applications.

Core layers:

Linux::Event
    The event loop. Linux-native readiness engine using epoll and related
    kernel facilities. Provides watchers and the dispatch loop.

Linux::Event::Listen
    Server-side socket acquisition (bind + listen + accept). Produces accepted
    nonblocking filehandles.

Linux::Event::Connect
    Client-side socket acquisition (nonblocking connect). Produces connected
    nonblocking filehandles.

Linux::Event::Stream
    Buffered I/O and backpressure management for an established filehandle.

Linux::Event::Fork
    Asynchronous child process management integrated with the event loop.

Linux::Event::Clock
    High resolution monotonic time utilities used for scheduling and deadlines.

Canonical network composition:

Listen / Connect
        ↓
      Stream
        ↓
  Application protocol

Example stack:

Linux::Event::Listen → Linux::Event::Stream → your protocol

or

Linux::Event::Connect → Linux::Event::Stream → your protocol

The core loop intentionally remains a primitive layer and does not grow
into a framework. Higher-level behavior is composed from small modules.

## Synopsis (raw bytes)

use v5.36;
use Linux::Event;
use Linux::Event::Stream;

my $loop = Linux::Event->new;

Linux::Event::Stream->new(
  loop => $loop,
  fh   => $fh,

  on_read => sub ($stream, $bytes, $data) {
    # arbitrary chunks
  },

  on_error => sub ($stream, $errno, $data) {
    local $! = $errno;
    warn "I/O error: $!\n";
  },

  on_close => sub ($stream, $data) {
    # closed
  },
);

$loop->run;

## Message mode

Linux::Event::Stream->new(
  loop => $loop,
  fh   => $fh,

  codec => 'line',

  on_message => sub ($stream, $line, $data) {
    $stream->write_message("echo: $line");
  },
);

## Backpressure

Stream tracks queued outbound bytes.

When buffered bytes exceed the high watermark the stream becomes write blocked.

A common pattern is:

pause reads upstream when write blocked  
resume reads when drained

## License

Same terms as Perl itself.

# Linux::Event::Stream

Buffered, backpressure-aware I/O semantics for any nonblocking file descriptor used with **Linux::Event**.

## What it is

`Linux::Event::Stream` is a small, focused abstraction:

- **Buffered writes** with partial-write handling
- Automatic **write readiness arming/disarming** (prevents write spin)
- **High/low watermarks** for backpressure
- `close_after_drain` for graceful shutdown
- Raw-byte `on_read` callback with `pause_read` / `resume_read`
- Idempotent teardown and lifecycle callbacks (`on_error`, `on_close`)

## What it is *not*

Stream does **not** do:

- socket setup (listen/connect/accept)
- fork logic
- TLS
- protocol logic (HTTP, Redis, etc.)
- loop modification

## Install

```bash
cpanm Linux::Event::Stream
```

## Quick example

```perl
use v5.36;
use Linux::Event;
use Linux::Event::Stream;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

my $loop = Linux::Event->new;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";

my $s = Linux::Event::Stream->new(
  loop => $loop,
  fh   => $a,
  on_read => sub ($s, $bytes, $data) {
    print "got: $bytes\n";
  },
);

$s->write("hello\n");
$loop->run;
```

## Status

- v0.001: raw buffering + backpressure + lifecycle
- v0.002 (planned): framing helpers (`on_line`, length frames, optional JSONL)

## License

Same terms as Perl itself.

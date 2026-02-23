package Linux::Event::Stream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

use Carp qw(croak);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

# Watcher callback shims (avoid per-instance closures; the Stream instance is passed as watcher data).
sub _watch_read_cb  ($w, $fh, $stream) { _on_read_ready($stream, $w, $fh)  }
sub _watch_write_cb ($w, $fh, $stream) { _on_write_ready($stream, $w, $fh) }
sub _watch_error_cb ($w, $fh, $stream) { _on_error_ready($stream, $w, $fh) }

sub new ($class, %opt) {
  my $loop = delete $opt{loop} // croak 'new(): missing required option: loop';
  my $fh   = delete $opt{fh}   // croak 'new(): missing required option: fh';

  my $on_read  = delete $opt{on_read};
  my $on_error = delete $opt{on_error};
  my $on_close = delete $opt{on_close};

  croak 'new(): on_read must be a coderef'  if defined $on_read  && ref($on_read)  ne 'CODE';
  croak 'new(): on_error must be a coderef' if defined $on_error && ref($on_error) ne 'CODE';
  croak 'new(): on_close must be a coderef' if defined $on_close && ref($on_close) ne 'CODE';

  my $data = delete $opt{data};

  my $high = delete $opt{high_watermark};
  my $low  = delete $opt{low_watermark};

  $high = 1_048_576 if !defined $high;
  $low  =   262_144 if !defined $low;

  $low = $high if $low > $high;

  my $read_size = delete $opt{read_size};
  $read_size = 8192 if !defined $read_size;

  my $max_read_per_tick = delete $opt{max_read_per_tick};
  $max_read_per_tick = 0 if !defined $max_read_per_tick;

  my $close_fh = delete $opt{close_fh};
  $close_fh = 0 if !defined $close_fh;

  croak 'new(): unknown options: ' . join(', ', sort keys %opt) if %opt;

  _set_nonblocking($fh);

  my $self = bless {
    loop => $loop,
    fh   => $fh,

    # callbacks + opaque user data
    on_read  => $on_read,
    on_error => $on_error,
    on_close => $on_close,
    data     => $data,

    # write buffering
    wbuf => '',
    woff => 0,

    high_watermark => $high,
    low_watermark  => $low,

    read_size        => $read_size,
    max_read_per_tick=> $max_read_per_tick,

    # state flags
    closed        => 0,
    closing       => 0,
    read_paused   => 0,
    write_blocked => 0,

    close_fh      => $close_fh,

    # callback-once guard
    close_cb_fired => 0,
  }, $class;

  my $w = $loop->watch($fh,
    read  => \&_watch_read_cb,
    write => \&_watch_write_cb,
    error => \&_watch_error_cb,
    data  => $self,

    # Stream controls readiness itself; defaults here are fine.
    edge_triggered => 0,
    oneshot        => 0,
  );

  $self->{watcher} = $w;

  # Don't arm write notifications unless we have buffered data.
  _disable_write($self);

  return $self;
}

sub fh ($self) { $self->{fh} }

sub is_closed ($self)  { !!$self->{closed} }
sub is_closing ($self) { !!$self->{closing} }

sub buffered_bytes ($self) {
  my $len = length($self->{wbuf});
  my $off = $self->{woff};
  return $len > $off ? ($len - $off) : 0;
}

sub is_write_blocked ($self) { !!$self->{write_blocked} }

sub write ($self, $bytes) {
  return 0 if $self->{closed};
  return 1 if !defined($bytes) || $bytes eq '';

  # Append to the write buffer. Use offset strategy to avoid copying on partial writes.
  my $buf = $self->{wbuf};
  my $off = $self->{woff};

  # If we've consumed a lot of the buffer, occasionally compact.
  # This is intentionally infrequent to avoid O(n) churn.
  if ($off && ($off > 65_536 || $off > (length($buf) >> 1))) {
    substr($buf, 0, $off, '');
    $off = 0;
  }

  $buf .= $bytes;

  $self->{wbuf} = $buf;
  $self->{woff} = $off;

  my $pending = length($buf) - $off;

  if (!$self->{write_blocked} && $pending > $self->{high_watermark}) {
    $self->{write_blocked} = 1;
  }

  _enable_write($self);

  return 1;
}

sub pause_read ($self) {
  return $self if $self->{closed} || $self->{read_paused};
  $self->{read_paused} = 1;
  _disable_read($self);
  return $self;
}

sub resume_read ($self) {
  return $self if $self->{closed} || !$self->{read_paused} || $self->{closing};
  $self->{read_paused} = 0;
  _enable_read($self);
  return $self;
}

sub close_after_drain ($self) {
  return $self if $self->{closed};
  $self->{closing} = 1;

  # Once closing is requested, stop delivering reads by default.
  if (!$self->{read_paused}) {
    $self->{read_paused} = 1;
    _disable_read($self);
  }

  if ($self->buffered_bytes == 0) {
    _close_now($self);
  } else {
    _enable_write($self); # ensure we drain
  }

  return $self;
}

sub close ($self) {
  return $self if $self->{closed};
  _close_now($self);
  return $self;
}

# ---- internal helpers (kept shallow; hot paths are _on_*_ready) ----

sub _set_nonblocking ($fh) {
  my $flags = fcntl($fh, F_GETFL, 0);
  return if !defined $flags; # best-effort
  return if ($flags & O_NONBLOCK);
  fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
  return;
}

sub _disable_read ($self) {
  my $w = $self->{watcher} or return;
  $w->disable_read if $w->can('disable_read');
  return;
}

sub _enable_read ($self) {
  my $w = $self->{watcher} or return;
  $w->enable_read if $w->can('enable_read');
  return;
}

sub _disable_write ($self) {
  my $w = $self->{watcher} or return;
  $w->disable_write if $w->can('disable_write');
  return;
}

sub _enable_write ($self) {
  my $w = $self->{watcher} or return;
  $w->enable_write if $w->can('enable_write');
  return;
}

sub _teardown_watcher ($self) {
  my $w = delete $self->{watcher} or return;

  $w->disable_read  if $w->can('disable_read');
  $w->disable_write if $w->can('disable_write');

  # Be conservative: different watcher implementations may expose different teardown names.
  $w->close   if $w->can('close');
  $w->cancel  if !$w->can('close')  && $w->can('cancel');
  $w->destroy if !$w->can('close')  && !$w->can('cancel') && $w->can('destroy');

  return;
}

sub _fire_on_error ($self, $errno) {
  my $cb = $self->{on_error} or return;
  my $data = $self->{data};
  $cb->($self, $errno, $data);
  return;
}

sub _fire_on_close ($self) {
  return if $self->{close_cb_fired}++;
  my $cb = $self->{on_close} or return;
  my $data = $self->{data};
  $cb->($self, $data);
  return;
}

sub _close_now ($self) {
  return if $self->{closed};

  $self->{closed}  = 1;
  $self->{closing} = 0;

  _teardown_watcher($self);

  if ($self->{close_fh}) {
    my $fh = $self->{fh};
    close($fh) if $fh;
  }

  _fire_on_close($self);
  return;
}

sub _on_read_ready ($self, $w, $fh) {
  return if $self->{closed} || $self->{read_paused} || $self->{closing};

  my $read_size = $self->{read_size};
  my $max_bytes = $self->{max_read_per_tick};

  my $total = 0;

  while (1) {
    my $bytes = '';
    my $n = sysread($fh, $bytes, $read_size);

    if (defined $n) {
      if ($n == 0) {
        # EOF
        _close_now($self);
        return;
      }

      $total += $n;

      if (my $cb = $self->{on_read}) {
        my $data = $self->{data};
        $cb->($self, $bytes, $data);
      }

      last if $self->{closed} || $self->{read_paused} || $self->{closing};

      last if $max_bytes && $total >= $max_bytes;

      next;
    }

    # sysread error
    my $errno = $! + 0;

    # EAGAIN / EWOULDBLOCK
    if ($errno == 11 || $errno == 35 || $errno == 10035) {
      return;
    }

    _fire_on_error($self, $errno);
    _close_now($self);
    return;
  }

  return;
}

sub _on_write_ready ($self, $w, $fh) {
  return if $self->{closed};

  my $buf = $self->{wbuf};
  my $off = $self->{woff};

  my $len = length($buf);
  my $pending = $len > $off ? ($len - $off) : 0;

  if ($pending == 0) {
    _disable_write($self);
    $self->{wbuf} = '';
    $self->{woff} = 0;

    _close_now($self) if $self->{closing};
    return;
  }

  while ($pending > 0) {
    my $n = syswrite($fh, $buf, $pending, $off);

    if (defined $n) {
      if ($n == 0) {
        # Treat as would-block-ish; just stop trying.
        last;
      }

      $off += $n;
      $pending -= $n;

      # Watermark transitions.
      if ($self->{write_blocked} && $pending < $self->{low_watermark}) {
        $self->{write_blocked} = 0;
      }

      next;
    }

    my $errno = $! + 0;

    # EAGAIN / EWOULDBLOCK
    if ($errno == 11 || $errno == 35 || $errno == 10035) {
      last;
    }

    _fire_on_error($self, $errno);
    _close_now($self);
    return;
  }

  # Commit updated buffer state.
  $self->{woff} = $off;
  if ($pending == 0) {
    $self->{wbuf} = '';
    $self->{woff} = 0;
    _disable_write($self);
    _close_now($self) if $self->{closing};
  } else {
    $self->{wbuf} = $buf;
    _enable_write($self); # keep draining
  }

  return;
}

sub _on_error_ready ($self, $w, $fh) {
  return if $self->{closed};

  # On many backends, "error" readiness corresponds to HUP/ERR; attempt to
  # surface something useful via $! if available.
  my $errno = $! + 0;
  $errno = 5 if !$errno; # EIO as a generic fallback

  _fire_on_error($self, $errno);
  _close_now($self);
  return;
}

1;

__END__

=head1 NAME

Linux::Event::Stream - Buffered, backpressure-aware I/O for nonblocking file descriptors

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;
  use Linux::Event::Stream;
  use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

  my $loop = Linux::Event->new;

  socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";

  my $got = '';

  my $sa = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,

    on_read => sub ($s, $bytes, $data) {
      $got .= $bytes;
      $s->close if length($got) >= 5;
    },

    on_error => sub ($s, $errno, $data) {
      die "stream error: $errno";
    },

    on_close => sub ($s, $data) {
      # Fired exactly once when the stream is torn down.
    },
  );

  $sa->write("hello");

  # Drain from the other end (just as an example; real code would also use Stream)
  $loop->watch($b, read => sub ($w, $fh, $data) { sysread($fh, my $x, 4096) });

  $loop->run;

=head1 DESCRIPTION

B<Linux::Event::Stream> provides buffered, backpressure-aware I/O semantics for any
nonblocking file descriptor used with L<Linux::Event>.

It is intentionally small and focused:

=over 4

=item *

No socket setup (listen/connect/accept)

=item *

No fork logic

=item *

No protocol logic (HTTP/Redis/etc.)

=item *

No TLS

=item *

No modifications to the event loop

=back

A Stream is just:

  fd + loop + internal watcher + buffering + callbacks

=head1 CONSTRUCTOR

=head2 new

  my $stream = Linux::Event::Stream->new(%opt);

Required:

=over 4

=item * C<loop>

A L<Linux::Event> loop instance.

=item * C<fh>

A nonblocking filehandle (or any filehandle that can be made nonblocking).

=back

Callbacks (all optional):

=over 4

=item * C<on_read =E<gt> sub ($stream, $bytes, $data) { ... }>

Called with raw bytes read from the file descriptor.

=item * C<on_error =E<gt> sub ($stream, $errno, $data) { ... }>

Called when a read/write/error condition occurs. C<$errno> is numeric (C<$!+0>)
at the time of failure. After C<on_error>, Stream closes by default.

=item * C<on_close =E<gt> sub ($stream, $data) { ... }>

Called exactly once when the stream is closed and fully torn down.

=back

Buffering / backpressure:

=over 4

=item * C<high_watermark>

Default: 1_048_576 bytes.

If buffered write data exceeds this amount, C<is_write_blocked> becomes true.
Stream does not automatically stop accepting writes; it reports state so the
caller can apply backpressure.

=item * C<low_watermark>

Default: 262_144 bytes.

When buffered bytes drop below this amount, C<is_write_blocked> becomes false.

=back

Read tuning:

=over 4

=item * C<read_size>

Default: 8192 bytes per C<sysread>.

=item * C<max_read_per_tick>

Default: 0 (unlimited). If non-zero, caps the total bytes read per readiness
notification to improve fairness across many active streams.

=back

Ownership:

=over 4

=item * C<close_fh>

Default: false. If true, Stream will C<close()> the filehandle when the stream
closes. If false, Stream tears down its watcher but does not close the fd.

=item * C<data>

Opaque user data passed to callbacks.

=back

=head1 METHODS

=head2 write

  $stream->write($bytes);  # returns bool

Buffers bytes for writing and arms write readiness notifications as needed.

Returns false only if the stream is already closed.

=head2 pause_read / resume_read

  $stream->pause_read;
  $stream->resume_read;

Disables or re-enables read delivery. While paused, read readiness is not
processed and C<on_read> is not called.

=head2 close

  $stream->close;

Immediately closes the stream (idempotent) and tears down watchers.
If C<close_fh> is enabled, also closes the filehandle.

=head2 close_after_drain

  $stream->close_after_drain;

Requests a graceful shutdown: stop reads and flush all buffered writes; when the
write buffer drains, the stream closes. Idempotent.

=head2 is_closed / is_closing

Boolean state queries.

=head2 is_write_blocked

True when buffered bytes exceed C<high_watermark>. Clears when buffered bytes
drop below C<low_watermark>.

=head2 buffered_bytes

Returns the current number of bytes queued in the write buffer.

=head2 fh

Returns the underlying filehandle.

=head1 CALLBACK SEMANTICS

=head2 on_read

Called with raw bytes as they are read. If the peer closes cleanly (EOF),
Stream closes and C<on_close> is called.

=head2 on_error

Called when a read/write operation fails. By default Stream then closes and
calls C<on_close> (exactly once).

=head2 on_close

Called exactly once when teardown is complete.

=head1 DESIGN NOTES

Stream registers exactly one watcher with the loop and arms/disarms write
notifications automatically to prevent write-spin.

Stream is designed as a universal buffered I/O layer across the ecosystem:

  Loop   = engine
  Listen = socket acquisition
  Fork   = process lifecycle
  Stream = I/O semantics

=head1 AUTHOR

Joshua S. Day E<lt>hax@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

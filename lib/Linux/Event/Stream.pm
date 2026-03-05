package Linux::Event::Stream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.002';

use Carp qw(croak);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Scalar::Util qw(reftype);

use Linux::Event::Stream::Codec::Line ();
use Linux::Event::Stream::Codec::Netstring ();
use Linux::Event::Stream::Codec::U32BE ();

# Watcher callbacks: ($loop, $fh, $watcher)
# The Stream instance is stored in $watcher->data.
sub _watch_read_cb  ($loop, $fh, $watcher) { my $self = $watcher->data or return; _on_read_ready($self, $watcher, $fh) }
sub _watch_write_cb ($loop, $fh, $watcher) { my $self = $watcher->data or return; _on_write_ready($self, $watcher, $fh) }
sub _watch_error_cb ($loop, $fh, $watcher) { my $self = $watcher->data or return; _on_error_ready($self, $watcher, $fh) }

sub new ($class, %opt) {
  my $loop = delete $opt{loop} // croak 'new(): missing loop';
  my $fh   = delete $opt{fh}   // croak 'new(): missing fh';

  my $on_read  = delete $opt{on_read};
  my $on_message = delete $opt{on_message};
  my $on_error = delete $opt{on_error};
  my $on_close = delete $opt{on_close};

  croak 'on_read must be a coderef'  if defined $on_read  && ref($on_read)  ne 'CODE';
  croak 'on_message must be a coderef' if defined $on_message && ref($on_message) ne 'CODE';
  croak 'on_error must be a coderef' if defined $on_error && ref($on_error) ne 'CODE';
  croak 'on_close must be a coderef' if defined $on_close && ref($on_close) ne 'CODE';

  my $codec   = delete $opt{codec};
  my $decoder = delete $opt{decoder};
  my $encoder = delete $opt{encoder};

  croak 'use either codec or decoder/encoder, not both'
    if defined($codec) && (defined($decoder) || defined($encoder));

  # Framed/message mode is enabled by providing on_message.
  my $framed = defined($on_message) ? 1 : 0;
  croak 'on_read is not used when on_message is provided; use on_message + codec'
    if $framed && defined $on_read;

  my $data = delete $opt{data};

  my $high = delete $opt{high_watermark} // 1_048_576;
  my $low  = delete $opt{low_watermark}  //   262_144;
  $low = $high if $low > $high;

  my $read_size = delete $opt{read_size} // 8192;
  my $max_read_per_tick = delete $opt{max_read_per_tick} // 0;

  my $max_inbuf = delete $opt{max_inbuf};
  $max_inbuf //= 1_048_576 if $framed;

  my $close_fh = delete $opt{close_fh} // 0;

  if ($framed) {
    $codec = $decoder // $encoder // $codec;
    croak 'new(): missing codec (required with on_message)' if !defined $codec;

    if (!ref($codec)) {
      $codec =
        $codec eq 'line'      ? Linux::Event::Stream::Codec::Line->new :
        $codec eq 'netstring' ? Linux::Event::Stream::Codec::Netstring->new :
        $codec eq 'u32be'     ? Linux::Event::Stream::Codec::U32BE->new :
        croak "unknown codec alias: $codec";
    }

    croak 'codec must be a hashref (or blessed hashref)'
      if !defined(reftype($codec)) || reftype($codec) ne 'HASH';
    croak 'codec->{decode} must be a coderef' if ref($codec->{decode}) ne 'CODE';
    croak 'codec->{encode} must be a coderef' if ref($codec->{encode}) ne 'CODE';
  }

  croak 'unknown options: ' . join(', ', sort keys %opt) if %opt;

  _set_nonblocking($fh);

  my $self = bless {
    loop => $loop,
    fh   => $fh,

    # raw bytes mode
    on_read  => $on_read,

    # framed/message mode
    on_message => $on_message,
    codec      => $codec,
    rbuf       => '',
    max_inbuf  => $max_inbuf,

    on_error => $on_error,
    on_close => $on_close,
    data     => $data,

    last_error => undef,

    # write buffering
    wbuf => '',
    woff => 0,

    high_watermark => $high,
    low_watermark  => $low,

    read_size         => $read_size,
    max_read_per_tick => $max_read_per_tick,

    # state
    closed        => 0,
    closing       => 0,
    read_paused   => 0,
    write_blocked => 0,
    close_fh      => $close_fh,
    close_cb_fired => 0,

    watcher => undef,
  }, $class;

  my $w = $loop->watch($fh,
    read  => \&_watch_read_cb,
    write => \&_watch_write_cb,
    error => \&_watch_error_cb,
    data  => $self,
  );

  $self->{watcher} = $w;

  # Do not arm write notifications until there is buffered data.
  $w->disable_write;

  return $self;
}

sub fh ($self) { $self->{fh} }

sub is_closed  ($self) { !!$self->{closed} }
sub is_closing ($self) { !!$self->{closing} }

sub buffered_bytes ($self) {
  my $len = length($self->{wbuf} // '');
  my $off = $self->{woff} // 0;
  return $len > $off ? ($len - $off) : 0;
}

sub is_write_blocked ($self) { !!$self->{write_blocked} }

sub last_error ($self) { $self->{last_error} }

sub write ($self, $bytes) {
  return 0 if $self->{closed};
  return 1 if !defined($bytes) || $bytes eq '';

  # Fast path: attempt to write immediately when there is no pending buffer.
  # This reduces latency and avoids reliance on EPOLLOUT notifications to start a drain.
  if ($self->buffered_bytes == 0) {
    my $n = syswrite($self->{fh}, $bytes);
    if (defined $n) {
      return 1 if $n == length($bytes);
      # partial: buffer remainder
      substr($bytes, 0, $n, '');
    } else {
      my $errno = $! + 0;
      # EAGAIN: buffer whole payload
      if ($errno != 11) {
        $self->{last_error} = "io:$errno";
        _fire_on_error($self, $errno);
        _close_now($self);
        return 0;
      }
    }
  }

  # Buffer what remains (or all, if immediate write did not happen).
  my $buf = $self->{wbuf};
  my $off = $self->{woff};

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

  $self->{watcher}->enable_write;
  return 1;
}

sub write_message ($self, $msg) {
  return 0 if $self->{closed};
  my $codec = $self->{codec} // croak 'write_message() requires a codec (use on_message mode)';
  my $bytes = $codec->{encode}->($codec, $msg);
  return $self->write($bytes);
}

sub pause_read ($self) {
  return $self if $self->{closed} || $self->{read_paused};
  $self->{read_paused} = 1;
  $self->{watcher}->disable_read;
  return $self;
}

sub resume_read ($self) {
  return $self if $self->{closed} || !$self->{read_paused} || $self->{closing};
  $self->{read_paused} = 0;
  $self->{watcher}->enable_read;
  return $self;
}

sub close_after_drain ($self) {
  return $self if $self->{closed};
  $self->{closing} = 1;

  $self->pause_read;

  if ($self->buffered_bytes == 0) {
    _close_now($self);
  } else {
    $self->{watcher}->enable_write;
  }

  return $self;
}

sub close ($self) {
  return $self if $self->{closed};
  _close_now($self);
  return $self;
}

# ---- internals ----

sub _set_nonblocking ($fh) {
  my $flags = fcntl($fh, F_GETFL, 0);
  return if !defined $flags;        # best-effort
  return if ($flags & O_NONBLOCK);
  fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
  return;
}

sub _fire_on_error ($self, $errno) {
  $self->{last_error} //= ($errno ? "io:$errno" : 'error');
  my $cb = $self->{on_error} or return;
  $cb->($self, $errno, $self->{data});
  return;
}

sub _fire_on_close ($self) {
  return if $self->{close_cb_fired}++;
  my $cb = $self->{on_close} or return;
  $cb->($self, $self->{data});
  return;
}

sub _close_now ($self) {
  return if $self->{closed};

  $self->{closed}  = 1;
  $self->{closing} = 0;

  if (my $w = $self->{watcher}) {
    $w->cancel;
  }

  if ($self->{close_fh}) {
    CORE::close($self->{fh});
  }

  _fire_on_close($self);
  return;
}

sub _on_read_ready ($self, $watcher, $fh) {
  return if $self->{closed} || $self->{read_paused} || $self->{closing};

  my $read_size = $self->{read_size};
  my $max_bytes = $self->{max_read_per_tick};

  my $total = 0;

  while (1) {
    my $bytes = '';
    my $n = sysread($fh, $bytes, $read_size);

    if (defined $n) {
      if ($n == 0) {
        _close_now($self);
        return;
      }

      $total += $n;

      if (my $cb = $self->{on_read}) {
        # raw bytes mode
        $cb->($self, $bytes, $self->{data});
      } elsif (my $on_message = $self->{on_message}) {
        # framed/message mode
        my $rbuf = $self->{rbuf};
        $rbuf .= $bytes;

        my $max = $self->{max_inbuf};
        if (defined($max) && length($rbuf) > $max) {
          $self->{last_error} = "codec:max_inbuf_exceeded:$max";
          _fire_on_error($self, 0);
          _close_now($self);
          return;
        }

        my @out;
        my $codec = $self->{codec};
        my ($ok, $err) = $codec->{decode}->($codec, \$rbuf, \@out);
        if (!$ok) {
          $err //= 'decode error';
          $self->{last_error} = "codec:$err";
          _fire_on_error($self, 0);
          _close_now($self);
          return;
        }

        $self->{rbuf} = $rbuf;

        for my $msg (@out) {
          $on_message->($self, $msg, $self->{data});
          last if $self->{closed} || $self->{read_paused} || $self->{closing};
        }
      }

      last if $self->{closed} || $self->{read_paused} || $self->{closing};
      last if $max_bytes && $total >= $max_bytes;

      next;
    }

    my $errno = $! + 0;
    return if $errno == 11; # EAGAIN on Linux

    $self->{last_error} = "io:$errno";
    _fire_on_error($self, $errno);
    _close_now($self);
    return;
  }

  return;
}

sub _on_write_ready ($self, $watcher, $fh) {
  return if $self->{closed};

  my $buf = $self->{wbuf};
  my $off = $self->{woff};

  my $pending = length($buf) - $off;

  if ($pending <= 0) {
    $self->{wbuf} = '';
    $self->{woff} = 0;
    $watcher->disable_write;
    _close_now($self) if $self->{closing};
    return;
  }

  while ($pending > 0) {
    my $n = syswrite($fh, $buf, $pending, $off);

    if (defined $n) {
      $off     += $n;
      $pending -= $n;

      # FIX: persist partial progress so buffered_bytes() and watermark state
      # can advance even when we return on EAGAIN later.
      $self->{woff} = $off;

      if ($self->{write_blocked} && $pending < $self->{low_watermark}) {
        $self->{write_blocked} = 0;
      }

      next;
    }

    my $errno = $! + 0;

    # FIX: also persist offset before returning.
    $self->{woff} = $off;

    return if $errno == 11; # EAGAIN on Linux

    $self->{last_error} = "io:$errno";
    _fire_on_error($self, $errno);
    _close_now($self);
    return;
  }

  # drained
  $self->{wbuf} = '';
  $self->{woff} = 0;
  $watcher->disable_write;

  _close_now($self) if $self->{closing};
  return;
}

sub _on_error_ready ($self, $watcher, $fh) {
  return if $self->{closed};

  my $errno = $! + 0;
  $errno = 5 if !$errno; # EIO fallback

  $self->{last_error} = "io:$errno";
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

  my $loop = Linux::Event->new;

  # Raw bytes mode: on_read receives arbitrary chunks.
  my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $fh,

    on_read => sub ($stream, $bytes, $data) {
      # ...
    },

    on_error => sub ($stream, $errno, $data) {
      # fatal I/O error; stream will close
      # local $! = $errno;
    },

    on_close => sub ($stream, $data) {
      # closed (EOF, error, or explicit close)
    },

    data => { ... },
  );

  $loop->run;

=head2 Message mode (codec)

  my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $fh,

    codec      => 'line',
    on_message => sub ($stream, $msg, $data) {
      $stream->write_message("echo: $msg");
      $stream->close_after_drain if $msg eq 'quit';
    },

    on_error => sub ($stream, $errno, $data) { },
    on_close => sub ($stream, $data) { },
  );

=head1 DESCRIPTION

B<Linux::Event::Stream> owns an established nonblocking filehandle (typically a
socket) and provides:

=over 4

=item * Buffered writes

Writes are queued and flushed when the fd becomes writable.

=item * Raw reads (bytes mode)

In bytes mode, inbound data is delivered as arbitrary chunks via C<on_read>.

=item * Optional framing (message mode)

In message mode, inbound bytes are decoded by a codec and delivered via
C<on_message>.

=item * Backpressure signaling

Stream tracks queued outbound bytes and reports when the stream is write blocked
(above the high watermark). This lets upstream code pause reads to keep memory
bounded.

=back

Stream does not bind, accept, connect, or resolve addresses. It only manages I/O
for a filehandle you provide.

=head1 LAYERING

This distribution is part of a composable socket stack:

=over 4

=item * B<Linux::Event::Listen>

Server-side socket acquisition: bind + listen + accept. Produces accepted
nonblocking filehandles.

=item * B<Linux::Event::Connect>

Client-side socket acquisition: nonblocking outbound connect. Produces connected
nonblocking filehandles.

=item * B<Linux::Event::Stream>

Buffered I/O + backpressure for an established filehandle (accepted or
connected). Stream owns the filehandle and handles read/write buffering.

=back

Canonical composition:

  Listen/Connect -> Stream -> (your protocol/codec/state)

=head1 CONSTRUCTOR

=head2 new

  my $stream = Linux::Event::Stream->new(%opt);

Creates and starts a stream immediately. Unknown keys are fatal.

Required:

=over 4

=item * C<loop>

A L<Linux::Event::Loop> instance.

=item * C<fh>

A filehandle. Stream forces nonblocking mode.

=back

Choose one input delivery mode:

=head3 Raw bytes mode

Provide C<on_read>:

  on_read => sub ($stream, $bytes, $data) { ... }

=head3 Message mode

Provide C<on_message>. You may also provide a codec (recommended):

  on_message => sub ($stream, $msg, $data) { ... }
  codec      => 'line' | $codec_object

If you do not provide a codec, you may provide C<decoder> and C<encoder>
coderefs (see L</CODECS>).

=head1 OPTIONS

=head2 data

  data => $any

Opaque user data passed to callbacks as the last argument.

=head2 on_read

  on_read => sub ($stream, $bytes, $data) { ... }

Raw bytes mode callback.

=head2 on_message

  on_message => sub ($stream, $msg, $data) { ... }

Message mode callback.

=head2 on_error

  on_error => sub ($stream, $errno, $data) { ... }

Called on fatal I/O error with numeric errno. Stream will close and then invoke
C<on_close>.

=head2 on_close

  on_close => sub ($stream, $data) { ... }

Called once when the stream closes (EOF, error, or explicit close). After this
fires, the stream is inert.

=head2 read_size

  read_size => 8192  # default

Read chunk size used internally for sysread.

=head2 max_read_per_tick

  max_read_per_tick => 0  # default (unlimited)

If non-zero, caps how many read iterations are performed per readiness event.

=head2 max_inbuf

  max_inbuf => 1048576  # default

Maximum buffered inbound bytes in message mode. If exceeded, the stream fails
with an error to prevent unbounded memory use.

=head2 high_watermark / low_watermark

  high_watermark => 1048576,  # default
  low_watermark  => 262144,   # default (clamped <= high)

Write backpressure thresholds. When queued outbound bytes exceed the high
watermark, the stream becomes write blocked. It becomes unblocked again once
queued bytes drop to (or below) the low watermark.

=head2 close_fh

  close_fh => 1  # default

If true, Stream closes the underlying filehandle when it closes. If false,
Stream detaches from the fh and you remain responsible for closing it.

=head1 CODECS

=head2 codec

  codec => 'line'

Provides a built-in codec by name. (See your distribution for which codecs are
included.)

=head2 decoder / encoder

  decoder => sub ($bytes, $state) { ... }
  encoder => sub ($msg,   $state) { ... }

Advanced: provide explicit decoder/encoder coderefs.

Do not mix C<codec> with C<decoder>/C<encoder>.

=head1 CALLBACK CONTRACT

All callbacks share the same shape:

  ($stream, ...args..., $data)

Where C<$data> is the C<data> option (or undef).

=head1 METHODS

=head2 fh

  my $fh = $stream->fh;

Return the underlying filehandle.

=head2 is_closed / is_closing

  $stream->is_closed;
  $stream->is_closing;

Introspection for stream state.

=head2 buffered_bytes

  my $n = $stream->buffered_bytes;

Number of queued outbound bytes not yet written.

=head2 is_write_blocked

  if ($stream->is_write_blocked) { ... }

True when queued outbound bytes exceed the high watermark.

=head2 last_error

  my $errno = $stream->last_error;

Return the last error number observed (if any).

=head2 write

  $stream->write($bytes);

Queue raw bytes for writing.

Stream attempts an immediate write fast-path when there is no pending outbound
buffer, then falls back to buffering and enabling write readiness.

=head2 write_message

  $stream->write_message($msg);

Encode a message using the configured codec/encoder and queue it for writing.
Only valid in message mode.

=head2 pause_read / resume_read

  $stream->pause_read;
  $stream->resume_read;

Disable/enable reading from the underlying fd. Use this with backpressure (for
example, pause reads when your downstream is write blocked).

=head2 close_after_drain

  $stream->close_after_drain;

Request a graceful close: stop accepting new writes, flush pending outbound data,
then close.

=head2 close

  $stream->close;

Close immediately.

=head1 BACKPRESSURE PATTERN

A canonical pattern is:

=over 4

=item * if downstream is write blocked, pause upstream reads

=item * when downstream drains, resume upstream reads

=back

This keeps buffering bounded and makes backpressure explicit in user code.

=head1 SEE ALSO

L<Linux::Event>, L<Linux::Event::Listen>, L<Linux::Event::Connect>

=head1 AUTHOR

Joshua S. Day

=head1 LICENSE

Same terms as Perl itself.

=cut

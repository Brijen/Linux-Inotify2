=head1 NAME

Linux::Inotify2 - scalable directory/file change notification

=head1 SYNOPSIS

 use Linux::Inotify2;

=head1 DESCRIPTION

=head2 The Linux::Inotify2 Class

This module implements an interface to the linux inotify file/directory
change notification sytem.

It has a number of advantages over the Linux::Inotfy module:

   - it is portable (Linux::Inotify only works on x86)
   - the equivalent of fullname works correctly
   - it is better documented
   - it has callback-style interface, which is better suited for
     integration.

=over 4

=cut

package Linux::Inotify2;

use Carp ();
use Scalar::Util ();

use base 'Exporter';

BEGIN {
   $VERSION = 0.1;

   @constants = qw(
      IN_ACCESS IN_MODIFY IN_ATTRIB IN_CLOSE_WRITE
      IN_CLOSE_NOWRITE IN_OPEN IN_MOVED_FROM IN_MOVED_TO
      IN_CREATE IN_DELETE IN_DELETE_SELF
      IN_ALL_EVENTS
      IN_UNMOUNT IN_Q_OVERFLOW IN_IGNORED
      IN_CLOSE IN_MOVE
      IN_ISDIR IN_ONESHOT
   );

   @EXPORT = @constants;

   require XSLoader;
   XSLoader::load Linux::Inotify2, $VERSION;
}

=item my $inotify = new Linux::Inotify2

Create a new notify object and return it. A notify object is kind of a
container that stores watches on filesystem names and is responsible for
handling event data.

On error, C<undef> is returned and C<$!> will be set accordingly. The followign errors
are documented:

 ENFILE   The system limit on the total number of file descriptors has been reached.
 EMFILE   The user limit on the total number of inotify instances has been reached.
 ENOMEM   Insufficient kernel memory is available.

=cut

sub new {
   my ($class) = @_;

   my $fd = inotify_init;

   return unless $fd >= 0;

   bless { fd => $fd }, $class
}

=item $watch = $inotify2->watch ($name, $mask, $cb)

Add a new watcher to the given notifier. The watcher will create events
on the pathname C<$name> as given in C<$mask>, which can be any of the
following constants (all exported by default) ORed together:

 IN_ACCESS            File was accessed
 IN_MODIFY            File was modified
 IN_ATTRIB            Metadata changed
 IN_CLOSE_WRITE       Writtable file was closed
 IN_CLOSE_NOWRITE     Unwrittable file closed
 IN_OPEN              File was opened
 IN_MOVED_FROM        File was moved from X
 IN_MOVED_TO          File was moved to Y
 IN_CREATE            Subfile was created
 IN_DELETE            Subfile was deleted
 IN_DELETE_SELF       Self was deleted
 IN_ONESHOT           only send event once
 IN_ALL_EVENTS        All of the above events

 IN_CLOSE             Same as IN_CLOSE_WRITE | IN_CLOSE_NOWRITE
 IN_MOVE              Same as IN_MOVED_FROM | IN_MOVED_TO

C<$cb> is a perl code reference that is called for each event. It receives
a C<Linux::Inotify2::Event> object.

The returned C<$watch> object is of class C<Linux::Inotify2::Watch>.

On error, C<undef> is returned and C<$!> will be set accordingly. The
following errors are documented:

 EBADF    The given file descriptor is not valid.
 EINVAL   The given event mask contains no legal events.
 ENOMEM   Insufficient kernel memory was available.
 ENOSPC   The user limit on the total number of inotify watches was reached or the kernel failed to allocate a needed resource.
 EACCESS  Read access to the given file is not permitted.

Example, show when C</etc/passwd> gets accessed and/or modified once:

   $inotify->watch ("/etc/passwd", IN_ACCESS | IN_MODIFY, sub {
      my $e = shift;
      print "$e->{w}{name} was accessed\n" if $e->IN_ACCESS;
      print "$e->{w}{name} was modified\n" if $e->IN_MODIFY;
      print "$e->{w}{name} is no longer mounted\n" if $e->IN_UNMOUNT;
      print "events for $e->{w}{name} have been lost\n" if $e->IN_Q_OVERFLOW;

      $e->w->cancel;
   });

=cut

sub watch {
   my ($self, $name, $mask, $cb) = @_;

   my $wd = inotify_add_watch $self->{fd}, $name, $mask;

   return unless $wd >= 0;
   
   my $w = $self->{w}{$wd} = bless {
      inotify => $self,
      wd      => $wd,
      name    => $name,
      mask    => $mask,
      cb      => $cb,
   }, Linux::Inotify2::Watch;

   Scalar::Util::weaken $w->{inotify};

   $w
}

=item $inotify2->fileno

Returns the fileno for this notify object. You are responsible for calling
the C<poll> method when this fileno becomes ready for reading.

=cut

sub fileno {
   $_[0]{fd}
}

=item $count = $inotify2->poll

Reads events from the kernel and handles them. If the notify fileno
is blocking (the default), then this method waits for at least one
event. Otherwise it returns immediately when no pending events could be
read.

Returns the count of events that have been handled.

=cut

# TODO: potential race with recently-canceled watchers

sub poll {
   my ($self) = @_;

   for (inotify_read $self->{fd}) {
      $_->{w} = $self->{w}{$_->{wd}}
         or next; # no such watcher
      $_->{w}{cb}->(bless $_, Linux::Inotify2::Event);
   }
}

sub DESTROY {
   inotify_close $_[0]{fd}
}

=back

=head2 The Linux::Inotify2::Event Class

Objects of this class are handed as first argument to the watch
callback. It has the following members and methods:

=over 4

=item $event->w

=item $event->{w}

The watcher object for this event.

=item $event->name

=item $event->{name}

The path of the filesystem object, relative to the watch name.

=item $watch->fullname

Returns the "full" name of the relevant object, i.e. including the C<name>
component of the watcher.

=item $event->mask

=item $event->{mask}

The received event mask. In addition the the events described for
C<$inotify->watch>, the following flags (exported by default) can be set:

 IN_ISDIR             event occurred against dir

 IN_UNMOUNT           Backing fs was unmounted
 IN_Q_OVERFLOW        Event queued overflowed
 IN_IGNORED           File was ignored (no more events will be delivered)

=item $event->IN_xxx

Returns a boolean that returns true if the event mask matches the
event. All of the C<IN_xxx> constants can be used as methods.

=item $event->cookie

=item $event->{cookie}

The event cookie, can be used to synchronize two related events.

=back

=cut

package Linux::Inotify2::Event;

sub w       { $_[0]{w}      }
sub name    { $_[0]{name}   }
sub mask    { $_[0]{mask}   }
sub cookie  { $_[0]{cookie} }

sub fullname {
   length $_[0]{name}
      ? "$_[0]{w}{name}/$_[0]{name}"
      : $_[0]{w}{name};
}

for my $name (@Linux::Inotify2::constants) {
   my $mask = &{"Linux::Inotify2::$name"};

   *$name = sub { ($_[0]{mask} & $mask) == $mask };
}

=head2 The Linux::Inotify2::Watch Class

Watch objects are created by calling the C<watch> method of a notifier.

It has the following members and methods:

=item $watch->name

=item $watch->{name}

The name as specified in the C<watch> call. For the object itself, this is
the empty string.  For directory watches, this is the name of the entry
without leading path elements.

=item $watch->mask

=item $watch->{mask}

The mask as specified in the C<watch> call.

=item $watch->cb ([new callback])

=item $watch->{cb}

The callback as specified in the C<watch> call. Can optionally be changed.

=item $watch->cancel

Cancels/removes this watch. Future events, even if already queued queued,
will not be handled and resources will be freed.

=cut

package Linux::Inotify2::Watch;

sub name    { $_[0]{name} }
sub mask    { $_[0]{mask} }

sub cb {
   $_[0]{cb} = $_[1] if @_ > 1;
   $_[0]{cb}
}

sub cancel {
   my ($self) = @_;

   (Linux::Inotify2::inotify_rm_watch $self->{inotify}{fd}, $self->{wd})
      ? 1 : undef
}

=head1 SEE ALSO

L<Linux::Inotify>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

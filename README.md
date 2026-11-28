# is_file_driver

intersyntactic's file driver: the service behind the airlock's
`ReadsAndWritesFiles` (from [is_file_request_vocabulary](https://pub.dev/packages/is_file_request_vocabulary)).
It reads and writes the files the airlock has decided, under the home of the
suit a trajectory's agent wears.

- `read` returns the file's exact text, line endings and byte order mark
  included. A file that isn't UTF-8 is `NothingRan`, never decoded loosely.
- `readBytes` returns the file's exact bytes.
- `write` writes the text as UTF-8, creating the folders it is in, and says
  whether it replaced a file. It writes a new file beside the old one and
  renames it over, so a reader sees the whole old file or the whole new
  one. The new file keeps the old one's permissions, a link inside the root
  is written through and kept, and a file the suit cannot write is
  `NothingRan`.
- A write that fails removes the folders it made, so it answers
  `NothingRan`. If one of them can't be removed (something else has been
  put in it since), it answers `StoppedPartway`, naming the folders it left.
- A file holding more than the cap (`FILE_DRIVER_MAX_BYTES`, 8 MiB unless
  set) is `NothingRan`, and so is a text that large: every byte is recorded.

## What contains it

It runs as a service of its own, as the OS user a trajectory's agent wears:
a suit (`suit-N`). That user is the wall: a read or write can reach what the
suit can and no more. Each driver answers only the airlock's user, read from
the socket as the kernel reports it, never from the request.

The airlock refuses a path whose text leaves the root. This driver refuses
one that leaves it through a symlink, at the moment it reads or writes, by
resolving the path to a real one with `isInsideTree` from
[is_path_confinement](https://pub.dev/packages/is_path_confinement). That
check guards against mistakes; it is not the wall. A link can be swapped
between the check and the open, which is why one driver runs per suit as
that suit, and not one privileged driver for every suit.

## The wire

One connection per request, one JSON value each way, with the codecs from
is_file_request_vocabulary and is_outcome_vocabulary:

- the caller sends one of `{"kind": "read", "path": ...}`,
  `{"kind": "readBytes", "path": ...}` or
  `{"kind": "write", "file": encodeFileText(...)}`, and closes its side;
- `FileDriver` answers one line, `encodeOutcome` of the result, and closes.

The airlock holds its own caller; this package has none, so nothing the
airlock runs depends on it.

## Running it

systemd starts it once per suit, from a template unit (infra's), which sets:

- `FILE_DRIVER_SOCKET`: where it listens, inside its `RuntimeDirectory`; it
  makes the socket `0660`, so the suit's group, which the airlock's user is
  in, can reach it;
- `FILE_DRIVER_CALLER`: the one user, by name or id, whose requests it
  carries out;
- `FILE_DRIVER_ROOT`: `/home/%i`; every path resolves under it;
- `FILE_DRIVER_MAX_BYTES`: optional, the cap above.

# Changelog

## 0.5.1

- Requires is_effects `^0.14.2`, so its lock matches the other builds
  deployed beside it. Nothing else changed.

## 0.5.0

- `write` is atomic: the text goes to a new file in a fresh folder beside
  the target, which is renamed over it, so a reader or a crash sees the
  whole old file or the whole new one, never a part.
- The new file takes the replaced file's permission bits (through libc
  `chmod`, which dart:io lacks), so a private file stays private and a
  script stays executable.
- A link inside the tree is written through to its file and kept, not
  replaced by a file.
- A file the suit cannot write is still refused, though a rename alone
  would replace it.
- A hard link to the replaced file keeps the old text: the rename gives the
  path a new file.

## 0.4.0

- Requires is_effects `^0.14.1`, whose `FileRequest` and
  `encodeFileRequest` / `decodeFileRequest` replace this package's own
  request codec, so the airlock's caller and the driver share one. The wire
  is unchanged.

## 0.3.0

- `FileDriverSocket` and `OutcomeUnknown` are gone: the airlock holds its
  own caller of the socket. The wire is unchanged.

## 0.2.0

- Requires is_effects `^0.13.0`, so a package depending on is_file_driver
  moves with it. Nothing in `ReadsAndWritesFiles` changed.

## 0.1.0

- `FileDriver`: a service on a Unix socket, answering only its caller's
  user, that reads and writes files under one root. It refuses a path that
  leaves the root through a symlink at the moment of reading or writing, and
  a file or text over its size cap. A text read keeps a leading byte order
  mark.
- `FileDriverSocket`: the airlock's side of that socket, its
  `ReadsAndWritesFiles`.
- `FileDriver.start` takes its caller as a `UserId` from
  is_unix_socket_user_check, and a connection whose user the kernel can't
  name is turned away. The service exits 78 when `FILE_DRIVER_CALLER`
  resolves to a uid that names no one user (65534, 4294967294, 4294967295).
- Requires is_effects `^0.12.0`, the version the airlock depends on.

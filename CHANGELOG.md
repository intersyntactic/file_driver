# Changelog

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

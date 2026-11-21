# Changelog

## 0.1.0 (unreleased)

- `TreeFileDriver`: `ReadsAndWritesFiles` under one root, refusing a path
  that leaves it through a symlink at the moment of reading or writing, and
  a file or text over its size cap.
- `FileDriverService`: the file driver as a service on a Unix socket,
  answering only its caller's user.
- `SocketFileDriver`: the airlock's side of that socket.

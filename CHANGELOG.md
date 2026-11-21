# Changelog

## 0.1.0 (unreleased)

- `FileDriver`: a service on a Unix socket, answering only its caller's
  user, that reads and writes files under one root. It refuses a path that
  leaves the root through a symlink at the moment of reading or writing, and
  a file or text over its size cap.
- `FileDriverSocket`: the airlock's side of that socket, its
  `ReadsAndWritesFiles`.

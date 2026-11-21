/// Runs the file driver (see `FileDriver`), as the suit a trajectory's agent
/// wears:
///
///     FILE_DRIVER_SOCKET=/run/file/suit-3/driver.sock \
///       FILE_DRIVER_CALLER=airlock \
///       FILE_DRIVER_ROOT=/home/suit-3 \
///       dart run is_file_driver:service
///
/// `FILE_DRIVER_CALLER` is the one user, by name or id, whose reads and
/// writes it carries out. `FILE_DRIVER_MAX_BYTES` is the most a file may
/// hold to be read, or a text to be written: 8 MiB unless set.
///
/// Exits 78 when it cannot start as configured. On SIGTERM or SIGINT it
/// closes.
library;

import 'dart:async';
import 'dart:io';

import 'package:is_file_driver/is_file_driver.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

Future<void> main() async {
  final env = Platform.environment;
  final [socket, caller, root] = [
    for (final name in [
      'FILE_DRIVER_SOCKET',
      'FILE_DRIVER_CALLER',
      'FILE_DRIVER_ROOT',
    ])
      env[name] ?? _fail('$name is not set'),
  ];
  final uid = _uidOf(caller) ?? _fail('no user $caller');
  final user =
      UserId.parse(uid) ??
      _fail('$caller is uid $uid, which the kernel uses for no one user');
  if (!Directory(root).existsSync()) _fail('no folder $root');
  final maxBytes = switch (env['FILE_DRIVER_MAX_BYTES']) {
    null => FileDriver.defaultMaxBytes,
    final raw => switch (int.tryParse(raw)) {
      final bytes? when bytes > 0 => bytes,
      _ => _fail('FILE_DRIVER_MAX_BYTES: not a number of bytes ($raw)'),
    },
  };
  final FileDriver driver;
  try {
    driver = await FileDriver.start(
      root: Directory(root),
      caller: user,
      socket: File(socket),
      maxBytes: maxBytes,
    );
  } on Object catch (e) {
    _fail('$e');
  }
  stdout.writeln(
    'listening on $socket for $caller, in $root, max $maxBytes bytes',
  );
  final stop = Completer<void>();
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) {
      if (!stop.isCompleted) stop.complete();
    });
  }
  await stop.future;
  await driver.close();
  exit(0);
}

int? _uidOf(String user) {
  if (int.tryParse(user) case final uid?) return uid;
  final r = Process.runSync('id', ['-u', user]);
  return r.exitCode == 0 ? int.tryParse(r.stdout.toString().trim()) : null;
}

Never _fail(String why) {
  stderr.writeln('is_file_driver service: $why');
  exit(78);
}

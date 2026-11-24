// Reads every regular file under each root through a FileDriver on its
// socket and checks the text it returns is the bytes on disk, or that a
// refusal is a file that truly isn't UTF-8; then writes each text through a
// driver on a scratch folder and checks the bytes match and nothing else is
// left there.
//
//   dart run tool/corpus_check.dart <scratch folder> <root>...
import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';
import 'package:is_file_driver/is_file_driver.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

import '../test/caller_over_socket.dart';

Future<void> main(List<String> args) async {
  final uid = int.parse('${(await Process.run('id', ['-u'])).stdout}'.trim());
  final me = UserId.parse(uid)!;
  // A Unix socket's path is short on macOS, so the sockets go under /tmp.
  final sockets = await Directory('/tmp').createTemp('fdc');
  var socketCount = 0;
  Future<(FileDriver, CallerOverSocket)> driverOn(Directory root) async {
    final socket = File('${sockets.path}/${socketCount++}');
    final driver = await FileDriver.start(
      root: root,
      caller: me,
      socket: socket,
    );
    return (driver, CallerOverSocket(socket));
  }

  final scratch = Directory(args.first)..createSync(recursive: true);
  final (writerDriver, writer) = await driverOn(scratch);
  final counts = {
    for (final k in const [
      'read as text',
      '  of which start with a BOM',
      '  of which contain CR',
      'nothing ran: not UTF-8',
      'nothing ran: other',
    ])
      k: 0,
  };
  void count(String k) => counts[k] = (counts[k] ?? 0) + 1;
  final failures = <String>[];
  const limit = 60000;
  var seen = 0;

  for (final rootPath in args.skip(1)) {
    final root = Directory(rootPath);
    final (readerDriver, reader) = await driverOn(root);
    final files = root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>();
    for (final file in files) {
      if (seen >= limit) break;
      final List<int> disk;
      try {
        if (file.lengthSync() > FileDriver.defaultMaxBytes) continue;
        disk = file.readAsBytesSync();
      } on FileSystemException {
        continue;
      }
      seen++;
      final rel = RelativePath(file.path.substring(root.path.length + 1));
      final strictUtf8 = _isUtf8(disk);
      final hasBom =
          disk.length >= 3 &&
          disk[0] == 0xEF &&
          disk[1] == 0xBB &&
          disk[2] == 0xBF;
      switch (await reader.read(rel)) {
        case Ran(output: ReadText(:final text)):
          count('read as text');
          if (hasBom) count('  of which start with a BOM');
          if (disk.contains(0x0D)) count('  of which contain CR');
          if (!_same(utf8.encode(text), disk)) failures.add('read: $rel');
          if (!strictUtf8) failures.add('read non-UTF-8: $rel');
          final out = RelativePath('f$seen');
          switch (await writer.write(FileText(out, text))) {
            case Ran():
              final back = File('${scratch.path}/${out.value}')
                  .readAsBytesSync();
              if (!_same(back, disk)) failures.add('round trip: $rel');
            case NothingRan(:final why):
              failures.add('write: nothing ran ($why): $rel');
            case StoppedPartway(:final why):
              failures.add('write: stopped partway ($why): $rel');
          }
          final left = scratch.listSync().map((e) => e.path).toList();
          if (left.length > 1) failures.add('left behind: $left');
          for (final e in scratch.listSync()) {
            e.deleteSync(recursive: true);
          }
        case Ran(output: ReadMissing()):
          failures.add('missing: $rel');
        case NothingRan(:final why):
          if (why.endsWith('is not UTF-8 text')) {
            count('nothing ran: not UTF-8');
            if (strictUtf8) failures.add('not UTF-8 but is: $rel');
          } else {
            count('nothing ran: other');
          }
        case StoppedPartway(:final why):
          failures.add('read: stopped partway ($why): $rel');
      }
      switch (await reader.readBytes(rel)) {
        case Ran(output: ReadBytes(:final bytes)):
          if (!_same(bytes, disk)) failures.add('readBytes: $rel');
        case Ran(output: ReadMissing()):
          failures.add('readBytes missing: $rel');
        case NothingRan(:final why):
          failures.add('readBytes: nothing ran ($why): $rel');
        case StoppedPartway(:final why):
          failures.add('readBytes: stopped partway ($why): $rel');
      }
    }
    await readerDriver.close();
  }
  await writerDriver.close();
  sockets.deleteSync(recursive: true);
  print('files: $seen');
  counts.forEach((k, v) => print('$k: $v'));
  print('failures: ${failures.length}');
  failures.take(20).forEach(print);
  exitCode = failures.isEmpty ? 0 : 1;
}

bool _isUtf8(List<int> bytes) {
  try {
    utf8.decode(bytes);
    return true;
  } on FormatException {
    return false;
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

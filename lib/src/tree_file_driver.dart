import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_path_confinement/is_path_confinement.dart';

/// [ReadsAndWritesFiles] for one root, the suit's home: every path is taken
/// under the root, and one that leaves it, by its text or through a symlink,
/// is [Refused] at the moment of reading or writing.
///
/// That check guards against mistakes; it is not the wall. A link can be
/// swapped between the check and the open, so what bounds a read or write is
/// this process's OS user, the suit, which can reach only what that suit can.
///
/// A read or write reaches it only once the airlock has decided and recorded
/// it, so it asks nobody.
final class TreeFileDriver implements ReadsAndWritesFiles {
  /// [maxBytes] is the most a file may hold to be read, or a text to be
  /// written: every byte is recorded.
  TreeFileDriver(this.root, {this.maxBytes = defaultMaxBytes});

  final Directory root;
  final int maxBytes;

  static const defaultMaxBytes = 8 << 20;

  /// The file's exact text, line endings and all; [Refused] when it is not
  /// UTF-8, never decoded loosely.
  @override
  Future<Outcome<ReadResult>> read(RelativePath path) async =>
      switch (await readBytes(path)) {
        Ran(output: ReadBytes(:final bytes)) => _decode(path, bytes),
        Ran(output: ReadMissing()) => const Ran(ReadMissing()),
        Refused(:final why) => Refused(why),
      };

  /// Keeps a leading byte order mark, which `utf8.decode` drops, so a read
  /// then a write leaves the file as it was.
  static Outcome<ReadResult> _decode(RelativePath path, Uint8List bytes) {
    final bom =
        bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF;
    try {
      final text = utf8.decode(bytes);
      return Ran(ReadText(bom ? '${String.fromCharCode(0xFEFF)}$text' : text));
    } on FormatException {
      return Refused('$path is not UTF-8 text');
    }
  }

  /// The file's exact bytes; [Refused] when it holds more than [maxBytes].
  @override
  Future<Outcome<BytesReadResult>> readBytes(RelativePath path) async {
    final file = _resolve(path);
    if (file == null) return Refused(_outside(path));
    if (_isFolder(file)) return Refused('$path is a folder');
    try {
      final opened = await file.open();
      try {
        // Read one byte past the cap rather than trust a size taken before
        // the read: the file can grow in between.
        final bytes = BytesBuilder(copy: false);
        while (bytes.length <= maxBytes) {
          final chunk = await opened.read(maxBytes + 1 - bytes.length);
          if (chunk.isEmpty) break;
          bytes.add(chunk);
        }
        if (bytes.length > maxBytes) {
          return Refused('$path is larger than $maxBytes bytes');
        }
        return Ran(ReadBytes(bytes.takeBytes()));
      } finally {
        await opened.close();
      }
    } on PathNotFoundException {
      return const Ran(ReadMissing());
    } on FileSystemException catch (e) {
      return Refused(_failed(path, e));
    }
  }

  /// Writes [FileText.text] as UTF-8, creating the folders it is in.
  @override
  Future<Outcome<Wrote>> write(FileText file) async {
    final path = file.path;
    final target = _resolve(path);
    if (target == null) return Refused(_outside(path));
    if (_isFolder(target)) return Refused('$path is a folder');
    final bytes = utf8.encode(file.text);
    if (bytes.length > maxBytes) {
      return Refused('the text for $path is larger than $maxBytes bytes');
    }
    try {
      final replaced = await target.exists();
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes, flush: true);
      return Ran(Wrote(replaced: replaced));
    } on FileSystemException catch (e) {
      return Refused(_failed(path, e));
    }
  }

  /// [path] under [root], or null when it resolves outside it. Both sides
  /// are resolved to real paths, so a symlink that leads out is outside.
  File? _resolve(RelativePath path) {
    final joined = path.value.isEmpty
        ? root.absolute.path
        : '${root.absolute.path}/${path.value}';
    return isInsideTree(root, joined) ? File(joined) : null;
  }

  static bool _isFolder(File file) =>
      FileSystemEntity.typeSync(file.path) == FileSystemEntityType.directory;

  static String _outside(RelativePath path) => '$path is outside the tree';

  static String _failed(RelativePath path, FileSystemException e) =>
      '$path: ${e.osError?.message ?? e.message}';
}

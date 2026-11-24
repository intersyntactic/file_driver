import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_path_confinement/is_path_confinement.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

import 'chmod.dart';

/// The file driver: a service on a Unix socket that reads and writes files
/// under its root, the suit's home, for the airlock's user alone.
///
/// A caller connects, sends one [FileRequest] as JSON ([encodeFileRequest])
/// and closes its side; the driver carries it out
/// and answers one line, the [Outcome] (see [encodeOutcome]), and closes.
/// Who is calling is read from the socket as the kernel reports it, never
/// from the request.
///
/// It runs as the suit, so a read or write can reach what that suit can and
/// no more: that is the wall. A path that leaves the root, by its text or
/// through a symlink, is also [Refused] at the moment of reading or writing,
/// but that guards against mistakes only, since a link can be swapped between
/// the check and the open.
///
/// A request reaches it only once the airlock has decided and recorded it,
/// so it asks nobody.
final class FileDriver {
  FileDriver._(
    this.root,
    this.maxBytes,
    this._socketUserCheck,
    this._socket,
    this._server,
  );

  final Directory root;

  /// The most a file may hold to be read, or a text to be written: every
  /// byte is recorded.
  final int maxBytes;

  final SocketUserCheck _socketUserCheck;
  final File _socket;
  final ServerSocket _server;

  static const defaultMaxBytes = 8 << 20;

  /// JSON escapes a character in at most six bytes, so a write the driver
  /// would take always fits.
  int get _maxRequest => 6 * maxBytes + 4096;

  /// Listens on [socket] for the user [caller] alone, reading and writing
  /// under [root]. The socket is made readable and writable by its group,
  /// the suit's own, which is how the airlock's user reaches it; a socket
  /// file nothing listens on is replaced. [socketUserReader] reads each
  /// caller's user from the kernel, the running kernel's by default.
  static Future<FileDriver> start({
    required Directory root,
    required UserId caller,
    required File socket,
    int maxBytes = defaultMaxBytes,
    SocketUserReader? socketUserReader,
  }) async {
    final server = await _bind(socket);
    final chmod = await Process.run('chmod', ['0660', socket.path]);
    if (chmod.exitCode != 0) {
      await server.close();
      throw FileSystemException('chmod 0660: ${chmod.stderr}', socket.path);
    }
    final driver = FileDriver._(
      root,
      maxBytes,
      SocketUserCheck.only(caller, reader: socketUserReader),
      socket,
      server,
    );
    driver._server.listen(driver._serve);
    return driver;
  }

  static Future<ServerSocket> _bind(File socket) async {
    final address = InternetAddress(
      socket.path,
      type: InternetAddressType.unix,
    );
    if (socket.existsSync()) {
      try {
        (await Socket.connect(address, 0)).destroy();
        throw StateError('a service is already listening on ${socket.path}');
      } on SocketException {
        socket.deleteSync();
      }
    }
    return ServerSocket.bind(address, 0);
  }

  Future<void> close() async {
    await _server.close();
    if (_socket.existsSync()) _socket.deleteSync();
  }

  Future<void> _serve(Socket socket) async {
    final verdict = _socketUserCheck.decide(socket);
    switch (verdict) {
      case Allowed():
        break;
      case NotAllowed():
      case Unread():
        stderr.writeln('is_file_driver: refused a caller, $verdict');
        socket.destroy();
        return;
    }
    try {
      final request = BytesBuilder(copy: false);
      var tooLarge = false;
      await for (final chunk in socket) {
        if (request.length + chunk.length > _maxRequest) {
          tooLarge = true;
          break;
        }
        request.add(chunk);
      }
      final answer = tooLarge
          ? _refusal('request too large')
          : await _answer(request.takeBytes());
      socket.add(utf8.encode('${jsonEncode(answer)}\n'));
      await socket.close();
    } on SocketException {
      socket.destroy();
    }
  }

  /// The encoded outcome of the request in [bytes].
  Future<Object?> _answer(Uint8List bytes) async {
    final FileRequest request;
    try {
      request = decodeFileRequest(jsonDecode(utf8.decode(bytes)));
    } on FormatException catch (e) {
      return _refusal('not a file request: ${e.message}');
    }
    return switch (request) {
      ReadFileRequest(:final path) => encodeOutcome(
        await _read(path),
        encodeReadResult,
      ),
      ReadFileBytesRequest(:final path) => encodeOutcome(
        await _readBytes(path),
        encodeBytesReadResult,
      ),
      WriteFileRequest(:final file) => encodeOutcome(
        await _write(file),
        encodeWrote,
      ),
    };
  }

  static Object? _refusal(String why) =>
      encodeOutcome<Never>(Refused(why), (output) => output);

  /// The file's exact text, line endings and all; [Refused] when it is not
  /// UTF-8, never decoded loosely.
  Future<Outcome<ReadResult>> _read(RelativePath path) async =>
      switch (await _readBytes(path)) {
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
  Future<Outcome<BytesReadResult>> _readBytes(RelativePath path) async {
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
  ///
  /// The text goes to a new file beside the old one, which is then renamed
  /// over it, so a reader sees the whole old file or the whole new one,
  /// never a part. The new file takes the old one's permissions, a link
  /// inside the root is written through rather than replaced, and a file
  /// the suit cannot write is refused as before.
  Future<Outcome<Wrote>> _write(FileText file) async {
    final path = file.path;
    final resolved = _resolve(path);
    if (resolved == null) return Refused(_outside(path));
    if (_isFolder(resolved)) return Refused('$path is a folder');
    final bytes = utf8.encode(file.text);
    if (bytes.length > maxBytes) {
      return Refused('the text for $path is larger than $maxBytes bytes');
    }
    Directory? scratch;
    try {
      final replaced = await resolved.exists();
      final target = replaced
          ? File(await resolved.resolveSymbolicLinks())
          : resolved;
      int? mode;
      if (replaced) {
        // Opening to append changes nothing, and fails as the write would
        // have on a file the suit cannot write.
        await (await target.open(mode: FileMode.append)).close();
        mode = (await target.stat()).mode & 0xFFF;
      }
      await target.parent.create(recursive: true);
      // A folder of its own, made with a name no other file has, beside the
      // target so the rename stays on one filesystem.
      scratch = await target.parent.createTemp('.file-driver-');
      final next = File('${scratch.path}/next');
      await next.writeAsBytes(bytes, flush: true);
      if (mode != null && !chmod(next.path, mode)) {
        return Refused('$path: could not keep its permissions');
      }
      await next.rename(target.path);
      return Ran(Wrote(replaced: replaced));
    } on FileSystemException catch (e) {
      return Refused(_failed(path, e));
    } finally {
      await scratch?.delete(recursive: true);
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

  static String _outside(RelativePath path) => '$path is outside the root';

  static String _failed(RelativePath path, FileSystemException e) =>
      '$path: ${e.osError?.message ?? e.message}';
}

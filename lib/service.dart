/// The file driver as a service of its own, which only the airlock's user
/// may call. It runs as the suit a trajectory's agent wears, so a read or
/// write can reach what that suit can and no more.
///
/// A caller connects to the Unix socket, sends one request (a `read`, a
/// `readBytes` or a `write`) as JSON and closes its side; the service
/// answers one line, the [Outcome] (see [encodeOutcome]), and closes.
/// [SocketFileDriver] is that caller.
///
/// Who is calling is read from the socket as the kernel reports it, never
/// from the request.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';

final class FileDriverService {
  FileDriverService._(
    this._driver,
    this._caller,
    this._socket,
    this._server,
    this._maxRequest,
  );

  final ReadsAndWritesFiles _driver;
  final int _caller;
  final File _socket;
  final ServerSocket _server;
  final int _maxRequest;

  /// Listens on [socket], reading and writing through [driver] for the user
  /// [caller] alone, and refusing a request larger than [maxRequest] bytes.
  /// The socket is made readable and writable by its group, the suit's own,
  /// which is how the airlock's user reaches it; a socket file nothing
  /// listens on is replaced.
  static Future<FileDriverService> start(
    ReadsAndWritesFiles driver,
    int caller,
    File socket, {
    required int maxRequest,
  }) async {
    final server = await _bind(socket);
    final chmod = await Process.run('chmod', ['0660', socket.path]);
    if (chmod.exitCode != 0) {
      await server.close();
      throw FileSystemException('chmod 0660: ${chmod.stderr}', socket.path);
    }
    final service = FileDriverService._(
      driver,
      caller,
      socket,
      server,
      maxRequest,
    );
    service._server.listen(service._serve);
    return service;
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
    final uid = _peerUid(socket);
    try {
      if (uid != _caller) {
        socket.destroy();
        return;
      }
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
          ? encodeOutcome<Never>(const Refused('request too large'), _never)
          : await _answer(request.takeBytes());
      socket.add(utf8.encode('${jsonEncode(answer)}\n'));
      await socket.close();
    } on SocketException {
      socket.destroy();
    }
  }

  /// The encoded outcome of the request in [bytes].
  Future<Object?> _answer(Uint8List bytes) async {
    final _FileRequest<Object?> request;
    try {
      request = _FileRequest.fromJson(jsonDecode(utf8.decode(bytes)));
    } on FormatException catch (e) {
      return encodeOutcome<Never>(
        Refused('not a file request: ${e.message}'),
        _never,
      );
    }
    return request.answer(_driver);
  }

  static Object? _never(Never output) => output;
}

/// [ReadsAndWritesFiles] in another process: sends each request to the
/// service at [socket] and returns its outcome.
final class SocketFileDriver implements ReadsAndWritesFiles {
  SocketFileDriver(this.socket);

  final File socket;

  @override
  Future<Outcome<ReadResult>> read(RelativePath path) => _ask(_Read(path));

  @override
  Future<Outcome<BytesReadResult>> readBytes(RelativePath path) =>
      _ask(_ReadBytes(path));

  @override
  Future<Outcome<Wrote>> write(FileText file) => _ask(_Write(file));

  /// [Refused] only when the service could not be reached, so nothing was
  /// sent. Once the request is sent, an answer that never comes throws
  /// [OutcomeUnknown]: a write may have happened, and no outcome in the
  /// contract says that.
  Future<Outcome<O>> _ask<O>(_FileRequest<O> request) async {
    final Socket s;
    try {
      s = await Socket.connect(
        InternetAddress(socket.path, type: InternetAddressType.unix),
        0,
      );
    } on SocketException catch (e) {
      return Refused('file driver: ${e.message}');
    }
    try {
      s.add(utf8.encode(jsonEncode(request.toJson())));
      await s.close();
      await for (final line
          in s
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        return decodeOutcome(jsonDecode(line), request.decodeOutput);
      }
      throw const OutcomeUnknown('the connection closed before it answered');
    } on SocketException catch (e) {
      throw OutcomeUnknown(e.message);
    } on FormatException catch (e) {
      throw OutcomeUnknown('bad answer: ${e.message}');
    }
  }
}

/// A request was sent to the file driver and its outcome never came back,
/// because [why]: a write may or may not have happened. Thrown, not recorded
/// as an outcome, since every outcome the contract has would claim to know.
final class OutcomeUnknown implements Exception {
  const OutcomeUnknown(this.why);

  final String why;

  @override
  String toString() => 'file driver: outcome unknown: $why';
}

/// One request on the wire, which carries itself out and encodes and
/// decodes its own output, so each output keeps its type end to end.
sealed class _FileRequest<O> {
  const _FileRequest();

  static _FileRequest<Object?> fromJson(Object? json) => switch (json) {
    {'kind': 'read', 'path': final Object? path} => _Read(
      decodeRelativePath(path),
    ),
    {'kind': 'readBytes', 'path': final Object? path} => _ReadBytes(
      decodeRelativePath(path),
    ),
    {'kind': 'write', 'file': final Object? file} => _Write(
      decodeFileText(file),
    ),
    _ => throw const FormatException(
      'not {"kind": "read" | "readBytes", "path"} or '
      '{"kind": "write", "file"}',
    ),
  };

  Object? toJson();

  Future<Outcome<O>> carryOut(ReadsAndWritesFiles driver);

  Object? encodeOutput(O output);

  O decodeOutput(Object? json, String field);

  /// The encoded outcome of carrying this out through [driver].
  Future<Object?> answer(ReadsAndWritesFiles driver) async =>
      encodeOutcome(await carryOut(driver), encodeOutput);
}

final class _Read extends _FileRequest<ReadResult> {
  const _Read(this.path);

  final RelativePath path;

  @override
  Object? toJson() => {'kind': 'read', 'path': encodeRelativePath(path)};

  @override
  Future<Outcome<ReadResult>> carryOut(ReadsAndWritesFiles driver) =>
      driver.read(path);

  @override
  Object? encodeOutput(ReadResult output) => encodeReadResult(output);

  @override
  ReadResult decodeOutput(Object? json, String field) =>
      decodeReadResult(json, field);
}

final class _ReadBytes extends _FileRequest<BytesReadResult> {
  const _ReadBytes(this.path);

  final RelativePath path;

  @override
  Object? toJson() => {'kind': 'readBytes', 'path': encodeRelativePath(path)};

  @override
  Future<Outcome<BytesReadResult>> carryOut(ReadsAndWritesFiles driver) =>
      driver.readBytes(path);

  @override
  Object? encodeOutput(BytesReadResult output) => encodeBytesReadResult(output);

  @override
  BytesReadResult decodeOutput(Object? json, String field) =>
      decodeBytesReadResult(json, field);
}

final class _Write extends _FileRequest<Wrote> {
  const _Write(this.file);

  final FileText file;

  @override
  Object? toJson() => {'kind': 'write', 'file': encodeFileText(file)};

  @override
  Future<Outcome<Wrote>> carryOut(ReadsAndWritesFiles driver) =>
      driver.write(file);

  @override
  Object? encodeOutput(Wrote output) => encodeWrote(output);

  @override
  Wrote decodeOutput(Object? json, String field) => decodeWrote(json, field);
}

/// The user on the other end of [socket], as the kernel reports it: Linux's
/// `SO_PEERCRED`, macOS's `LOCAL_PEERCRED`. Null where neither is known.
/// The same as is_program_driver's service reads its own.
int? _peerUid(Socket socket) {
  try {
    if (Platform.isLinux) {
      final ucred = socket.getRawOption(RawSocketOption(1, 17, Uint8List(12)));
      return ByteData.sublistView(ucred).getUint32(4, Endian.host);
    }
    if (Platform.isMacOS) {
      final xucred = socket.getRawOption(RawSocketOption(0, 1, Uint8List(76)));
      return ByteData.sublistView(xucred).getUint32(4, Endian.host);
    }
  } on SocketException {
    return null;
  }
  return null;
}

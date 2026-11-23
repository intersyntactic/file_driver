import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';

/// The caller's side of the socket, as the airlock holds its own: one
/// request in is_effects' JSON, then one answer line. An answer that never comes is
/// [Refused] here; the tests that look for one read the socket themselves.
final class CallerOverSocket implements ReadsAndWritesFiles {
  CallerOverSocket(this.socket);

  final File socket;

  @override
  Future<Outcome<ReadResult>> read(RelativePath path) =>
      _ask(ReadFileRequest(path), decodeReadResult);

  @override
  Future<Outcome<BytesReadResult>> readBytes(RelativePath path) =>
      _ask(ReadFileBytesRequest(path), decodeBytesReadResult);

  @override
  Future<Outcome<Wrote>> write(FileText file) =>
      _ask(WriteFileRequest(file), decodeWrote);

  Future<Outcome<O>> _ask<O>(
    FileRequest request,
    O Function(Object? json, String field) decodeOutput,
  ) async {
    final s = await Socket.connect(
      InternetAddress(socket.path, type: InternetAddressType.unix),
      0,
    );
    s.add(utf8.encode(jsonEncode(encodeFileRequest(request))));
    await s.close();
    final answer = await utf8.decoder.bind(s).join();
    if (answer.isEmpty) return const Refused('no answer');
    return decodeOutcome(jsonDecode(answer), decodeOutput);
  }
}

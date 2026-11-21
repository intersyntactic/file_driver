import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';

import 'request.dart';

/// The airlock's connection to the [FileDriver] at [socket]: each read or
/// write the airlock passes on is sent there, and its outcome returned.
final class FileDriverSocket implements ReadsAndWritesFiles {
  FileDriverSocket(this.socket);

  final File socket;

  @override
  Future<Outcome<ReadResult>> read(RelativePath path) =>
      _ask(ReadRequest(path), decodeReadResult);

  @override
  Future<Outcome<BytesReadResult>> readBytes(RelativePath path) =>
      _ask(ReadBytesRequest(path), decodeBytesReadResult);

  @override
  Future<Outcome<Wrote>> write(FileText file) =>
      _ask(WriteRequest(file), decodeWrote);

  /// [Refused] only when the driver could not be reached, so nothing was
  /// sent. Once the request is sent, an answer that never comes throws
  /// [OutcomeUnknown]: a write may have happened, and no outcome in the
  /// contract says that.
  Future<Outcome<O>> _ask<O>(
    FileRequest request,
    O Function(Object? json, String field) decodeOutput,
  ) async {
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
        return decodeOutcome(jsonDecode(line), decodeOutput);
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

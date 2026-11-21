import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_file_driver/service.dart';
import 'package:test/test.dart';

/// Holds files in memory and records every request it carries out.
final class Memory implements ReadsAndWritesFiles {
  final files = <RelativePath, Uint8List>{};
  final carriedOut = <Object>[];

  @override
  Future<Outcome<ReadResult>> read(RelativePath path) async {
    carriedOut.add(path);
    return Ran(switch (files[path]) {
      final bytes? => ReadText(utf8.decode(bytes)),
      null => const ReadMissing(),
    });
  }

  @override
  Future<Outcome<BytesReadResult>> readBytes(RelativePath path) async {
    carriedOut.add(path);
    return Ran(switch (files[path]) {
      final bytes? => ReadBytes(bytes),
      null => const ReadMissing(),
    });
  }

  @override
  Future<Outcome<Wrote>> write(FileText file) async {
    carriedOut.add(file);
    final replaced = files.containsKey(file.path);
    files[file.path] = utf8.encode(file.text);
    return Ran(Wrote(replaced: replaced));
  }
}

final me = int.parse((Process.runSync('id', ['-u']).stdout as String).trim());

void main() {
  late Directory dir;
  late File socket;
  late Memory driver;

  setUp(() async {
    // A Unix socket's path is short on macOS, so not under the test's own
    // temp directory.
    dir = await Directory('/tmp').createTemp('fd');
    socket = File('${dir.path}/s');
    driver = Memory();
  });
  tearDown(() => dir.delete(recursive: true));

  Future<FileDriverService> start({int? caller, int maxRequest = 1 << 20}) =>
      FileDriverService.start(
        driver,
        caller ?? me,
        socket,
        maxRequest: maxRequest,
      );

  Future<String> raw(String request) async {
    final s = await Socket.connect(
      InternetAddress(socket.path, type: InternetAddressType.unix),
      0,
    );
    s.add(utf8.encode(request));
    await s.close();
    return utf8.decoder.bind(s).join();
  }

  test('writes, reads and reads bytes for its caller', () async {
    final service = await start();
    addTearDown(service.close);
    final files = SocketFileDriver(socket);
    final path = RelativePath('notes/a.txt');

    final wrote = await files.write(FileText(path, 'a\r\nb'));
    expect((wrote as Ran<Wrote>).output.replaced, isFalse);
    final read = await files.read(path);
    expect(((read as Ran<ReadResult>).output as ReadText).text, 'a\r\nb');
    final bytes = await files.readBytes(path);
    expect(
      ((bytes as Ran<BytesReadResult>).output as ReadBytes).bytes,
      utf8.encode('a\r\nb'),
    );
    final missing = await files.read(RelativePath('none'));
    expect((missing as Ran<ReadResult>).output, isA<ReadMissing>());
  });

  test('passes a refusal back as the driver gave it', () async {
    final service = await FileDriverService.start(
      _Refusing(),
      me,
      socket,
      maxRequest: 1 << 20,
    );
    addTearDown(service.close);
    final out = await SocketFileDriver(socket).read(RelativePath('x'));
    expect((out as Refused).why, 'x is outside the tree');
  });

  test('answers one line, the outcome', () async {
    final service = await start();
    addTearDown(service.close);
    final answer = await raw('{"kind":"read","path":"a"}');
    expect(answer, '{"kind":"ran","output":{"kind":"missing"}}\n');
  });

  test('refuses what is not a file request, and carries nothing out', () async {
    final service = await start();
    addTearDown(service.close);
    for (final request in const [
      '{"kind":"delete","path":"a"}',
      '{"kind":"write","path":"a"}',
      '{"kind":"read","path":3}',
      'not json',
    ]) {
      final outcome = decodeOutcome<Never>(
        jsonDecode(await raw(request)),
        (_, field) => throw FormatException(field),
      );
      expect((outcome as Refused).why, startsWith('not a file request'));
    }
    expect(driver.carriedOut, isEmpty);
  });

  test('refuses a request larger than its cap, unread', () async {
    final service = await start(maxRequest: 100);
    addTearDown(service.close);
    final out = await SocketFileDriver(socket)
        .write(FileText(RelativePath('a'), 'x' * 200));
    expect((out as Refused).why, 'request too large');
    expect(driver.carriedOut, isEmpty);
  });

  test('answers nobody but its caller, and carries nothing out', () async {
    final service = await start(caller: me + 1);
    addTearDown(service.close);
    // From the caller's side a hang-up after the request is sent is a write
    // whose outcome never came back, which it cannot tell from a refusal.
    await expectLater(
      SocketFileDriver(socket).write(FileText(RelativePath('a'), 'x')),
      throwsA(isA<OutcomeUnknown>()),
    );
    expect(driver.carriedOut, isEmpty);
  });

  test('is refused when no service is listening', () async {
    final out = await SocketFileDriver(socket).read(RelativePath('a'));
    expect(out, isA<Refused>());
  });

  test('its socket is readable and writable by owner and group only', () async {
    final service = await start();
    addTearDown(service.close);
    expect(socket.statSync().modeString(), 'rw-rw----');
  });
}

final class _Refusing implements ReadsAndWritesFiles {
  @override
  Future<Outcome<ReadResult>> read(RelativePath path) async =>
      Refused('$path is outside the tree');

  @override
  Future<Outcome<BytesReadResult>> readBytes(RelativePath path) async =>
      Refused('$path is outside the tree');

  @override
  Future<Outcome<Wrote>> write(FileText file) async =>
      Refused('${file.path} is outside the tree');
}

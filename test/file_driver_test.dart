import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_file_driver/is_file_driver.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';
import 'package:test/test.dart';

import 'caller_over_socket.dart';

final uid = int.parse((Process.runSync('id', ['-u']).stdout as String).trim());
final me = UserId.parse(uid)!;

void main() {
  late Directory base;
  late Directory root;
  late Directory outside;
  late File socket;
  late CallerOverSocket files;

  setUp(() async {
    // A Unix socket's path is short on macOS, so not under the test's own
    // temp directory.
    base = await Directory('/tmp').createTemp('fd');
    root = Directory('${base.path}/suit')..createSync();
    outside = Directory('${base.path}/other')..createSync();
    File('${outside.path}/case.txt').writeAsStringSync('another mission');
    socket = File('${base.path}/s');
    final driver = await FileDriver.start(
      root: root,
      caller: me,
      socket: socket,
      maxBytes: 64,
    );
    addTearDown(driver.close);
    files = CallerOverSocket(socket);
  });
  tearDown(() => base.deleteSync(recursive: true));

  /// Every file and folder under [base] that is not under [root], so a test
  /// can show that nothing outside the root was created or changed.
  Map<String, String> outsideTheRoot() => {
    for (final e in base.listSync(recursive: true, followLinks: false))
      if (!e.path.startsWith('${root.path}/') && e.path != root.path)
        e.path: switch (e.statSync().type) {
          FileSystemEntityType.file => File(e.path).readAsStringSync(),
          final type => '$type',
        },
  };

  Future<String> readText(String path) async =>
      switch (await files.read(RelativePath(path))) {
        Ran(output: ReadText(:final text)) => text,
        final other => fail('$path: $other'),
      };

  String refusal(Outcome<Object?> outcome) => switch (outcome) {
    Refused(:final why) => why,
    Ran(:final output) => fail('ran: $output'),
  };

  /// Checking the check is not checking the write: these assert what is on
  /// the disk after the write, since a check can be right about a path and
  /// creating its folders can still change the disk it reasoned about.
  group('a path that leaves the root by its text', () {
    for (final rel in const [
      'q1/../../victim.txt',
      'q2/./../../victim.txt',
      'a/b/../../../victim.txt',
      '../victim.txt',
      '../other/case.txt',
    ]) {
      test('"$rel" is refused, and nothing outside is touched', () async {
        final before = outsideTheRoot();
        refusal(await files.write(FileText(RelativePath(rel), 'PWNED')));
        refusal(await files.read(RelativePath(rel)));
        refusal(await files.readBytes(RelativePath(rel)));
        expect(outsideTheRoot(), before);
      });
    }

    test('a .. that lands back inside the root is allowed', () async {
      await files.write(FileText(RelativePath('gone/../kept.txt'), 'x'));
      expect(File('${root.path}/kept.txt').readAsStringSync(), 'x');
    });

    test('an absolute path is taken under the root', () async {
      await files.write(FileText(RelativePath('/etc/hosts'), 'x'));
      expect(File('${root.path}/etc/hosts').readAsStringSync(), 'x');
    });
  });

  group('a path that leaves the root through a symlink', () {
    test('a link to a folder outside: read and write refused', () async {
      Link('${root.path}/out').createSync(outside.path);
      final before = outsideTheRoot();
      final why = refusal(await files.read(RelativePath('out/case.txt')));
      expect(why, 'out/case.txt is outside the root');
      refusal(await files.readBytes(RelativePath('out/case.txt')));
      refusal(await files.write(FileText(RelativePath('out/case.txt'), 'x')));
      refusal(await files.write(FileText(RelativePath('out/new/x'), 'x')));
      expect(outsideTheRoot(), before);
    });

    test('a link to a file outside: read and write refused', () async {
      Link('${root.path}/notes.txt').createSync('${outside.path}/case.txt');
      final before = outsideTheRoot();
      refusal(await files.read(RelativePath('notes.txt')));
      refusal(await files.write(FileText(RelativePath('notes.txt'), 'x')));
      expect(outsideTheRoot(), before);
    });

    test('a dangling link outward: the write does not create it', () async {
      Link('${root.path}/plant').createSync('${outside.path}/planted.txt');
      refusal(await files.write(FileText(RelativePath('plant'), 'x')));
      expect(File('${outside.path}/planted.txt').existsSync(), isFalse);
    });

    test('a relative link that climbs out is refused', () async {
      Link('${root.path}/up').createSync('../other');
      refusal(await files.read(RelativePath('up/case.txt')));
    });

    test('a link that stays inside is followed', () async {
      Directory('${root.path}/real').createSync();
      Link('${root.path}/alias').createSync('${root.path}/real');
      await files.write(FileText(RelativePath('alias/a.txt'), 'in'));
      expect(File('${root.path}/real/a.txt').readAsStringSync(), 'in');
      expect(await readText('alias/a.txt'), 'in');
    });
  });

  group('read', () {
    // The driver's read is the file, not a tool's view of its lines: its
    // text, encoded again, is the bytes on disk.
    const bom = [0xEF, 0xBB, 0xBF];
    for (final (name, bytes) in const [
      (
        'CRLF, a lone CR, LF, no newline at the end',
        [
          0x61, 0x0D, 0x0A, 0x62, 0x0D, 0x63, 0x0A, 0x64, //
        ],
      ),
      ('a BOM and CRLF', [...bom, 0x61, 0x0D, 0x0A, 0x62]),
      ('a BOM and nothing else', bom),
      ('two BOMs', [...bom, ...bom, 0x68, 0x69]),
      ('a BOM mid-file', [0x68, ...bom, 0x69]),
      ('an empty file', <int>[]),
      ('a NUL byte', [0x68, 0x00, 0x69]),
      (
        'two-, three- and four-byte characters',
        [
          0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80, //
        ],
      ),
    ]) {
      test('returns the exact text: $name', () async {
        File('${root.path}/f').writeAsBytesSync(bytes);
        expect(utf8.encode(await readText('f')), bytes);
      });
    }

    for (final (name, bytes) in const [
      ('half a BOM', [0xEF, 0xBB, 0x68]),
      ('a BOM then a byte UTF-8 never has', [...bom, 0xFF]),
      ('UTF-16 with its BOM', [0xFF, 0xFE, 0x68, 0x00]),
      ('Latin-1', [0x63, 0x61, 0x66, 0xE9]),
      ('a character cut off at the end', [0x68, 0xE2, 0x82]),
    ]) {
      test('refuses what is not UTF-8: $name', () async {
        File('${root.path}/f').writeAsBytesSync(bytes);
        expect(refusal(await files.read(RelativePath('f'))), contains('UTF-8'));
      });
    }

    test('a read then a write leaves a BOM file as it was', () async {
      final bytes = [...bom, 0x61, 0x0D, 0x0A];
      File('${root.path}/f').writeAsBytesSync(bytes);
      await files.write(FileText(RelativePath('f'), await readText('f')));
      expect(File('${root.path}/f').readAsBytesSync(), bytes);
    });

    test('a write then a read give back the same text', () async {
      const text = 'a\r\nb\r\né\u{1F600}';
      await files.write(FileText(RelativePath('rt.txt'), text));
      expect(await readText('rt.txt'), text);
      expect(File('${root.path}/rt.txt').readAsBytesSync(), utf8.encode(text));
    });

    test('refuses a file that is not UTF-8, naming it', () async {
      File('${root.path}/bin.dat').writeAsBytesSync([0x50, 0x4b, 0xff, 0xfe]);
      expect(
        refusal(await files.read(RelativePath('bin.dat'))),
        'bin.dat is not UTF-8 text',
      );
    });

    test('finds nothing where there is no file', () async {
      final read = await files.read(RelativePath('none.txt'));
      expect((read as Ran<ReadResult>).output, isA<ReadMissing>());
    });

    test('refuses a folder', () async {
      expect(refusal(await files.read(RelativePath.root)), ' is a folder');
    });
  });

  group('readBytes', () {
    test('returns the exact bytes, UTF-8 or not', () async {
      final bytes = Uint8List.fromList([0x50, 0x4b, 0x03, 0x04, 0xff, 0x00]);
      File('${root.path}/a.docx').writeAsBytesSync(bytes);
      final read = await files.readBytes(RelativePath('a.docx'));
      expect(((read as Ran<BytesReadResult>).output as ReadBytes).bytes, bytes);
    });

    test('finds nothing where there is no file', () async {
      final read = await files.readBytes(RelativePath('none'));
      expect((read as Ran<BytesReadResult>).output, isA<ReadMissing>());
    });
  });

  group('the size cap', () {
    test('a file of exactly the cap is read; one byte more is not', () async {
      File('${root.path}/at').writeAsStringSync('x' * 64);
      File('${root.path}/over').writeAsStringSync('x' * 65);
      expect(await readText('at'), 'x' * 64);
      expect(
        refusal(await files.readBytes(RelativePath('over'))),
        'over is larger than 64 bytes',
      );
      refusal(await files.read(RelativePath('over')));
    });

    test('a text over the cap is not written, in part or at all', () async {
      refusal(await files.write(FileText(RelativePath('big'), 'x' * 65)));
      expect(File('${root.path}/big').existsSync(), isFalse);
    });

    test('counts bytes, not characters', () async {
      // 22 four-byte characters are 88 bytes.
      final why = refusal(
        await files.write(FileText(RelativePath('e'), '\u{1F600}' * 22)),
      );
      expect(why, contains('larger than 64 bytes'));
    });

    test('a request too large to be a write is refused unread', () async {
      final out = await files.write(FileText(RelativePath('a'), 'x' * 5000));
      expect(refusal(out), 'request too large');
      expect(File('${root.path}/a').existsSync(), isFalse);
    });
  });

  group('write', () {
    test(
      'creates the folders it is in, and says it replaced nothing',
      () async {
        final wrote = await files.write(
          FileText(RelativePath('lib/src/new.dart'), 'x'),
        );
        expect((wrote as Ran<Wrote>).output.replaced, isFalse);
        expect(File('${root.path}/lib/src/new.dart').readAsStringSync(), 'x');
      },
    );

    test('says when it replaced a file', () async {
      await files.write(FileText(RelativePath('a'), 'one'));
      final wrote = await files.write(FileText(RelativePath('a'), 'two'));
      expect((wrote as Ran<Wrote>).output.replaced, isTrue);
      expect(File('${root.path}/a').readAsStringSync(), 'two');
    });

    test('refuses a folder', () async {
      Directory('${root.path}/dir').createSync();
      expect(
        refusal(await files.write(FileText(RelativePath('dir'), 'x'))),
        'dir is a folder',
      );
    });

    test('replaces the file whole: one open on the old file reads the old '
        'text after', () async {
      final old = File('${root.path}/a')..writeAsStringSync('old text');
      final opened = old.openSync();
      addTearDown(opened.closeSync);
      await files.write(FileText(RelativePath('a'), 'new'));
      expect(utf8.decode(opened.readSync(100)), 'old text');
      expect(old.readAsStringSync(), 'new');
    });

    test('leaves nothing beside the file', () async {
      await files.write(FileText(RelativePath('d/a'), 'one'));
      await files.write(FileText(RelativePath('d/a'), 'two'));
      expect(Directory('${root.path}/d').listSync().map((e) => e.path), [
        '${root.path}/d/a',
      ]);
    });

    for (final mode in ['600', '755', '640']) {
      test('keeps the permissions of the file it replaces: $mode', () async {
        final f = File('${root.path}/p')..writeAsStringSync('x');
        Process.runSync('chmod', [mode, f.path]);
        await files.write(FileText(RelativePath('p'), 'y'));
        expect(f.readAsStringSync(), 'y');
        expect((f.statSync().mode & 0x1FF).toRadixString(8), mode);
      });
    }

    test(
      'refuses a file the suit cannot write, and leaves it as it was',
      () async {
        final f = File('${root.path}/ro')..writeAsStringSync('kept');
        Process.runSync('chmod', ['444', f.path]);
        addTearDown(() => Process.runSync('chmod', ['644', f.path]));
        expect(
          refusal(await files.write(FileText(RelativePath('ro'), 'x'))),
          startsWith('ro: '),
        );
        expect(f.readAsStringSync(), 'kept');
        expect(root.listSync().map((e) => e.path), [f.path]);
      },
      // Root can write any file, so there is nothing to refuse.
      skip: uid == 0,
    );

    test('writes through a link inside the root, keeping the link', () async {
      File('${root.path}/real.txt').writeAsStringSync('old');
      Link('${root.path}/alias.txt').createSync('${root.path}/real.txt');
      await files.write(FileText(RelativePath('alias.txt'), 'new'));
      expect(FileSystemEntity.isLinkSync('${root.path}/alias.txt'), isTrue);
      expect(File('${root.path}/real.txt').readAsStringSync(), 'new');
    });
  });

  test(
    'a file it cannot open is refused with why, not as not UTF-8',
    () async {
      final locked = File('${root.path}/locked.txt')..writeAsStringSync('x');
      Process.runSync('chmod', ['000', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['600', locked.path]));
      final why = refusal(await files.read(RelativePath('locked.txt')));
      expect(why, startsWith('locked.txt: '));
      expect(why, isNot(contains('UTF-8')));
    },
    // Root can open any file, so there is nothing to refuse.
    skip: uid == 0,
  );

  group('the socket', () {
    /// What the driver at [at] answers [request]; empty when it hangs up,
    /// which it can do before the request is even sent.
    Future<String> raw(String request, [File? at]) async {
      final s = await Socket.connect(
        InternetAddress((at ?? socket).path, type: InternetAddressType.unix),
        0,
      );
      try {
        s.add(utf8.encode(request));
        await s.close();
        return await utf8.decoder.bind(s).join();
      } on SocketException {
        return '';
      }
    }

    const write = '{"kind":"write","file":{"path":"a","text":"x"}}';

    test('answers one line, the outcome', () async {
      expect(
        await raw('{"kind":"read","path":"a"}'),
        '{"kind":"ran","output":{"kind":"missing"}}\n',
      );
    });

    test('refuses what is not a file request, and does nothing', () async {
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
      expect(root.listSync(), isEmpty);
    });

    test('answers nobody but its caller, and writes nothing', () async {
      final other = File('${base.path}/t');
      final driver = await FileDriver.start(
        root: root,
        caller: UserId.parse(uid + 1)!,
        socket: other,
      );
      addTearDown(driver.close);
      expect(await raw(write, other), isEmpty);
      expect(File('${root.path}/a').existsSync(), isFalse);
    });

    test('answers no peer whose user the kernel cannot name', () async {
      final other = File('${base.path}/u');
      final driver = await FileDriver.start(
        root: root,
        caller: me,
        socket: other,
        socketUserReader: SocketUserReader(kernel: Kernel.other),
      );
      addTearDown(driver.close);
      expect(await raw(write, other), isEmpty);
      expect(File('${root.path}/a').existsSync(), isFalse);
    });

    test('is readable and writable by owner and group only', () async {
      expect(socket.statSync().modeString(), 'rw-rw----');
    });
  });
}

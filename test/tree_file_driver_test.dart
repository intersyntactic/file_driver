import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_file_driver/is_file_driver.dart';
import 'package:test/test.dart';

void main() {
  late Directory base;
  late Directory root;
  late Directory outside;
  late TreeFileDriver driver;

  setUp(() {
    base = Directory.systemTemp.createTempSync('fd');
    root = Directory('${base.path}/suit')..createSync();
    outside = Directory('${base.path}/other')..createSync();
    File('${outside.path}/case.txt').writeAsStringSync('another mission');
    driver = TreeFileDriver(root, maxBytes: 64);
  });
  tearDown(() => base.deleteSync(recursive: true));

  /// Every path under [base] that is not under [root], so a test can show
  /// that nothing outside the root was created or changed.
  Map<String, String> outsideTheRoot() => {
    for (final e in base.listSync(recursive: true, followLinks: false))
      if (!e.path.startsWith('${root.path}/') && e.path != root.path)
        if (e is File) e.path: e.readAsStringSync() else e.path: '',
  };

  Future<String> readText(String path) async =>
      switch (await driver.read(RelativePath(path))) {
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
  group('a path that leaves the tree by its text', () {
    for (final rel in const [
      'q1/../../victim.txt',
      'q2/./../../victim.txt',
      'a/b/../../../victim.txt',
      '../victim.txt',
      '../other/case.txt',
    ]) {
      test('"$rel" is refused, and nothing outside is touched', () async {
        final before = outsideTheRoot();
        refusal(await driver.write(FileText(RelativePath(rel), 'PWNED')));
        refusal(await driver.read(RelativePath(rel)));
        refusal(await driver.readBytes(RelativePath(rel)));
        expect(outsideTheRoot(), before);
      });
    }

    test('a .. that lands back inside the root is allowed', () async {
      await driver.write(FileText(RelativePath('gone/../kept.txt'), 'x'));
      expect(File('${root.path}/kept.txt').readAsStringSync(), 'x');
    });

    test('an absolute path is taken under the root', () async {
      await driver.write(FileText(RelativePath('/etc/hosts'), 'x'));
      expect(File('${root.path}/etc/hosts').readAsStringSync(), 'x');
    });
  });

  group('a path that leaves the tree through a symlink', () {
    test('a link to a folder outside: read and write refused', () async {
      Link('${root.path}/out').createSync(outside.path);
      final before = outsideTheRoot();
      final why = refusal(await driver.read(RelativePath('out/case.txt')));
      expect(why, 'out/case.txt is outside the tree');
      refusal(await driver.readBytes(RelativePath('out/case.txt')));
      refusal(await driver.write(FileText(RelativePath('out/case.txt'), 'x')));
      refusal(await driver.write(FileText(RelativePath('out/new/x'), 'x')));
      expect(outsideTheRoot(), before);
    });

    test('a link to a file outside: read and write refused', () async {
      Link('${root.path}/notes.txt').createSync('${outside.path}/case.txt');
      final before = outsideTheRoot();
      refusal(await driver.read(RelativePath('notes.txt')));
      refusal(await driver.write(FileText(RelativePath('notes.txt'), 'x')));
      expect(outsideTheRoot(), before);
    });

    test('a dangling link outward: the write does not create it', () async {
      Link('${root.path}/plant').createSync('${outside.path}/planted.txt');
      refusal(await driver.write(FileText(RelativePath('plant'), 'x')));
      expect(File('${outside.path}/planted.txt').existsSync(), isFalse);
    });

    test('a relative link that climbs out is refused', () async {
      Link('${root.path}/up').createSync('../other');
      refusal(await driver.read(RelativePath('up/case.txt')));
    });

    test('a link that stays inside is followed', () async {
      Directory('${root.path}/real').createSync();
      Link('${root.path}/alias').createSync('${root.path}/real');
      await driver.write(FileText(RelativePath('alias/a.txt'), 'in'));
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
        expect(
          refusal(await driver.read(RelativePath('f'))),
          contains('UTF-8'),
        );
      });
    }

    test('a read then a write leaves a BOM file as it was', () async {
      final bytes = [...bom, 0x61, 0x0D, 0x0A];
      File('${root.path}/f').writeAsBytesSync(bytes);
      await driver.write(FileText(RelativePath('f'), await readText('f')));
      expect(File('${root.path}/f').readAsBytesSync(), bytes);
    });

    test('a write then a read give back the same text', () async {
      const text = 'a\r\nb\r\né\u{1F600}';
      await driver.write(FileText(RelativePath('rt.txt'), text));
      expect(await readText('rt.txt'), text);
      expect(File('${root.path}/rt.txt').readAsBytesSync(), utf8.encode(text));
    });

    test('refuses a file that is not UTF-8', () async {
      File('${root.path}/bin.dat').writeAsBytesSync([0x50, 0x4b, 0xff, 0xfe]);
      expect(
        refusal(await driver.read(RelativePath('bin.dat'))),
        'bin.dat is not UTF-8 text',
      );
    });

    test('finds nothing where there is no file', () async {
      expect(
        await driver.read(RelativePath('none.txt')),
        isA<Ran<ReadResult>>().having(
          (r) => r.output,
          'output',
          isA<ReadMissing>(),
        ),
      );
    });

    test('refuses a folder', () async {
      expect(refusal(await driver.read(RelativePath.root)), ' is a folder');
    });
  });

  group('readBytes', () {
    test('returns the exact bytes, UTF-8 or not', () async {
      final bytes = Uint8List.fromList([0x50, 0x4b, 0x03, 0x04, 0xff, 0x00]);
      File('${root.path}/a.docx').writeAsBytesSync(bytes);
      final read = await driver.readBytes(RelativePath('a.docx'));
      expect(((read as Ran<BytesReadResult>).output as ReadBytes).bytes, bytes);
    });

    test('finds nothing where there is no file', () async {
      final read = await driver.readBytes(RelativePath('none'));
      expect((read as Ran<BytesReadResult>).output, isA<ReadMissing>());
    });
  });

  group('the size cap', () {
    test('a file of exactly the cap is read; one byte more is not', () async {
      File('${root.path}/at').writeAsStringSync('x' * 64);
      File('${root.path}/over').writeAsStringSync('x' * 65);
      expect(await readText('at'), 'x' * 64);
      expect(
        refusal(await driver.readBytes(RelativePath('over'))),
        'over is larger than 64 bytes',
      );
      refusal(await driver.read(RelativePath('over')));
    });

    test('a text over the cap is not written, in part or at all', () async {
      refusal(await driver.write(FileText(RelativePath('big'), 'x' * 65)));
      expect(File('${root.path}/big').existsSync(), isFalse);
    });

    test('counts bytes, not characters', () async {
      // 22 four-byte characters are 88 bytes.
      final why = refusal(
        await driver.write(FileText(RelativePath('e'), '\u{1F600}' * 22)),
      );
      expect(why, contains('larger than 64 bytes'));
    });
  });

  group('write', () {
    test(
      'creates the folders it is in, and says it replaced nothing',
      () async {
        final wrote = await driver.write(
          FileText(RelativePath('lib/src/new.dart'), 'x'),
        );
        expect((wrote as Ran<Wrote>).output.replaced, isFalse);
        expect(File('${root.path}/lib/src/new.dart').readAsStringSync(), 'x');
      },
    );

    test('says when it replaced a file', () async {
      await driver.write(FileText(RelativePath('a'), 'one'));
      final wrote = await driver.write(FileText(RelativePath('a'), 'two'));
      expect((wrote as Ran<Wrote>).output.replaced, isTrue);
      expect(File('${root.path}/a').readAsStringSync(), 'two');
    });

    test('refuses a folder', () async {
      Directory('${root.path}/dir').createSync();
      expect(
        refusal(await driver.write(FileText(RelativePath('dir'), 'x'))),
        'dir is a folder',
      );
    });
  });

  test(
    'a file it cannot open is refused with why, not as not UTF-8',
    () async {
      final locked = File('${root.path}/locked.txt')..writeAsStringSync('x');
      Process.runSync('chmod', ['000', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['600', locked.path]));
      final why = refusal(await driver.read(RelativePath('locked.txt')));
      expect(why, startsWith('locked.txt: '));
      expect(why, isNot(contains('UTF-8')));
    },
    // Root can open any file, so there is nothing to refuse.
    skip: Process.runSync('id', ['-u']).stdout.toString().trim() == '0',
  );
}

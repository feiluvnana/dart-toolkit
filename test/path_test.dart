import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dart_toolkit/path.dart';
import 'package:dart_toolkit/src/fs/io.dart' show sandbox;
import 'package:test/test.dart';

void main() {
  group('fs glob, Seeker and sandbox', () {
    late io.Directory tmp;
    setUp(() async {
      tmp = await io.Directory.systemTemp.createTemp('tk_fs_');
      await io.Directory('${tmp.path}/a/b').create(recursive: true);
      await io.File('${tmp.path}/a/x.dart').writeAsString('x');
      await io.File('${tmp.path}/a/b/y.dart').writeAsString('y');
      await io.File('${tmp.path}/a/b/z.txt').writeAsString('z');
      await io.File('${tmp.path}/top.dart').writeAsString('t');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('** spans zero or more dirs; * stays in one segment', () async {
      final dir = Dir(tmp.path);
      expect((await dir.find('**/*.dart')).map((f) => f.name).toSet(), {'x.dart', 'y.dart', 'top.dart'});
      expect((await dir.find('a/**/*.dart')).map((f) => f.name).toSet(), {'x.dart', 'y.dart'});
      expect((await dir.find('*.dart')).map((f) => f.name).toSet(), {'top.dart'});
      expect((await dir.find('a/*.dart')).map((f) => f.name).toSet(), {'x.dart'});
    });

    test('?/[... ]/{a,b} classes and escapes', () async {
      final dir = Dir(tmp.path);
      expect((await dir.find('a/?.dart')).map((f) => f.name), ['x.dart']);
      expect((await dir.find('a/[x-z].dart')).map((f) => f.name), ['x.dart']);
      expect((await dir.find('**/*.{dart,txt}')).length, 4);
    });

    test('bad patterns: empty/unclosed are FormatException; absolute/.. are ArgumentError', () async {
      final dir = Dir(tmp.path);
      await expectLater(dir.find(''), throwsFormatException);
      await expectLater(dir.find('a/[x.dart'), throwsFormatException);
      await expectLater(dir.find('a/{x.dart'), throwsFormatException);
      await expectLater(dir.find('/abs'), throwsArgumentError);
      await expectLater(dir.find('../out'), throwsArgumentError);
    });

    test('a missing directory is PathNotFoundException', () async {
      await expectLater(Dir('${tmp.path}/gone').find('**'), throwsA(isA<io.PathNotFoundException>()));
    });

    test('File seek resumes a half-read file with the identical tail', () async {
      final path = '${tmp.path}/big.bin';
      final data = Uint8List.fromList(List.generate(200000, (i) => i & 0xFF));
      await io.File(path).writeAsBytes(data);
      final r = await File(path).reader();
      try {
        final head = Uint8List(1000);
        expect(await r.read(head), 1000);
        expect(head, data.sublist(0, 1000));
        final seeker = r as Seeker;
        expect(await seeker.seek(150000), 150000);
        final tail = BytesBuilder(copy: false);
        final chunk = Uint8List(8192);
        while (true) {
          final n = await r.read(chunk);
          if (n <= 0) break;
          tail.add(chunk.sublist(0, n));
        }
        expect(tail.takeBytes(), data.sublist(150000));
        await expectLater(seeker.seek(-1), throwsArgumentError);
      } finally {
        await r.close();
      }
    });

    test('sandbox refuses escape/absolute/NUL', () async {
      await expectLater(sandbox(tmp.path, '../out'), throwsA(isA<SecurityException>()));
      await expectLater(sandbox(tmp.path, '/abs'), throwsA(isA<SecurityException>()));
      await expectLater(sandbox(tmp.path, 'a\x00b'), throwsA(isA<SecurityException>()));
      final ok = await sandbox(tmp.path, 'a/../top.dart');
      expect(ok.endsWith('top.dart'), isTrue);
    });
  });

  group('fs native wiring', () {
    late io.Directory tmp;
    setUp(() async {
      tmp = await io.Directory.systemTemp.createTemp('tk_phasec_fs_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('text() on malformed UTF-8 is a FormatException naming the file', () async {
      final path = '${tmp.path}/bad.txt';
      await io.File(path).writeAsBytes([0x68, 0x69, 0xFF, 0xFE, 0x0A]);
      await expectLater(
        File(path).text(),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(path))),
      );
      // Well-formed text still reads.
      await io.File(path).writeAsString('hi ✓\n');
      expect(await File(path).text(), 'hi ✓\n');
    });

    test('write over a held handle lands the new bytes', () async {
      // The holder lives in a child process: the native rename retries
      // synchronously (blocking this isolate's event loop), so a Timer-based
      // release here would never fire mid-retry.
      final holder = io.File('${tmp.path}/holder.dart')
        ..writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final held = File(args[0]).openSync();
  print('holding');
  await Future<void>.delayed(const Duration(seconds: 2));
  held.closeSync();
}
''');
      final path = '${tmp.path}/held.txt';
      await io.File(path).writeAsString('old');
      final child = await io.Process.start(io.Platform.executable, [holder.path, path]);
      try {
        // Wait until the child holds the file (error 5/32 on Windows from here on).
        await child.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
        await File(path).write('new');
      } finally {
        await child.exitCode;
        await holder.delete();
      }
      expect(await io.File(path).readAsString(), 'new');
    });

    test('copy then move round-trip bytes', () async {
      final data = Uint8List.fromList(List.generate(100000, (i) => i & 0xFF));
      final src = File('${tmp.path}/a.bin');
      await io.File(src.path).writeAsBytes(data);
      final copied = await src.copy(File('${tmp.path}/b.bin'));
      expect(await copied.bytes(), data);
      final moved = await copied.move(File('${tmp.path}/c.bin'));
      expect(await moved.bytes(), data);
      expect(await copied.exists(), isFalse);
    });

    test('chmod through the seam does not throw', () async {
      final path = '${tmp.path}/m.txt';
      await io.File(path).writeAsString('x');
      await File(path).chmod(420); // 0644
      expect(await io.File(path).exists(), isTrue);
    });

    test('write is atomic: a failed write leaves the old content', () async {
      final dir = await Dir.temp();
      try {
        final f = dir.file('c.json');
        await f.write('old');
        await expectLater(f.write(Object()), throwsArgumentError); // not String/List<int>
        expect(await f.text(), 'old');
        expect((await dir.files()).map((f) => f.name), ['c.json']); // no temp left behind
      } finally {
        await dir.drop();
      }
    });

    test('files() and dirs() split the children', () async {
      final dir = await Dir.temp();
      try {
        await dir.file('a.txt').write('a');
        await dir.dir('sub').make();
        expect((await dir.files()).map((f) => f.name), ['a.txt']);
        expect((await dir.dirs()).map((d) => d.name), ['sub']);
      } finally {
        await dir.drop();
      }
    });

    test('symlink is called on the source', () async {
      final dir = await Dir.temp();
      try {
        final data = dir.file('data.txt');
        await data.write('x');
        final link = await data.symlink(dir.file('short'));
        expect(await link.isLink(), isTrue);
        expect((await link.target())?.path, data.path);
      } finally {
        await dir.drop();
      }
    }, testOn: '!windows');

    test('write keeps the mode bits', () async {
      final f = File('${tmp.path}/script.sh');
      await f.write('#!/bin/sh\n');
      await f.chmod(493); // 0755
      await f.write('#!/bin/sh\necho hi\n');
      expect(io.FileStat.statSync(f.path).mode & 511, 493); // 0777 mask, 0755 kept
      expect(await f.text(), '#!/bin/sh\necho hi\n');
    }, testOn: '!windows');

    test('write through a symlink keeps the link and lands in the target', () async {
      final target = File('${tmp.path}/real.txt');
      await target.write('old');
      final link = await target.symlink(File('${tmp.path}/link.txt'));
      expect(await link.isLink(), isTrue);
      await link.write('new');
      expect(await io.FileSystemEntity.isLink(link.path), isTrue);
      expect(await target.text(), 'new');
    }, testOn: '!windows');
  });
}

// Phase A exit gate (reports/roadmap.md): safe foundation, pure Dart.
// Core pipe spine, hash blocking fixes, fs glob + Seeker, process two-ended
// pipe — all green, `api_names` untouched (it covers the legacy surface).

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dart_toolkit/core.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/path.dart';
import 'package:dart_toolkit/process.dart';
import 'package:test/test.dart';

String hexOf(Uint8List b) => DigestValue(b).hex;

void main() {
  group('core pipe spine', () {
    test('Reader pipes to Writer with the byte count', () async {
      final src = BufferReader(Uint8List.fromList([1, 2, 3]));
      final dst = BufferWriter();
      expect(await src.pipe(dst), 3);
      expect(dst.take(), [1, 2, 3]);
    });

    test('bytes pipe as one write; awaitable bytes pipe once arrived', () async {
      final dst = BufferWriter();
      expect(await Uint8List.fromList([9, 9]).pipe(dst), 2);
      final dst2 = BufferWriter();
      expect(await Future.value(Uint8List.fromList([7])).pipe(dst2), 1);
      expect(dst2.take(), [7]);
    });

    test('onProgress is a display-only tap of bytes so far', () async {
      final seen = <int>[];
      await BufferReader(Uint8List.fromList(List.filled(100, 1))).pipe(BufferWriter(), onProgress: seen.add);
      expect(seen.last, 100);
      expect(seen, orderedEquals(seen..sort()));
    });

    test('FnReader/FnWriter adapt callbacks as a Reader/Writer pair', () async {
      final data = Uint8List.fromList([1, 2, 3, 4]);
      var pos = 0;
      final reader = FnReader((buf) async {
        if (pos >= data.length) return 0;
        final n = buf.length < data.length - pos ? buf.length : data.length - pos;
        buf.setRange(0, n, data, pos);
        pos += n;
        return n;
      });
      final collected = <int>[];
      final writer = FnWriter((chunk) async {
        final bytes = chunk is String ? utf8.encode(chunk) : (chunk as List<int>);
        collected.addAll(bytes);
        return bytes.length;
      });
      expect(await reader.pipe(writer, buf: 2), 4);
      expect(collected, [1, 2, 3, 4]);
    });

    test('Writer contract: String UTF-8, bytes verbatim, else ArgumentError', () async {
      final w = BufferWriter();
      await w.write('hé');
      await w.write([255]);
      expect(w.take(), [...utf8.encode('hé'), 255]);
      await expectLater(w.write(42), throwsArgumentError);
    });

    test('AlgoWriter sinks a pipe: File bytes hash to the one-shot digest', () async {
      final tmp = await io.Directory.systemTemp.createTemp('lib2_pipe_');
      try {
        final file = io.File('${tmp.path}/x.bin');
        final data = Uint8List.fromList(List.generate(10000, (i) => i & 0xFF));
        await file.writeAsBytes(data);
        final src = await File.open(file.path);
        final hasher = Hash.sha256.writer();
        expect(await src.pipe(hasher), data.length);
        await src.close();
        expect(hexOf(hasher.finish()), hexOf(Hash.sha256(data)));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });

  group('hash blocking fixes', () {
    test('known answers incl. xxh3/xxh64 vectors', () {
      final abc = utf8.encode('abc');
      expect(hexOf(Hash.sha256(abc)), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(hexOf(Hash.sha256('')), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(hexOf(Hash.md5(abc)), '900150983cd24fb0d6963f7d28e17f72');
      expect(hexOf(Hash.crc32(abc)), '352441c2');
      expect(hexOf(Hash.blake3(abc)), '6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85');
      expect(hexOf(Hash.xxh64(abc)), '44bc2cf5ad770999');
      expect(hexOf(Hash.xxh3(abc)), '78af5f94892f3950');
      expect(hexOf(Hash.xxh3(<int>[])), '2d06800538d394c2');
    });

    test('streaming writer equals the one-shot across block boundaries', () async {
      for (final n in [0, 1, 55, 56, 57, 63, 64, 65, 111, 112, 113, 127, 128, 129, 200, 1000]) {
        final data = Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) & 0xFF));
        for (final algo in [Hash.md5, Hash.sha256, Hash.sha512, Hash.crc32, Hash.blake3, Hash.xxh64, Hash.xxh3]) {
          final w = algo.writer();
          var i = 0;
          while (i < data.length) {
            final take = (i % 13) + 1;
            final end = i + take > data.length ? data.length : i + take;
            await w.write(Uint8List.sublistView(data, i, end));
            i = end;
          }
          expect(hexOf(w.finish()), hexOf(algo(data)), reason: '${algo.name} len=$n');
        }
      }
    });

    test('file() streams and equals the one-shot; HMAC file equals keyed one-shot', () async {
      final tmp = await io.Directory.systemTemp.createTemp('lib2_hashfile_');
      try {
        final data = Uint8List.fromList(List.generate(200000, (i) => (i * 7 + 3) & 0xFF));
        final path = '${tmp.path}/big.bin';
        await io.File(path).writeAsBytes(data);
        expect(hexOf(await Hash.sha256.file(path)), hexOf(Hash.sha256(data)));
        expect(hexOf(await Hash.xxh3.file(File(path))), hexOf(Hash.xxh3(data)));
        expect(hexOf(await Hash.sha256.file(path, key: 'Jefe')), hexOf(Hash.sha256(data, key: 'Jefe')));
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('RFC 4231 HMAC case 2 and checksum key refusal', () {
      expect(
        hexOf(Hash.sha256('what do ya want for nothing?', key: 'Jefe')),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
      expect(() => Hash.crc32('x', key: 'k'), throwsArgumentError);
      expect(() => Hash.xxh3('x', key: 'k'), throwsArgumentError);
    });

    test('hashing a missing file names it in PathNotFoundException', () async {
      await expectLater(
        Hash.sha256.file('/nope/absent.bin'),
        throwsA(isA<io.PathNotFoundException>().having((e) => e.path, 'path', '/nope/absent.bin')),
      );
    });

    test('call(File) directs to the async file() noun', () {
      expect(() => Hash.sha256(File('x')), throwsArgumentError);
    });

    test('constant-time checks: matches, constantEquals, double finish', () async {
      final d = Hash.sha256('abc');
      expect(d.matches(hexOf(d).toUpperCase()), isTrue);
      expect(d.matches(hexOf(Hash.sha256('x'))), isFalse);
      expect(d.matches('ab'), isFalse, reason: 'another length');
      expect(() => d.matches('not hex!!'), throwsFormatException);
      expect(Uint8List.fromList([1, 2]).constantEquals([1, 2]), isTrue);
      expect(Uint8List.fromList([1, 2]).constantEquals([1, 3]), isFalse);
      expect(Uint8List.fromList([1, 2]).constantEquals([1]), isFalse);
      final w = Hash.sha256.writer();
      await w.write('abc');
      w.finish();
      expect(() => w.finish(), throwsStateError);
    });

    test('Hex and Base64 nouns round-trip', () {
      expect(Hex.encode([0xDE, 0xAD, 0xBE, 0xEF]), 'deadbeef');
      expect(Hex.decode('DEADbeef'), [0xDE, 0xAD, 0xBE, 0xEF]);
      expect(() => Hex.decode('abc'), throwsFormatException);
      expect(() => Hex.decode('zz'), throwsFormatException);
      expect(Base64.encode('hello'), 'aGVsbG8=');
      expect(Base64.decode('aGVsbG8='), utf8.encode('hello'));
    });
  });

  group('fs glob, Seeker and sandbox', () {
    late io.Directory tmp;
    setUp(() async {
      tmp = await io.Directory.systemTemp.createTemp('lib2_fs_');
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
      final f = await File.open(path);
      try {
        final head = Uint8List(1000);
        expect(await f.read(head), 1000);
        expect(head, data.sublist(0, 1000));
        expect(await f.seek(150000), 150000);
        final tail = BytesBuilder(copy: false);
        final chunk = Uint8List(8192);
        while (true) {
          final n = await f.read(chunk);
          if (n <= 0) break;
          tail.add(chunk.sublist(0, n));
        }
        expect(tail.takeBytes(), data.sublist(150000));
        await expectLater(f.seek(-1), throwsArgumentError);
      } finally {
        await f.close();
      }
    });

    test('sandbox refuses escape/absolute/NUL; Path starts/equals are canonical', () async {
      await expectLater(sandbox(tmp.path, '../out'), throwsA(isA<SecurityException>()));
      await expectLater(sandbox(tmp.path, '/abs'), throwsA(isA<SecurityException>()));
      await expectLater(sandbox(tmp.path, 'a\x00b'), throwsA(isA<SecurityException>()));
      final ok = await sandbox(tmp.path, 'a/../top.dart');
      expect(ok.str.endsWith('top.dart'), isTrue);
      expect(Path('${tmp.path}/a/../top.dart').starts(Path(tmp.path)), isTrue);
      expect(Path('${tmp.path}/a/../../out').starts(Path(tmp.path)), isFalse);
      expect(Path('a/./b').equals(Path('a/b')), isTrue);
    });
  });

  group('process two-ended pipe', () {
    late io.Directory tmp;
    late String dart;
    setUp(() async {
      tmp = await io.Directory.systemTemp.createTemp('lib2_proc_');
      dart = io.Platform.executable;
      io.File('${tmp.path}/slow.dart').writeAsStringSync('''
Future<void> main() async {
  for (var i = 0; i < 5; i++) {
    print('line\$i');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
''');
      io.File('${tmp.path}/echo.dart').writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    print('got:\$line');
  }
}
''');
      io.File('${tmp.path}/sleep.dart').writeAsStringSync('''
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 60));
}
''');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('line() yields before exit; lines() streams the rest', () async {
      final p = Process(dart, ['${tmp.path}/slow.dart']);
      expect(await p.line(), 'line0');
      final rest = <String>[];
      await for (final l in p.lines()) {
        rest.add(l);
      }
      expect(rest, ['line1', 'line2', 'line3', 'line4']);
      expect(await p.wait(), 0);
    });

    test('write/line round-trip; closeStdin gives null at EOF', () async {
      final p = Process(dart, ['${tmp.path}/echo.dart']);
      await p.write('hello\n');
      expect(await p.line(), 'got:hello');
      await expectLater(p.write(42), throwsArgumentError);
      await p.closeStdin();
      expect(await p.line(), isNull);
      expect(await p.wait(), 0);
    });

    test('p1.pipe(p2) then text() after closeStdin', () async {
      final p1 = Process(dart, ['${tmp.path}/slow.dart']);
      final p2 = Process(dart, ['${tmp.path}/echo.dart']);
      expect(await p1.pipe(p2), greaterThan(0));
      await p2.closeStdin();
      final out = await p2.text();
      expect(out.split('\n').first.trim(), 'got:line0');
      expect(await p1.wait(), 0);
      expect(await p2.wait(), 0);
    });

    test('wait(timeout:) throws TimeoutException and reaps the child', () async {
      final p = Process(dart, ['${tmp.path}/sleep.dart']);
      await expectLater(p.wait(timeout: const Duration(seconds: 2)), throwsA(isA<TimeoutException>()));
      expect(await p.wait(), isNot(0));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('cancel() kills and reaps; second cancel is quiet', () async {
      final p = Process(dart, ['${tmp.path}/sleep.dart']);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await p.cancel();
      expect(await p.exitCode, isNot(0));
      await p.cancel();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a missing executable is ProcessException 127', () async {
      await expectLater(
        Process('definitely-not-a-real-binary-xyz', []).wait(),
        throwsA(isA<ProcessException>().having((e) => e.code, 'code', 127)),
      );
    });

    test('run() one-shot still captures', () async {
      final res = await Process.run(dart, ['--version']);
      expect(res.ok, isTrue);
    });
  });
}

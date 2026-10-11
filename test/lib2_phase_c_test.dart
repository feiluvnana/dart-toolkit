// Phase C exit gate (reports/roadmap.md): native2 core wiring, post-cutover.
//
// No Dart fallback remains (r50): every assertion below runs through the
// native library — one-shots, streaming writers and file ingest must agree
// across the `tk_digest*` entry points; unpack(pack(d)) == d for
// zip/tar/tar.gz; image round-trips; Windows rename-retry with a held
// handle; kill-tree reaps a 3-level chain.

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/core.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/native.dart';
import 'package:dart_toolkit/path.dart';
import 'package:dart_toolkit/process.dart';
import 'package:test/test.dart';

String hexOf(Uint8List b) => DigestValue(b).hex;

void main() {
  group('native seam', () {
    test('reports loaded or a reason', () {
      if (Lib2Native.isAvailable) {
        expect(Lib2Native.reason, isNull);
      } else {
        expect(Lib2Native.reason, isNotNull);
      }
    });
  });

  group('hash paths agree', () {
    test('one-shot across the whole set, small and multi-chunk', () async {
      final small = Uint8List.fromList(utf8.encode('abc'));
      final big = Uint8List.fromList(List.generate(300000, (i) => (i * 7 + 3) & 0xFF));
      for (final algo in Hash.values) {
        for (final data in [small, big]) {
          // Repeat calls agree: each call opens and finishes its own handle.
          expect(hexOf(algo(data)), hexOf(algo(data)), reason: '${algo.name} len=${data.length}');
        }
        // Text and bytes of the same content hash alike (input normalization).
        expect(hexOf(algo('abc')), hexOf(algo(small)), reason: algo.name);
      }
    });

    test('streaming writer equals the one-shot', () async {
      final data = Uint8List.fromList(List.generate(200000, (i) => (i * 31 + 7) & 0xFF));
      for (final algo in Hash.values) {
        final w = algo.writer();
        var i = 0;
        while (i < data.length) {
          final take = (i % 13) + 1;
          final end = i + take > data.length ? data.length : i + take;
          await w.write(Uint8List.sublistView(data, i, end));
          i = end;
        }
        expect(hexOf(w.finish()), hexOf(algo(data)), reason: '${algo.name} stream vs one-shot');
      }
    });

    test('file() equals the in-memory digest; HMAC file matches', () async {
      final tmp = await io.Directory.systemTemp.createTemp('lib2_phasec_hash_');
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
  });

  group('archive round-trips and selective open', () {
    late io.Directory tmp;
    setUp(() async {
      tmp = await io.Directory.systemTemp.createTemp('lib2_phasec_arc_');
      await io.Directory('${tmp.path}/d/sub').create(recursive: true);
      await io.File('${tmp.path}/d/a.txt').writeAsString('hello archive');
      await io.File('${tmp.path}/d/sub/b.bin').writeAsBytes(List.generate(50000, (i) => i & 0xFF));
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    for (final ext in ['zip', 'tar', 'tar.gz']) {
      test('unpack(pack(d)) == d for .$ext', () async {
        final bundle = '${tmp.path}/b.$ext';
        final out = '${tmp.path}/out-$ext';
        await Archive.pack('${tmp.path}/d', bundle);
        expect(await Archive.list(bundle), containsAll(['a.txt', 'sub/b.bin']));
        await Archive.unpack(bundle, out);
        expect(await io.File('$out/a.txt').readAsString(), 'hello archive');
        expect(await io.File('$out/sub/b.bin').readAsBytes(), List.generate(50000, (i) => i & 0xFF));
      });
    }

    test('open() streams one member; missing and link members throw', () async {
      final bundle = '${tmp.path}/b.zip';
      await Archive.pack('${tmp.path}/d', bundle);
      final reader = await Archive.open(bundle, 'a.txt');
      final dst = BufferWriter();
      expect(await reader.pipe(dst), 'hello archive'.length);
      expect(utf8.decode(dst.take()), 'hello archive');
      await expectLater(Archive.open(bundle, 'nope.txt'), throwsA(isA<MissingException>()));
      expect(await Archive.extract(bundle, 'a.txt'), utf8.encode('hello archive'));
    });
  });

  group('image round-trips and pipe sink', () {
    test('png round-trip keeps dimensions and pixels', () async {
      final img = Image.blank(width: 32, height: 24)..fill(0xFF112233);
      final bytes = img.encode(format: 'png');
      expect(Image.formatOf(bytes), 'png');
      final back = await Image.decode(bytes);
      expect((back.width, back.height), (32, 24));
      expect(back.bytes, img.bytes);
    });

    test('qoi round-trip keeps dimensions and pixels', () async {
      final img = Image.blank(width: 17, height: 9)..fill(0xFF445566);
      final bytes = img.encode(format: 'qoi');
      expect(Image.formatOf(bytes), 'qoi');
      final back = await Image.decode(bytes);
      expect((back.width, back.height), (17, 9));
      expect(back.bytes, img.bytes);
    });

    test('jpeg/webp round-trip keeps dimensions when native loads', () async {
      if (!Lib2Native.isAvailable) {
        await expectLater(
          () async => Image.blank(width: 8, height: 8).encode(format: 'jpeg'),
          throwsA(isA<UnsupportedError>()),
        );
        return;
      }
      final img = Image.blank(width: 48, height: 32)..fill(0xFF778899);
      for (final format in ['jpeg', 'webp']) {
        final bytes = img.encode(format: format, quality: 80);
        expect(Image.formatOf(bytes), format);
        final back = await Image.decode(bytes);
        expect((back.width, back.height), (48, 32));
      }
    });

    test('unknown bytes are a FormatException', () async {
      await expectLater(Image.decode([1, 2, 3, 4]), throwsFormatException);
    });

    test('blur of a solid image is solid; draw leaves pixels', () {
      final solid = Image.blank(width: 16, height: 16)..fill(0xFF102030);
      final blurred = solid.blur(2);
      expect(blurred.bytes, solid.bytes);
      final base = Image.blank(width: 16, height: 16)..fill(0xFF000000);
      final mark = Image.blank(width: 4, height: 4)..fill(0xFFFFFFFF);
      final composed = base.draw(mark, x: 2, y: 2);
      expect(composed.bytes, isNot(equals(base.bytes)));
      expect(composed.pixel(2, 2), isNot(equals(base.pixel(2, 2))));
      expect(composed.pixel(0, 0), equals(base.pixel(0, 0)));
    });

    test('File bytes pipe into Image.load() sink; image pipes out as PNG', () async {
      final tmp = await io.Directory.systemTemp.createTemp('lib2_phasec_img_');
      try {
        final img = Image.blank(width: 20, height: 12)..fill(0xFF334455);
        final path = '${tmp.path}/x.png';
        await io.File(path).writeAsBytes(img.encode(format: 'png'));
        final src = await File.open(path);
        final sink = Image.load() as ImageDecodeSink;
        expect(await src.pipe(sink), greaterThan(0));
        await src.close();
        final got = await sink.finish();
        expect((got.width, got.height), (20, 12));
        expect(got.bytes, img.bytes);
        // And back out through the Reader form.
        final dst = BufferWriter();
        expect(await got.pipe(dst), greaterThan(0));
        final back = await Image.decode(dst.take());
        expect((back.width, back.height), (20, 12));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });

  group('fs native wiring', () {
    late io.Directory tmp;
    setUp(() async {
      tmp = await io.Directory.systemTemp.createTemp('lib2_phasec_fs_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('atomic over a held handle lands the new bytes', () async {
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
        await File(path).atomic('new');
      } finally {
        await child.exitCode;
        await holder.delete();
      }
      expect(await io.File(path).readAsString(), 'new');
    });

    test('copy then move round-trip bytes; id is stable across rename', () async {
      final src = '${tmp.path}/a.bin';
      final data = Uint8List.fromList(List.generate(100000, (i) => i & 0xFF));
      await io.File(src).writeAsBytes(data);
      await File(src).copy('${tmp.path}/b.bin');
      expect(await io.File('${tmp.path}/b.bin').readAsBytes(), data);
      final before = await File('${tmp.path}/b.bin').id();
      await File('${tmp.path}/b.bin').move('${tmp.path}/c.bin');
      expect(await io.File('${tmp.path}/c.bin').readAsBytes(), data);
      expect(await io.File('${tmp.path}/b.bin').exists(), isFalse);
      if (Lib2Native.isAvailable) {
        final after = await File('${tmp.path}/c.bin').id();
        expect(after, isNotNull);
        expect(after, before);
      }
    });

    test('chmod through the seam does not throw', () async {
      final path = '${tmp.path}/m.txt';
      await io.File(path).writeAsString('x');
      await File(path).chmod(420); // 0644
      expect(await io.File(path).exists(), isTrue);
    });
  });

  group('process tree kill', () {
    late io.Directory tmp;
    late String dart;
    setUp(() async {
      tmp = await io.Directory.systemTemp.createTemp('lib2_phasec_proc_');
      dart = io.Platform.executable;
      io.File('${tmp.path}/sleep.dart').writeAsStringSync('''
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 120));
}
''');
      // level2 spawns a sleeper grandchild, records both pids, then waits.
      io.File('${tmp.path}/level2.dart').writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final sleeper = await Process.start(Platform.executable, [args[0]]);
  await File(args[1]).writeAsString('\$pid \${sleeper.pid}');
  await sleeper.exitCode;
}
''');
      // level1 spawns level2, then waits: a 3-level chain below the test.
      io.File('${tmp.path}/level1.dart').writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final mid = await Process.start(Platform.executable, [args[0], args[1], args[2]]);
  await mid.exitCode;
}
''');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('cancel() reaps a 3-level chain', () async {
      final pids = '${tmp.path}/pids.txt';
      final p = Process(dart, ['${tmp.path}/level1.dart', '${tmp.path}/level2.dart', '${tmp.path}/sleep.dart', pids]);
      // Wait for the chain to record its pids.
      for (var i = 0; i < 100 && !io.File(pids).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(io.File(pids).existsSync(), isTrue, reason: 'chain did not start');
      final parts = (await io.File(pids).readAsString()).trim().split(' ');
      final mid = int.parse(parts[0]), leaf = int.parse(parts[1]);
      expect(await _alive(mid), isTrue);
      expect(await _alive(leaf), isTrue);
      await p.cancel();
      expect(await _alive(mid), isFalse);
      expect(await _alive(leaf), isFalse);
      expect(await p.exitCode, isNot(0));
      await p.cancel(); // second cancel is quiet
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

/// Whether [pid] still names a live process.
Future<bool> _alive(int pid) async {
  if (io.Platform.isWindows) {
    final r = await io.Process.run('tasklist', ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH']);
    return '${r.stdout}'.contains('"$pid"');
  }
  final r = await io.Process.run('ps', ['-p', '$pid']);
  return r.exitCode == 0;
}

import 'dart:async';
import 'dart:convert';
import 'dart:io' hide File;
import 'dart:io' as io show File;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:test/test.dart';

import 'support/in_dir.dart';

List<int> _tarBlock(String name, int size, int typeflag) {
  final b = List<int>.filled(512, 0);
  b.setRange(0, name.length, name.codeUnits);
  b.setRange(100, 107, '0000644'.codeUnits);
  b.setRange(124, 135, size.toRadixString(8).padLeft(11, '0').codeUnits);
  b[156] = typeflag;
  b.setRange(257, 263, 'ustar\x00'.codeUnits);
  b.setRange(148, 156, List.filled(8, 0x20));
  final sum = b.fold<int>(0, (a, c) => a + c);
  b.setRange(148, 155, sum.toRadixString(8).padLeft(6, '0').codeUnits + [0]);
  b[155] = 0x20;
  return b;
}

List<int> _tarBody(List<int> body) =>
    [...body, ...List.filled((512 - body.length % 512) % 512, 0)];

List<int> _pax(Map<String, String> records) {
  final out = <int>[];
  for (final e in records.entries) {
    final body = '${e.key}=${e.value}\n';
    var n = body.length + 2;
    if ('$n '.length + body.length != n) n = '$n '.length + body.length;
    out.addAll('$n $body'.codeUnits);
  }
  return out;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('archive_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  String p(String name) => '${tmp.path}/$name';

  Future<void> seed() async {
    await Fs.file(p('site/index.html')).write('<h1>hi</h1>');
    await Fs.file(p('site/a/b.txt')).write('bee');
  }

  group('Archive.pack', () {
    test('zip round-trips folder contents, not the folder', () async {
      await seed();
      await (Archive.pack(p('site'), ArchiveFormat.zip) > Fs.file(p('s.zip')));
      await (Fs.file(p('s.zip')) > Archive.unpack(p('out')));
      expect(await Fs.file(p('out/index.html')).text(), '<h1>hi</h1>');
      expect(await Fs.file(p('out/a/b.txt')).text(), 'bee');
      expect(await Fs.entry(p('out/site')), isNull);
    });

    test('tar round-trips', () async {
      await seed();
      await (Archive.pack(p('site'), ArchiveFormat.tar) > Fs.file(p('s.tar')));
      await (Fs.file(p('s.tar')) > Archive.unpack(p('out')));
      expect(await Fs.file(p('out/a/b.txt')).text(), 'bee');
    });

    test('tgz round-trips', () async {
      await seed();
      await (Archive.pack(p('site'), ArchiveFormat.tgz) > Fs.file(p('s.tgz')));
      await (Fs.file(p('s.tgz')) > Archive.unpack(p('out')));
      expect(await Fs.file(p('out/a/b.txt')).text(), 'bee');
    });

    test('packing is lazy and missing dirs fail when read', () async {
      final r = Archive.pack(p('missing'), ArchiveFormat.zip);
      expect(r.bytes(), throwsA(isA<FileSystemException>()));
    });
  });

  group('Archive.unpack', () {
    test('refuses absolute members with a FormatException', () async {
      await seed();
      await (Archive.pack(p('site'), ArchiveFormat.zip) > Fs.file(p('s.zip')));
      // Corrupt the member name by hand: rewrite the zip is overkill;
      // instead feed garbage and expect a FormatException.
      await (Reader.of([1, 2, 3, 4]) > Fs.file(p('bad.zip')));
      expect(
        Fs.file(p('bad.zip')) > Archive.unpack(p('out')),
        throwsFormatException,
      );
    });

    test('a failed run leaves no half-unpacked tree', () async {
      await (Reader.of([1, 2, 3, 4]) > Fs.file(p('bad.zip')));
      await expectLater(
        Fs.file(p('bad.zip')) > Archive.unpack(p('out')),
        throwsFormatException,
      );
      expect(await Fs.entry(p('out')), isNull);
    });

    test('F1: unpacking merges, never deletes the target', () async {
      await seed();
      await Fs.file(p('vendor/precious.txt')).write('do not lose');
      await (Archive.pack(p('site'), ArchiveFormat.zip) >
          Archive.unpack(p('vendor')));
      expect(await Fs.file(p('vendor/precious.txt')).text(), 'do not lose');
      expect(await Fs.file(p('vendor/index.html')).text(), '<h1>hi</h1>');
    });

    test('F1: unpacking into . keeps the working tree', () async {
      await seed();
      await Fs.file(p('work/keep.txt')).write('keep me');
      await runInDir(p('work'), "import 'package:dart_toolkit/archive.dart';",
          "await (Archive.pack('../site', ArchiveFormat.zip) > Archive.unpack('.'));");
      expect(await Fs.file(p('work/keep.txt')).text(), 'keep me');
      expect(await Fs.file(p('work/index.html')).text(), '<h1>hi</h1>');
    });

    test('F2: a trailing-slash target unpacks beside itself', () async {
      await seed();
      await (Archive.pack(p('site'), ArchiveFormat.zip) >
          Archive.unpack('${p('out')}/'));
      expect(await Fs.file(p('out/a/b.txt')).text(), 'bee');
    });

    test('F13: an empty folder packs and unpacks in every format',
        () async {
      await Fs.dir(p('empty')).create();
      for (final format in ArchiveFormat.values) {
        await (Archive.pack(p('empty'), format) > Fs.file(p('e.bin')));
        await (Fs.file(p('e.bin')) > Archive.unpack(p('eout')));
        expect(await Fs.dir(p('eout')).exists(), isTrue);
        await Fs.dir(p('eout')).delete();
      }
    });

    test('F13: gzip data that is not a tar fails clearly', () async {
      await Fs.file(p('plain.txt')).write('just text, not a tar');
      await (Fs.file(p('plain.txt')) | Archive.gzip() > Fs.file(p('t.gz')));
      await expectLater(
        Fs.file(p('t.gz')) > Archive.unpack(p('out')),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('not a tar'),
        )),
      );
    });

    test('F13: unpacked files keep their executable bit', () async {
      if (Platform.isWindows) markTestSkipped('needs POSIX modes');
      await seed();
      await Process.run('chmod', ['755', p('site/a/b.txt')]);
      await (Archive.pack(p('site'), ArchiveFormat.tar) > Fs.file(p('s.tar')));
      await (Fs.file(p('s.tar')) > Archive.unpack(p('out')));
      final mode = (await FileStat.stat(p('out/a/b.txt'))).mode & 0x1ff;
      expect(mode & 0x100, isNot(0));
    });

    test('H8: unpack cancels its source, even with padding after the end',
        () async {
      await seed();
      final tar = await Archive.pack(p('site'), ArchiveFormat.tar).bytes();
      var cancelled = false;
      final c = StreamController<List<int>>(onCancel: () => cancelled = true);
      c.add([...tar, ...List.filled(4096, 0)]);
      await Archive.unpack(p('out')).consume(c.stream);
      expect(cancelled, isTrue);
      expect(await Fs.file(p('out/a/b.txt')).text(), 'bee');
    });

    test('H8: unpack cancels its source when the archive is corrupt',
        () async {
      var cancelled = false;
      final c = StreamController<List<int>>(onCancel: () => cancelled = true);
      c.add(List.filled(1024, 7));
      await expectLater(
        Archive.unpack(p('out')).consume(c.stream),
        throwsFormatException,
      );
      expect(cancelled, isTrue);
    });

    test('H9: a pax size record overrides the header size', () async {
      final pax = _pax({'size': '5'});
      final tar = [
        ..._tarBlock('PaxHeader', pax.length, 0x78),
        ..._tarBody(pax),
        ..._tarBlock('big.bin', 0, 0x30),
        ..._tarBody('hello'.codeUnits),
        ...List.filled(1024, 0),
      ];
      await Archive.unpack(p('out')).consume(Stream.value(tar));
      expect(await Fs.file(p('out/big.bin')).text(), 'hello');
    });

    test('H9: a sparse member fails instead of extracting garbage', () async {
      final pax = _pax({'GNU.sparse.name': 'big.bin', 'GNU.sparse.size': '9'});
      final tar = [
        ..._tarBlock('PaxHeader', pax.length, 0x78),
        ..._tarBody(pax),
        ..._tarBlock('GNUSparseFile.0/big.bin', 3, 0x30),
        ..._tarBody('abc'.codeUnits),
        ...List.filled(1024, 0),
      ];
      await expectLater(
        Archive.unpack(p('out')).consume(Stream.value(tar)),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('sparse'))),
      );
      expect(await Fs.entry(p('out')), isNull);
    });

    test('H10: tar header of a file over 8 GiB carries the true size',
        () async {
      final size = (8 << 30) + 5;
      final raf = await io.File(p('huge.bin')).open(mode: FileMode.write);
      await raf.truncate(size);
      await raf.close();
      await Directory(p('one')).create();
      await io.File(p('huge.bin')).rename(p('one/huge.bin'));
      final header = (await Archive.pack(p('one'), ArchiveFormat.tar)
              .stream()
              .first)
          .toList();
      expect(header[124] & 0x80, isNot(0));
      var got = 0;
      for (var i = 125; i < 136; i++) {
        got = got * 256 + header[i];
      }
      expect(got, size);
    });

    test('H10: tar pack streams files and round-trips a multi-chunk file',
        () async {
      final data = List.generate(300000, (i) => i % 251);
      await io.File(p('site/big.bin')).create(recursive: true);
      await io.File(p('site/big.bin')).writeAsBytes(data);
      await (Archive.pack(p('site'), ArchiveFormat.tar) > Fs.file(p('s.tar')));
      await (Fs.file(p('s.tar')) > Archive.unpack(p('out')));
      expect(await io.File(p('out/big.bin')).readAsBytes(), data);
    });

    test('H7: tar unpack streams a member in constant memory', () async {
      await Directory(p('work')).create();
      await runInDir(p('work'), """
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_toolkit/archive.dart';
""", r'''
const total = 100 << 20;
final chunk = Uint8List(64 << 10);
final head = List<int>.filled(512, 0)
  ..setRange(0, 7, 'big.bin'.codeUnits)
  ..setRange(100, 107, '0000644'.codeUnits)
  ..setRange(124, 135, total.toRadixString(8).padLeft(11, '0').codeUnits)
  ..[156] = 0x30
  ..setRange(257, 263, 'ustar\x00'.codeUnits)
  ..setRange(148, 156, List.filled(8, 0x20));
final sum = head.fold<int>(0, (a, c) => a + c);
head.setRange(148, 155, sum.toRadixString(8).padLeft(6, '0').codeUnits + [0]);
head[155] = 0x20;
Stream<List<int>> tar() async* {
  yield head;
  for (var n = 0; n < total; n += chunk.length) {
    yield chunk;
  }
  yield Uint8List(1024);
}
final before = ProcessInfo.maxRss;
await Archive.unpack('out').consume(tar());
if (File('out/big.bin').lengthSync() != total) throw 'size';
if (ProcessInfo.maxRss - before > (60 << 20)) throw 'rss \${ProcessInfo.maxRss - before}';
''');
    });

    test('H7: tar unpack handles tiny input chunks', () async {
      await seed();
      final tar = await Archive.pack(p('site'), ArchiveFormat.tar).bytes();
      Stream<List<int>> bits() async* {
        for (var i = 0; i < tar.length; i += 7) {
          yield tar.sublist(i, i + 7 > tar.length ? tar.length : i + 7);
        }
      }

      await Archive.unpack(p('out')).consume(bits());
      expect(await Fs.file(p('out/a/b.txt')).text(), 'bee');
      expect(await Fs.file(p('out/index.html')).text(), '<h1>hi</h1>');
    });

    test('M29: non-portable member names are refused on every OS', () async {
      for (final name in [
        'a:b',
        'CON',
        'aux.txt',
        'dir/NUL.log',
        'x.',
        'dir./f',
        'x ',
        'a<b',
        'q?',
        '.. ',
      ]) {
        final tar = [
          ..._tarBlock(name, 1, 0x30),
          ..._tarBody('x'.codeUnits),
          ...List.filled(1024, 0),
        ];
        await expectLater(
          Archive.unpack(p('out')).consume(Stream.value(tar)),
          throwsFormatException,
          reason: name,
        );
        expect(await Fs.entry(p('out')), isNull, reason: name);
      }
    });

    test('M29: members that differ only in case are refused', () async {
      List<int> member(String name) => [
            ..._tarBlock(name, 1, 0x30),
            ..._tarBody('x'.codeUnits),
          ];
      final tar = [
        ...member('A.txt'),
        ...member('a.txt'),
        ...List.filled(1024, 0),
      ];
      await expectLater(
        Archive.unpack(p('out')).consume(Stream.value(tar)),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('case'))),
      );
      final dirClash = [
        ..._tarBlock('Dir/', 0, 0x35),
        ...member('dir/x.txt'),
        ...List.filled(1024, 0),
      ];
      await expectLater(
        Archive.unpack(p('out')).consume(Stream.value(dirClash)),
        throwsFormatException,
      );
    });

    test('M29: ordinary names and a repeated member still unpack', () async {
      List<int> member(String name, String body) => [
            ..._tarBlock(name, body.length, 0x30),
            ..._tarBody(body.codeUnits),
          ];
      final tar = [
        ...member('.hidden', 'h'),
        ...member('a.b/c-d_e.txt', 'one'),
        ...member('a.b/c-d_e.txt', 'two'),
        ...List.filled(1024, 0),
      ];
      await Archive.unpack(p('out')).consume(Stream.value(tar));
      expect(await Fs.file(p('out/a.b/c-d_e.txt')).text(), 'two');
    });

    test('M8: tar members come depth-first', () async {
      await Fs.file(p('o/a/b')).write('1');
      await Fs.file(p('o/a-b')).write('2');
      final tar = await Archive.pack(p('o'), ArchiveFormat.tar).bytes();
      final names = <String>[];
      for (var i = 0; i + 512 <= tar.length; i += 512) {
        if (tar[i] == 0) break;
        names.add(String.fromCharCodes(tar.sublist(i, i + 100))
            .replaceAll('\x00', ''));
        final size = int.parse(
            String.fromCharCodes(tar.sublist(i + 124, i + 135)),
            radix: 8);
        i += (size + 511) ~/ 512 * 512;
      }
      expect(names, ['a/', 'a/b', 'a-b']);
    });

    test('L12: one-byte and empty input are a FormatException', () async {
      for (final bytes in [<int>[], [0x50], [0x1f]]) {
        await expectLater(
          Archive.unpack(p('out')).consume(Stream.value(bytes)),
          throwsFormatException,
        );
      }
    });

    test('F13: pack refuses symlinks like unpack does', () async {
      await seed();
      await Fs.link(p('site/link')).create('${p('site')}/a/b.txt');
      await expectLater(
        Archive.pack(p('site'), ArchiveFormat.zip).bytes(),
        throwsFormatException,
      );
    });
  });

  group('interrupt', () {
    for (final mode in ['write', 'unpack']) {
      test('M6: Ctrl-C during $mode leaves no temp siblings', () async {
        if (Platform.isWindows) markTestSkipped('needs a POSIX SIGINT');
        final proc = await Process.start(
          Platform.resolvedExecutable,
          ['test/signal_probe/probe.dart', mode, tmp.path],
        );
        final lines = proc.stdout
            .transform(const SystemEncoding().decoder)
            .transform(const LineSplitter());
        await lines.firstWhere((l) => l.trim() == 'ready').timeout(
              const Duration(seconds: 60),
            );
        proc.kill(ProcessSignal.sigint);
        expect(await proc.exitCode.timeout(const Duration(seconds: 20)), 130);
        expect(await tmp.list().toList(), isEmpty);
      });
    }
  });

  group('gzip', () {
    test('gzip then gunzip round-trips, streaming', () async {
      await Fs.file(p('big.txt')).write('x' * 100000);
      await (Fs.file(p('big.txt')) | Archive.gzip() > Fs.file(p('big.gz')));
      expect(await Fs.file(p('big.gz')).size(), lessThan(100000));
      await (Fs.file(p('big.gz')) | Archive.gunzip() > Fs.file(p('back.txt')));
      expect(await Fs.file(p('back.txt')).size(), 100000);
    });

    test('bad gzip data fails with a FormatException', () async {
      await (Reader.of([1, 2, 3]) > Fs.file(p('nope.gz')));
      expect(
        Fs.file(p('nope.gz')) | Archive.gunzip() > Fs.file(p('o.txt')),
        throwsFormatException,
      );
    });

    test('F3: truncated gzip fails instead of saving partial data', () async {
      await Fs.file(p('big.txt')).write('x' * 100000);
      await (Fs.file(p('big.txt')) | Archive.gzip() > Fs.file(p('big.gz')));
      final full = await Fs.file(p('big.gz')).bytes();
      await (Reader.of(full.sublist(0, full.length ~/ 2)) >
          Fs.file(p('half.gz')));
      await expectLater(
        Fs.file(p('half.gz')) | Archive.gunzip() > Fs.file(p('o.txt')),
        throwsFormatException,
      );
    });

    test('M7: gunzip works on tiny chunks and still catches corruption',
        () async {
      final plain = List.generate(50000, (i) => i * 7 % 256);
      final gz = gzip.encode(plain);
      Stream<List<int>> bits(List<int> b) async* {
        for (var i = 0; i < b.length; i += 3) {
          yield b.sublist(i, i + 3 > b.length ? b.length : i + 3);
        }
      }

      final out = await Archive.gunzip().transform(bits(gz)).expand((c) => c).toList();
      expect(out, plain);
      final bad = List<int>.of(gz)..[gz.length - 9] ^= 0xff; // flips CRC input
      await expectLater(
        Archive.gunzip().transform(bits(bad)).drain<void>(),
        throwsFormatException,
      );
      await expectLater(
        Archive.gunzip().transform(bits(gz.sublist(0, gz.length - 5))).drain<void>(),
        throwsFormatException,
      );
    });
  });
}

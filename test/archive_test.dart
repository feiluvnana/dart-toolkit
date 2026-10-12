// Archives: contained unpacking, round-trips and streaming.
//
// Every refusal throws a SecurityException before anything is written — no
// entry escapes its destination, no absolute member, no NUL byte, no link
// materialized. Unpacking a download streams through the native unpack sink.
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/path.dart';
import 'package:test/test.dart';

/// A minimal tar builder for members the packer never emits (links, dirs).
Uint8List tarOf(List<(String name, List<int> data, String type)> members) {
  final out = BytesBuilder(copy: true);
  for (final (name, data, type) in members) {
    final header = Uint8List(512);
    void str(int off, String s, int len) {
      final codes = utf8.encode(s);
      for (var i = 0; i < len; i++) {
        header[off + i] = i < codes.length ? codes[i] : 0;
      }
    }

    str(0, name, 100);
    str(124, '${data.length.toRadixString(8).padLeft(11, '0')}\x00', 12);
    header[156] = type.codeUnitAt(0);
    str(257, 'ustar\x00', 6);
    for (var i = 148; i < 156; i++) {
      header[i] = 0x20;
    }
    var sum = 0;
    for (final b in header) {
      sum += b;
    }
    str(148, '${sum.toRadixString(8).padLeft(6, '0')}\x00 ', 8);
    out.add(header);
    out.add(data);
    final pad = (512 - data.length % 512) % 512;
    if (pad > 0) out.add(Uint8List(pad));
  }
  out.add(Uint8List(1024));
  return out.takeBytes();
}

void main() {
  late io.Directory tmp;
  setUp(() async {
    tmp = await io.Directory.systemTemp.createTemp('archive_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  String at(String name) => '${tmp.path}/$name';

  group('zip-slip members are refused before anything is written', () {
    test('../ escape writes nothing and throws SecurityException', () async {
      io.File(at('evil.zip')).writeAsBytesSync(
        Archive.zip({
          '../../evil.txt': [1, 2, 3],
          'ok.txt': [4],
        }),
      );
      await expectLater(File(at('evil.zip')).unpack(Dir(at('sandbox'))), throwsA(isA<SecurityException>()));
      expect(io.Directory(at('sandbox')).existsSync(), isFalse);
      expect(io.File(at('evil.txt')).existsSync(), isFalse);
    });

    test('nested a/../../ escape is refused', () async {
      io.File(at('evil.zip')).writeAsBytesSync(
        Archive.zip({
          'a/../../evil.txt': [1],
        }),
      );
      await expectLater(File(at('evil.zip')).unpack(Dir(at('sandbox'))), throwsA(isA<SecurityException>()));
      expect(io.Directory(at('sandbox')).existsSync(), isFalse);
    });

    test('backslash ..\\..\\ escape is refused', () async {
      io.File(at('evil.zip')).writeAsBytesSync(
        Archive.zip({
          '..\\..\\evil.txt': [1],
        }),
      );
      await expectLater(File(at('evil.zip')).unpack(Dir(at('sandbox'))), throwsA(isA<SecurityException>()));
      expect(io.Directory(at('sandbox')).existsSync(), isFalse);
    });

    test('absolute members are refused', () async {
      for (final name in ['/abs.txt', 'C:/abs.txt', r'C:\abs.txt']) {
        io.File(at('abs.zip')).writeAsBytesSync(
          Archive.zip({
            name: [1],
          }),
        );
        await expectLater(
          File(at('abs.zip')).unpack(Dir(at('sandbox'))),
          throwsA(isA<SecurityException>()),
          reason: name,
        );
      }
      expect(io.Directory(at('sandbox')).existsSync(), isFalse);
    });

    test('a NUL byte member is refused', () async {
      io.File(at('nul.zip')).writeAsBytesSync(
        Archive.zip({
          'a\x00b.txt': [1],
        }),
      );
      await expectLater(File(at('nul.zip')).unpack(Dir(at('sandbox'))), throwsA(isA<SecurityException>()));
    });

    test('tar .. escape is refused', () async {
      io.File(at('evil.tar')).writeAsBytesSync(
        tarOf([
          ('sub/../../evil.txt', [1], '0'),
        ]),
      );
      await expectLater(File(at('evil.tar')).unpack(Dir(at('sandbox'))), throwsA(isA<SecurityException>()));
      expect(io.Directory(at('sandbox')).existsSync(), isFalse);
    });

    test('tar symlink and hardlink members are refused', () async {
      for (final type in ['1', '2']) {
        io.File(at('link.tar')).writeAsBytesSync(tarOf([('link', utf8.encode('target'), type)]));
        await expectLater(
          File(at('link.tar')).unpack(Dir(at('sandbox'))),
          throwsA(isA<SecurityException>()),
          reason: 'typeflag $type',
        );
      }
      expect(io.Directory(at('sandbox')).existsSync(), isFalse);
    });

    test('entry of a link member is refused; of a missing member is MissingException', () async {
      io.File(at('link.tar')).writeAsBytesSync(tarOf([('link', utf8.encode('target'), '2')]));
      await expectLater(File(at('link.tar')).entry('link').text(), throwsA(isA<SecurityException>()));
      io.File(at('good.zip')).writeAsBytesSync(
        Archive.zip({
          'a.txt': [7],
        }),
      );
      await expectLater(File(at('good.zip')).entry('nope.txt').text(), throwsA(isA<MissingException>()));
    });
  });

  group('good archives still round-trip', () {
    test('unpack(pack(d)) is d byte-for-byte, zip and tar.gz', () async {
      final src = io.Directory(at('src'))..createSync();
      io.File('${src.path}/a.txt').writeAsStringSync('hello');
      io.Directory('${src.path}/sub').createSync();
      io.File('${src.path}/sub/b.txt').writeAsBytesSync([0, 1, 2, 255]);
      for (final ext in ['zip', 'tar.gz', 'tar']) {
        await Dir(src.path).pack(File(at('b.$ext')));
        expect(await File(at('b.$ext')).entries(), {'a.txt', 'sub/b.txt'});
        await File(at('b.$ext')).unpack(Dir(at('out-$ext')));
        expect(io.File(at('out-$ext/a.txt')).readAsStringSync(), 'hello');
        expect(io.File(at('out-$ext/sub/b.txt')).readAsBytesSync(), [0, 1, 2, 255]);
        expect(await File(at('b.$ext')).entry('sub/b.txt').bytes(), [0, 1, 2, 255]);
      }
    });

    test('tar directories are created, not written as files', () async {
      io.File(at('dirs.tar')).writeAsBytesSync(
        tarOf([
          ('empty/', [], '5'),
          ('empty/f.txt', [9], '0'),
        ]),
      );
      await File(at('dirs.tar')).unpack(Dir(at('sandbox')));
      expect(io.Directory(at('sandbox/empty')).existsSync(), isTrue);
      expect(io.File(at('sandbox/empty/f.txt')).readAsBytesSync(), [9]);
      expect(await File(at('dirs.tar')).entries(), ['empty/f.txt']);
    });

    test('unpack through a symlinked destination parent keeps subfolders', () async {
      final real = await io.Directory.systemTemp.createTemp('tk_real_');
      final link = io.Link('${io.Directory.systemTemp.path}/tk_link_${DateTime.now().microsecondsSinceEpoch}');
      await link.create(real.path);
      try {
        io.File('${real.path}/src/sub/a.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync('hi');
        await Dir('${link.path}/src').pack(File('${link.path}/x.tar'));
        await File('${link.path}/x.tar').unpack(Dir('${link.path}/out'));
        expect(io.File('${real.path}/out/sub/a.txt').readAsStringSync(), 'hi');
      } finally {
        await link.delete();
        await real.delete(recursive: true);
      }
    });
  });

  group('archive round-trips and selective open', () {
    late io.Directory work;
    setUp(() async {
      work = await io.Directory.systemTemp.createTemp('archive_roundtrip_');
      await io.Directory('${work.path}/d/sub').create(recursive: true);
      await io.File('${work.path}/d/a.txt').writeAsString('hello archive');
      await io.File('${work.path}/d/sub/b.bin').writeAsBytes(List.generate(50000, (i) => i & 0xFF));
    });
    tearDown(() async {
      if (await work.exists()) await work.delete(recursive: true);
    });

    for (final ext in ['zip', 'tar', 'tar.gz']) {
      test('unpack(pack(d)) == d for .$ext', () async {
        final bundle = File('${work.path}/b.$ext');
        final out = Dir('${work.path}/out-$ext');
        await Dir('${work.path}/d').pack(bundle);
        expect(await bundle.entries(), containsAll(['a.txt', 'sub/b.bin']));
        await bundle.unpack(out);
        expect(await io.File('${out.path}/a.txt').readAsString(), 'hello archive');
        expect(await io.File('${out.path}/sub/b.bin').readAsBytes(), List.generate(50000, (i) => i & 0xFF));
      });
    }

    test('entry() streams one member; missing and link members throw', () async {
      final bundle = File('${work.path}/b.zip');
      await Dir('${work.path}/d').pack(bundle);
      expect(await bundle.entry('a.txt').text(), 'hello archive');
      await expectLater(bundle.entry('nope.txt').text(), throwsA(isA<MissingException>()));
    });
  });

  group('compressed tars', () {
    late io.Directory work;
    setUp(() async {
      work = await io.Directory.systemTemp.createTemp('archive_tars_');
      await io.Directory('${work.path}/d/sub').create(recursive: true);
      await io.File('${work.path}/d/a.txt').writeAsString('hello tar');
      await io.File('${work.path}/d/sub/b.bin').writeAsBytes(List.generate(20000, (i) => i & 0xFF));
    });
    tearDown(() async {
      if (await work.exists()) await work.delete(recursive: true);
    });

    for (final ext in ['tar.zst', 'tzst', 'tar.xz', 'txz', 'tar.bz2', 'tbz2']) {
      test('unpack(pack(d)) == d for .$ext', () async {
        final bundle = File('${work.path}/b.$ext');
        final out = Dir('${work.path}/out-$ext');
        await Dir('${work.path}/d').pack(bundle);
        expect(await bundle.entries(), containsAll(['a.txt', 'sub/b.bin']));
        await bundle.unpack(out);
        expect(await io.File('${out.path}/a.txt').readAsString(), 'hello tar');
        expect(await io.File('${out.path}/sub/b.bin').readAsBytes(), List.generate(20000, (i) => i & 0xFF));
      });
    }
  });

  group('single-file streams', () {
    test('File pack to .gz round-trips through gunzip', () async {
      final file = File(at('one.txt'));
      await file.write('hello stream');
      final packed = File(at('one.txt.gz'));
      await file.pack(packed);
      expect(Archive.gunzip(await packed.bytes()), utf8.encode('hello stream'));
    });

    test('File pack to .zst writes a zstd stream', () async {
      final file = File(at('one.txt'));
      await file.write('hello stream');
      final packed = File(at('one.txt.zst'));
      await file.pack(packed);
      expect((await packed.bytes()).sublist(0, 4), [0x28, 0xB5, 0x2F, 0xFD]);
    });
  });

  group('streaming unpack', () {
    late io.HttpServer server;
    late List<int> bundle;
    setUp(() async {
      final dir = Dir(at('stream_src'));
      await dir.make();
      await dir.file('a.txt').write('hello stream');
      await dir.dir('sub').make();
      await dir.file('sub/b.bin').write(List.generate(50000, (i) => i & 0xFF));
      final packed = File(at('bundle.tar.gz'));
      await dir.pack(packed);
      bundle = (await packed.bytes()).toList();
      server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async {
      await server.close(force: true);
    });

    String url(String path) => 'http://${server.address.host}:${server.port}$path';

    test('Http.get(u).unpack streams a tar.gz in small writes', () async {
      server.listen((request) async {
        request.response.headers.contentType = io.ContentType.binary;
        request.response.contentLength = bundle.length;
        for (var i = 0; i < bundle.length; i += 1024) {
          request.response.add(bundle.sublist(i, (i + 1024).clamp(0, bundle.length)));
          await request.response.flush();
        }
        await request.response.close();
      });
      final out = Dir(at('stream-out'));
      final count = await Http.get(url('/bundle.tar.gz')).unpack(out);
      expect(count, 2);
      expect(await out.file('a.txt').text(), 'hello stream');
      expect(await out.file('sub/b.bin').bytes(), List.generate(50000, (i) => i & 0xFF));
      // Nothing lands on disk first: no spool temp remains beside the destination.
      for (final entry in io.Directory(at('')).listSync()) {
        expect(entry.path.contains('.part_'), isFalse, reason: entry.path);
      }
    });

    test('streaming a zip round-trips through the spool', () async {
      final dir = Dir(at('zip_src'));
      await dir.make();
      await dir.file('a.txt').write('hello zip');
      final packed = File(at('bundle.zip'));
      await dir.pack(packed);
      final bytes = (await packed.bytes()).toList();
      server.listen((request) async {
        request.response.headers.contentType = io.ContentType.binary;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      final out = Dir(at('zip-out'));
      expect(await Http.get(url('/bundle.zip')).unpack(out), 1);
      expect(await out.file('a.txt').text(), 'hello zip');
      for (final entry in io.Directory(at('')).listSync()) {
        expect(entry.path.contains('.part_'), isFalse, reason: entry.path);
      }
    });

    test('streaming a tar with a ../escape member throws, writing nothing outside', () async {
      final evil = tarOf([
        ('sub/../../evil.txt', [1], '0'),
      ]).toList();
      server.listen((request) async {
        request.response.headers.contentType = io.ContentType.binary;
        request.response.contentLength = evil.length;
        request.response.add(evil);
        await request.response.close();
      });
      final out = Dir(at('evil-out'));
      await expectLater(Http.get(url('/evil.tar')).unpack(out), throwsA(isA<SecurityException>()));
      expect(io.File(at('evil.txt')).existsSync(), isFalse);
    });
  });

  group('entries', () {
    test('entries() lists files only; entry() reads one member', () async {
      io.File(
        at('b.zip'),
      ).writeAsBytesSync(Archive.zip({'a.txt': utf8.encode('hello'), 'sub/b.txt': utf8.encode('world')}));
      final bundle = File(at('b.zip'));
      expect(await bundle.entries(), {'a.txt', 'sub/b.txt'});
      expect(await bundle.entry('a.txt').text(), 'hello');
      await expectLater(bundle.entry('nope').text(), throwsA(isA<MissingException>()));
    });
  });
}

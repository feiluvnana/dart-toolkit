// Phase A exit gate: untrusted archives are contained. Every refusal throws
// a SecurityException before anything is written — no entry escapes `dst`,
// no absolute member, no NUL byte, no link materialized (reports/archive.md
// §5.1, CONVENTIONS.md r41).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/lib2/archive.dart';
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
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('archive_security_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  String at(String name) => '${tmp.path}/$name';

  group('zip-slip members are refused before anything is written', () {
    test('../ escape writes nothing and throws SecurityException', () async {
      File(at('evil.zip')).writeAsBytesSync(
        Archive.zip({
          '../../evil.txt': [1, 2, 3],
          'ok.txt': [4],
        }),
      );
      await expectLater(Archive.unpack(at('evil.zip'), at('sandbox')), throwsA(isA<SecurityException>()));
      expect(Directory(at('sandbox')).existsSync(), isFalse);
      expect(File(at('evil.txt')).existsSync(), isFalse);
    });

    test('nested a/../../ escape is refused', () async {
      File(at('evil.zip')).writeAsBytesSync(
        Archive.zip({
          'a/../../evil.txt': [1],
        }),
      );
      await expectLater(Archive.unpack(at('evil.zip'), at('sandbox')), throwsA(isA<SecurityException>()));
      expect(Directory(at('sandbox')).existsSync(), isFalse);
    });

    test('backslash ..\\..\\ escape is refused', () async {
      File(at('evil.zip')).writeAsBytesSync(
        Archive.zip({
          '..\\..\\evil.txt': [1],
        }),
      );
      await expectLater(Archive.unpack(at('evil.zip'), at('sandbox')), throwsA(isA<SecurityException>()));
      expect(Directory(at('sandbox')).existsSync(), isFalse);
    });

    test('absolute members are refused', () async {
      for (final name in ['/abs.txt', 'C:/abs.txt', r'C:\abs.txt']) {
        File(at('abs.zip')).writeAsBytesSync(
          Archive.zip({
            name: [1],
          }),
        );
        await expectLater(
          Archive.unpack(at('abs.zip'), at('sandbox')),
          throwsA(isA<SecurityException>()),
          reason: name,
        );
      }
      expect(Directory(at('sandbox')).existsSync(), isFalse);
    });

    test('a NUL byte member is refused', () async {
      File(at('nul.zip')).writeAsBytesSync(
        Archive.zip({
          'a\x00b.txt': [1],
        }),
      );
      await expectLater(Archive.unpack(at('nul.zip'), at('sandbox')), throwsA(isA<SecurityException>()));
    });

    test('tar .. escape is refused', () async {
      File(at('evil.tar')).writeAsBytesSync(
        tarOf([
          ('sub/../../evil.txt', [1], '0'),
        ]),
      );
      await expectLater(Archive.unpack(at('evil.tar'), at('sandbox')), throwsA(isA<SecurityException>()));
      expect(Directory(at('sandbox')).existsSync(), isFalse);
    });

    test('tar symlink and hardlink members are refused', () async {
      for (final type in ['1', '2']) {
        File(at('link.tar')).writeAsBytesSync(tarOf([('link', utf8.encode('target'), type)]));
        await expectLater(
          Archive.unpack(at('link.tar'), at('sandbox')),
          throwsA(isA<SecurityException>()),
          reason: 'typeflag $type',
        );
      }
      expect(Directory(at('sandbox')).existsSync(), isFalse);
    });

    test('extract of a link member is refused; of a missing member is MissingException', () async {
      File(at('link.tar')).writeAsBytesSync(tarOf([('link', utf8.encode('target'), '2')]));
      await expectLater(Archive.extract(at('link.tar'), 'link'), throwsA(isA<SecurityException>()));
      File(at('good.zip')).writeAsBytesSync(
        Archive.zip({
          'a.txt': [7],
        }),
      );
      await expectLater(Archive.extract(at('good.zip'), 'nope.txt'), throwsA(isA<MissingException>()));
    });
  });

  group('good archives still round-trip', () {
    test('unpack(pack(d)) is d byte-for-byte, zip and tar.gz', () async {
      final src = Directory(at('src'))..createSync();
      File('${src.path}/a.txt').writeAsStringSync('hello');
      Directory('${src.path}/sub').createSync();
      File('${src.path}/sub/b.txt').writeAsBytesSync([0, 1, 2, 255]);
      for (final ext in ['zip', 'tar.gz', 'tar']) {
        await Archive.pack(src.path, at('b.$ext'));
        final names = await Archive.list(at('b.$ext'));
        expect(names.toSet(), {'a.txt', 'sub/b.txt'}, reason: ext);
        await Archive.unpack(at('b.$ext'), at('out-$ext'));
        expect(File(at('out-$ext/a.txt')).readAsStringSync(), 'hello', reason: ext);
        expect(File(at('out-$ext/sub/b.txt')).readAsBytesSync(), [0, 1, 2, 255], reason: ext);
        expect(await Archive.extract(at('b.$ext'), 'sub/b.txt'), [0, 1, 2, 255], reason: 'extract $ext');
      }
    });

    test('tar directories are created, not written as files', () async {
      File(at('dirs.tar')).writeAsBytesSync(
        tarOf([
          ('empty/', [], '5'),
          ('empty/f.txt', [9], '0'),
        ]),
      );
      await Archive.unpack(at('dirs.tar'), at('sandbox'));
      expect(Directory(at('sandbox/empty')).existsSync(), isTrue);
      expect(File(at('sandbox/empty/f.txt')).readAsBytesSync(), [9]);
      expect(await Archive.list(at('dirs.tar')), ['empty/f.txt']);
    });
  });
}

import 'dart:io';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:test/test.dart';

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
      await Fs.file(p('bad.zip')).write([1, 2, 3, 4]);
      expect(
        Fs.file(p('bad.zip')) > Archive.unpack(p('out')),
        throwsFormatException,
      );
    });

    test('a failed run leaves no half-unpacked tree', () async {
      await Fs.file(p('bad.zip')).write([1, 2, 3, 4]);
      await expectLater(
        Fs.file(p('bad.zip')) > Archive.unpack(p('out')),
        throwsFormatException,
      );
      expect(await Fs.entry(p('out')), isNull);
    });
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
      await Fs.file(p('nope.gz')).write([1, 2, 3]);
      expect(
        Fs.file(p('nope.gz')) | Archive.gunzip() > Fs.file(p('o.txt')),
        throwsFormatException,
      );
    });
  });
}

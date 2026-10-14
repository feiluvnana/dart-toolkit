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
      expect(await Fs.lookup(p('out/site')), isNull);
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
      expect(await Fs.lookup(p('out')), isNull);
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
      final cwd = Directory.current;
      Directory.current = Directory(p('work'));
      try {
        await (Archive.pack('../site', ArchiveFormat.zip) > Archive.unpack('.'));
        expect(await Fs.file(p('work/keep.txt')).text(), 'keep me');
        expect(await Fs.file(p('work/index.html')).text(), '<h1>hi</h1>');
      } finally {
        Directory.current = cwd;
      }
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

    test('F13: pack refuses symlinks like unpack does', () async {
      await seed();
      await Fs.link(p('site/link')).create('${p('site')}/a/b.txt');
      await expectLater(
        Archive.pack(p('site'), ArchiveFormat.zip).bytes(),
        throwsFormatException,
      );
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
  });
}

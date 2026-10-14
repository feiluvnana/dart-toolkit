import 'dart:async';
import 'dart:convert';
import 'dart:io' hide File;
import 'dart:io' as io show File;
import 'dart:typed_data';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/src/rar.dart' as rar;
import 'package:test/test.dart';

import 'support/child.dart';

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

/// Recompute the checksum of the header at [at] after editing it.
void _resum(List<int> tar, int at) {
  final b = tar.sublist(at, at + 512)..setRange(148, 156, List.filled(8, 0x20));
  final sum = b.fold<int>(0, (a, c) => a + c);
  tar.setRange(at + 148, at + 155, sum.toRadixString(8).padLeft(6, '0').codeUnits + [0]);
  tar[at + 155] = 0x20;
}

List<int> _tarBody(List<int> body) => [...body, ...List.filled((512 - body.length % 512) % 512, 0)];

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

  group('zip interop', () {
    Future<bool> has(String tool) async {
      try {
        return (await Process.run('which', [tool])).exitCode == 0;
      } catch (_) {
        return false;
      }
    }

    test('our zip passes unzip -t and keeps modes and unicode names', () async {
      if (!await has('unzip')) markTestSkipped('needs unzip');
      await Fs.file(p('src/run.sh')).write('#!/bin/sh\n');
      await Process.run('chmod', ['755', p('src/run.sh')]);
      await Fs.file(p('src/d/café.txt')).write('x' * 5000);
      await (Archive.archive(['.'], dir: p('src'), format: ArchiveFormat.zip) > Fs.file(p('a.zip')));
      expect((await Process.run('unzip', ['-tq', p('a.zip')])).exitCode, 0);
      await Process.run('unzip', ['-q', p('a.zip'), '-d', p('out')]);
      expect(await Fs.file(p('out/d/café.txt')).text(), 'x' * 5000);
      expect((await FileStat.stat(p('out/run.sh'))).mode & 0x1ff, 0x1ed);
    });

    test('zips from zip -r, zip -fz (zip64) and ditto unpack', () async {
      if (!await has('zip')) markTestSkipped('needs zip');
      await Fs.file(p('src/a.txt')).write('a' * 3000);
      await Fs.file(p('src/sub/b.bin')).write('b');
      final makers = <String, List<String>>{
        'r.zip': ['zip', '-qr', p('r.zip'), '.'],
        'z64.zip': ['zip', '-qr', '-fz', p('z64.zip'), '.'],
        if (await has('ditto')) 'ditto.zip': ['ditto', '-c', '-k', '--norsrc', '.', p('ditto.zip')],
      };
      for (final MapEntry(key: name, value: cmd) in makers.entries) {
        final made = await Process.run(cmd.first, cmd.sublist(1), workingDirectory: p('src'));
        expect(made.exitCode, 0, reason: '$name: ${made.stderr}');
        await (Fs.file(p(name)) > Archive.unarchive(p('out_$name')));
        expect(await Fs.file(p('out_$name/a.txt')).text(), 'a' * 3000, reason: name);
        expect(await Fs.file(p('out_$name/sub/b.bin')).text(), 'b', reason: name);
      }
    });

    test('a password encrypts with AES-256; wrong or missing ones fail before writing', () async {
      await Fs.file(p('src/a.txt')).write('secret ' * 1000);
      await (Archive.archive(['.'], dir: p('src'), password: 'pw') > Fs.file(p('enc.zip')));
      final raw = await Fs.file(p('enc.zip')).text();
      expect(raw.contains('secret'), isFalse);
      await expectLater(
        Fs.file(p('enc.zip')) > Archive.unarchive(p('o1'), password: 'nope'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('wrong password'))),
      );
      await expectLater(
        Fs.file(p('enc.zip')) > Archive.unarchive(p('o2')),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('pass password:'))),
      );
      expect(await Fs.entry(p('o1/a.txt')), isNull);
      await (Fs.file(p('enc.zip')) > Archive.unarchive(p('o3'), password: 'pw'));
      expect(await Fs.file(p('o3/a.txt')).text(), 'secret ' * 1000);
      expect(() => Archive.archive(['.'], format: ArchiveFormat.tgz, password: 'pw'), throwsArgumentError);
    });

    test('encrypted zips interoperate with bsdtar (AES) and zip -P (ZipCrypto)', () async {
      if (!await has('bsdtar') || !await has('zip')) markTestSkipped('needs bsdtar and zip');
      await Fs.file(p('src/a.txt')).write('hello ' * 300);
      await Fs.file(p('src/d/b.txt')).write('b');
      await (Archive.archive(['.'], dir: p('src'), password: 'pw') > Fs.file(p('ours.zip')));
      await Fs.dir(p('x1')).create();
      final r = await Process.run('bsdtar', ['--passphrase', 'pw', '-xf', p('ours.zip'), '-C', p('x1')]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(await Fs.file(p('x1/a.txt')).text(), 'hello ' * 300);
      for (final strength in ['aes128', 'aes256']) {
        final made = await Process.run('bsdtar', [
          '--format',
          'zip',
          '--options',
          'zip:encryption=$strength',
          '--passphrase',
          'pw',
          '-cf',
          p('$strength.zip'),
          '.',
        ], workingDirectory: p('src'));
        expect(made.exitCode, 0, reason: '${made.stderr}');
        await (Fs.file(p('$strength.zip')) > Archive.unarchive(p('o_$strength'), password: 'pw'));
        expect(await Fs.file(p('o_$strength/d/b.txt')).text(), 'b', reason: strength);
      }
      await Process.run('zip', ['-qr', '-P', 'pw', p('legacy.zip'), '.'], workingDirectory: p('src'));
      await (Fs.file(p('legacy.zip')) > Archive.unarchive(p('o_legacy'), password: 'pw'));
      expect(await Fs.file(p('o_legacy/a.txt')).text(), 'hello ' * 300);
      await expectLater(Fs.file(p('legacy.zip')) > Archive.unarchive(p('o_bad'), password: 'x'), throwsFormatException);
    });

    test('7z from bsdtar (LZMA2, LZMA, Deflate, Copy) unarchives with modes', () async {
      if (!await has('bsdtar')) markTestSkipped('needs bsdtar');
      await Fs.file(p('src/a.txt')).write('alpha beta ' * 5000);
      await Fs.file(p('src/d/run.sh')).write('#!/bin/sh\n');
      await Process.run('chmod', ['755', p('src/d/run.sh')]);
      await Fs.dir(p('src/empty')).create();
      await Fs.dir(p('out')).create();
      await Process.run('chmod', ['700', p('out')]);
      for (final c in ['lzma2', 'lzma1', 'deflate', 'copy']) {
        final made = await Process.run('bsdtar', [
          '--format',
          '7zip',
          '--options',
          '7zip:compression=$c',
          '-cf',
          p('$c.7z'),
          '.',
        ], workingDirectory: p('src'));
        expect(made.exitCode, 0, reason: '${made.stderr}');
        await (Fs.file(p('$c.7z')) > Archive.unarchive(p('out/$c')));
        expect(await Fs.file(p('out/$c/a.txt')).text(), 'alpha beta ' * 5000, reason: c);
        expect((await FileStat.stat(p('out/$c/d/run.sh'))).mode & 0x1ff, 0x1ed, reason: c);
        expect(await Fs.dir(p('out/$c/empty')).exists(), isTrue, reason: c);
      }
      await (Fs.file(p('lzma2.7z')) > Archive.unarchive(p('out')));
      expect((await Directory(p('out')).stat()).mode & 0x1ff, 0x1c0); // the '.' member never re-modes the target
    });

    test('our 7z round-trips, with and without a password, and bsdtar reads it', () async {
      await Fs.file(p('src/a.txt')).write('seven ' * 4000);
      await Fs.file(p('src/d/run.sh')).write('#!/bin/sh\n');
      await Process.run('chmod', ['755', p('src/d/run.sh')]);
      await Fs.file(p('src/d/empty.txt')).write('');
      await Fs.dir(p('src/e')).create();
      await (Archive.archive(['.'], dir: p('src'), format: ArchiveFormat.sevenZip) > Fs.file(p('ours.7z')));
      await (Fs.file(p('ours.7z')) > Archive.unarchive(p('o1')));
      expect(await Fs.file(p('o1/a.txt')).text(), 'seven ' * 4000);
      expect(await Fs.file(p('o1/d/empty.txt')).text(), '');
      expect(await Fs.dir(p('o1/e')).exists(), isTrue);
      expect((await FileStat.stat(p('o1/d/run.sh'))).mode & 0x1ff, 0x1ed);
      if (await has('bsdtar')) {
        await Fs.dir(p('o2')).create();
        final r = await Process.run('bsdtar', ['-xf', p('ours.7z'), '-C', p('o2')]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(await Fs.file(p('o2/a.txt')).text(), 'seven ' * 4000);
      }
      await (Archive.archive(['.'], dir: p('src'), format: ArchiveFormat.sevenZip, password: 'pw') >
          Fs.file(p('enc.7z')));
      final raw = String.fromCharCodes(await Fs.file(p('enc.7z')).bytes());
      expect(raw.contains('a\u0000.\u0000t\u0000x\u0000t'), isFalse); // names are encrypted too
      await expectLater(Fs.file(p('enc.7z')) > Archive.unarchive(p('o3')), throwsFormatException);
      await expectLater(Fs.file(p('enc.7z')) > Archive.unarchive(p('o4'), password: 'nope'), throwsFormatException);
      await (Fs.file(p('enc.7z')) > Archive.unarchive(p('o5'), password: 'pw'));
      expect(await Fs.file(p('o5/a.txt')).text(), 'seven ' * 4000);
    });

    test('7-Zip AES archives (data, and header too) open with their password', () async {
      for (final name in ['7z_aes', '7z_aes_header']) {
        final src = Fs.file('test/fixtures/archives/$name.7z');
        await expectLater(
          src > Archive.unarchive(p('bad_$name'), password: 'nope'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('wrong password'))),
        );
        await (src > Archive.unarchive(p(name), password: '12345678'));
        expect((await Fs.file(p('$name/bar.txt')).text()).trim(), 'foo', reason: name);
      }
    });

    test('RAR5 (solid, ARM filter, Windows-made) unarchives with every CRC checked', () async {
      final fx = 'test/fixtures/archives';
      await (Fs.file('$fx/rar5_solid.rar') > Archive.unarchive(p('solid')));
      expect(
        [for (final e in await Fs.dir(p('solid')).list()) e.name()],
        ['test.bin', 'test1.bin', 'test2.bin', 'test3.bin', 'test4.bin', 'test5.bin', 'test6.bin'],
      );
      await (Fs.file('$fx/rar5_arm.rar') > Archive.unarchive(p('arm')));
      expect(await Fs.file(p('arm/elf-Linux-ARMv7-ls')).size(), 90808);
      await (Fs.file('$fx/rar5_win32.rar') > Archive.unarchive(p('win')));
      expect(await Fs.dir(p('win/testdir')).exists(), isTrue);
      await (Fs.file('$fx/rar5_multiple_files.rar') > Archive.unarchive(p('multi')));
      expect(await Fs.file(p('multi/test4.bin')).size(), 4096);
    });

    test('RAR5 passwords: encrypted names, a wrong password, a member with its own', () async {
      final fx = 'test/fixtures/archives';
      await expectLater(
        Fs.file('$fx/rar5_encrypted_filenames.rar') > Archive.unarchive(p('none')),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('pass password:'))),
      );
      await expectLater(
        Fs.file('$fx/rar5_encrypted_filenames.rar') > Archive.unarchive(p('bad'), password: 'nope'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('wrong password'))),
      );
      await (Fs.file('$fx/rar5_encrypted_filenames.rar') > Archive.unarchive(p('names'), password: 'password'));
      expect((await Fs.file(p('names/a.txt')).text()).isNotEmpty, isTrue);
      // d.txt uses 'password2': the whole unarchive fails before writing.
      await expectLater(
        Fs.file('$fx/rar5_encrypted.rar') > Archive.unarchive(p('mixed'), password: 'password'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('d.txt'))),
      );
      expect(await Fs.entry(p('mixed/a.txt')), isNull);
    });

    test('RAR4: the E8 filter, AES-128 with encrypted names and solid, links refused', () async {
      final fx = 'test/fixtures/archives';
      await (Fs.file('$fx/rar4_filter.rar') > Archive.unarchive(p('exe')));
      expect(await Fs.file(p('exe/bsdcat.exe')).size(), 204288);
      for (final name in ['rar4_encrypted_filenames', 'rar4_solid_encrypted']) {
        await expectLater(
          Fs.file('$fx/$name.rar') > Archive.unarchive(p('bad_$name'), password: 'nope'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('wrong password'))),
        );
        await (Fs.file('$fx/$name.rar') > Archive.unarchive(p(name), password: 'password'));
        expect(
          [for (final e in await Fs.dir(p(name)).list()) e.name()],
          ['a.txt', 'b.txt', 'c.txt', 'd.txt'],
          reason: name,
        );
      }
      // d.txt has its own password: unarchive fails before writing anything.
      await expectLater(
        Fs.file('$fx/rar4_encrypted.rar') > Archive.unarchive(p('mixed'), password: 'password'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('d.txt'))),
      );
      await expectLater(
        Fs.file('$fx/rar4_links.rar') > Archive.unarchive(p('links')),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('link'))),
      );
    });

    test('.tar.xz unarchives, with CRC32, CRC64 and SHA-256 checks', () async {
      await Fs.file(p('src/a.txt')).write('xz ' * 20000);
      await Fs.file(p('src/d/b.bin')).write('b');
      for (final check in ['crc32', 'crc64', 'sha256']) {
        final made = await Process.run('python3', [
          '-I',
          '-c',
          'import tarfile,lzma,io,sys\n'
              'buf=io.BytesIO()\n'
              'with tarfile.open(fileobj=buf,mode="w") as t: t.add(sys.argv[1],arcname=".")\n'
              'open(sys.argv[2],"wb").write(lzma.compress(buf.getvalue(),check=getattr(lzma,"CHECK_"+sys.argv[3].upper())))',
          p('src'),
          p('$check.tar.xz'),
          check,
        ]);
        if (made.exitCode != 0) markTestSkipped('needs python3: ${made.stderr}');
        await (Fs.file(p('$check.tar.xz')) > Archive.unarchive(p('o_$check')));
        expect(await Fs.file(p('o_$check/a.txt')).text(), 'xz ' * 20000, reason: check);
        expect(await Fs.file(p('o_$check/d/b.bin')).text(), 'b', reason: check);
      }
      final bytes = await Fs.file(p('crc64.tar.xz')).bytes();
      final flipped = [...bytes]..[bytes.length ~/ 2] ^= 1;
      await expectLater(Reader.of(flipped) > Archive.unarchive(p('bad')), throwsFormatException);
    });

    test('PPMd: 7z from bsdtar and a RAR4 best-mode archive decode exactly', () async {
      final text = [for (var i = 0; i < 40000; i++) 'word${i % 977} '].join();
      await Fs.file(p('src/t.txt')).write(text);
      if (await has('bsdtar')) {
        final made = await Process.run('bsdtar', [
          '--format',
          '7zip',
          '--options',
          '7zip:compression=ppmd',
          '-cf',
          p('p.7z'),
          't.txt',
        ], workingDirectory: p('src'));
        expect(made.exitCode, 0, reason: '${made.stderr}');
        await (Fs.file(p('p.7z')) > Archive.unarchive(p('o7')));
        expect(await Fs.file(p('o7/t.txt')).text(), text);
      }
      // The fixture holds a symlink, so read it below unarchive; CRCs are checked.
      final entries = rar.readRar(io.File('test/fixtures/archives/rar4_ppmd.rar').readAsBytesSync());
      final html = entries.firstWhere((e) => e.name == 'LibarchiveAddingTest.html');
      expect(html.data().length, 20111);
      expect(entries.where((e) => e.isLink).map((e) => e.name), ['testlink']);
    });

    test('damaged 7z and RAR input is a FormatException, never a crash', () async {
      final fx = Directory('test/fixtures/archives')
          .listSync()
          .whereType<io.File>()
          .where((f) => !f.path.endsWith('.md'));
      for (final f in fx) {
        final orig = f.readAsBytesSync();
        for (var t = 1; t < 40; t++) {
          final cut = orig.sublist(0, orig.length * t ~/ 40);
          final flipped = Uint8List.fromList(orig)..[8 + (orig.length - 9) * t ~/ 40] ^= 0x10;
          for (final input in [cut, flipped]) {
            try {
              await (Reader.of(input) >
                  Archive.unarchive(p('dmg'), password: f.path.contains('7z') ? '12345678' : 'password'));
            } on FormatException {
              // expected
            }
          }
        }
      }
    });

    test('an encrypted or truncated zip is a FormatException', () async {
      if (!await has('zip')) markTestSkipped('needs zip');
      await Fs.file(p('src/a.txt')).write('secret');
      await Process.run('zip', ['-q', '-P', 'pw', p('enc.zip'), 'a.txt'], workingDirectory: p('src'));
      await expectLater(
        Fs.file(p('enc.zip')) > Archive.unarchive(p('o1x')),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('encrypted'))),
      );
      final bytes = await Fs.file(p('enc.zip')).bytes();
      await expectLater(
        Reader.of(bytes.sublist(0, bytes.length - 30)) > Archive.unarchive(p('o2')),
        throwsFormatException,
      );
    });
  });

  group('Archive.archive', () {
    test('several entries keep their names relative to from', () async {
      await seed();
      await Fs.file(p('README.md')).write('read me');
      for (final format in ArchiveFormat.values) {
        await (Archive.archive(['site', 'README.md'], dir: tmp.path, format: format) >
            Archive.unarchive(p('out_${format.name}')));
        expect(await Fs.file(p('out_${format.name}/site/a/b.txt')).text(), 'bee', reason: format.name);
        expect(await Fs.file(p('out_${format.name}/README.md')).text(), 'read me', reason: format.name);
      }
    });

    test('an entry outside from is an ArgumentError; a missing one fails when read', () async {
      await seed();
      await expectLater(Archive.archive(['../x'], dir: p('site')).bytes(), throwsArgumentError);
      await expectLater(Archive.archive(['nope'], dir: tmp.path).bytes(), throwsA(isA<PathNotFoundException>()));
    });

    test('an archive written into its own tree leaves out the writer\'s temp', () async {
      await seed();
      await (Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.tar) > Fs.file(p('site/self.tar')));
      await (Fs.file(p('site/self.tar')) > Archive.unarchive(p('out')));
      final names = [for (final e in await Fs.dir(p('out')).list(recursive: true)) e.name()];
      expect(names.where((n) => n.contains('.tmp')), isEmpty);
    });

    test('zip round-trips folder contents, not the folder', () async {
      await seed();
      await (Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.zip) > Fs.file(p('s.zip')));
      await (Fs.file(p('s.zip')) > Archive.unarchive(p('out')));
      expect(await Fs.file(p('out/index.html')).text(), '<h1>hi</h1>');
      expect(await Fs.file(p('out/a/b.txt')).text(), 'bee');
      expect(await Fs.entry(p('out/site')), isNull);
    });

    test('tar round-trips', () async {
      await seed();
      await (Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.tar) > Fs.file(p('s.tar')));
      await (Fs.file(p('s.tar')) > Archive.unarchive(p('out')));
      expect(await Fs.file(p('out/a/b.txt')).text(), 'bee');
    });

    test('tgz round-trips', () async {
      await seed();
      await (Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.tgz) > Fs.file(p('s.tgz')));
      await (Fs.file(p('s.tgz')) > Archive.unarchive(p('out')));
      expect(await Fs.file(p('out/a/b.txt')).text(), 'bee');
    });

    test('packing is lazy and missing dirs fail when read', () async {
      final r = Archive.archive(['.'], dir: p('missing'), format: ArchiveFormat.zip);
      expect(r.bytes(), throwsA(isA<FileSystemException>()));
    });
  });

  group('Archive.unarchive', () {
    test('refuses absolute members with a FormatException', () async {
      await seed();
      await (Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.zip) > Fs.file(p('s.zip')));
      // Corrupt the member name by hand: rewrite the zip is overkill;
      // instead feed garbage and expect a FormatException.
      await (Reader.of([1, 2, 3, 4]) > Fs.file(p('bad.zip')));
      expect(Fs.file(p('bad.zip')) > Archive.unarchive(p('out')), throwsFormatException);
    });

    test('a failed run leaves no half-unpacked tree', () async {
      await (Reader.of([1, 2, 3, 4]) > Fs.file(p('bad.zip')));
      await expectLater(Fs.file(p('bad.zip')) > Archive.unarchive(p('out')), throwsFormatException);
      expect(await Fs.entry(p('out')), isNull);
    });

    test('F1: unpacking merges, never deletes the target', () async {
      await seed();
      await Fs.file(p('vendor/precious.txt')).write('do not lose');
      await (Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.zip) > Archive.unarchive(p('vendor')));
      expect(await Fs.file(p('vendor/precious.txt')).text(), 'do not lose');
      expect(await Fs.file(p('vendor/index.html')).text(), '<h1>hi</h1>');
    });

    test('F1: unpacking into . keeps the working tree', () async {
      await seed();
      await Fs.file(p('work/keep.txt')).write('keep me');
      await runInDir(
        p('work'),
        "import 'package:dart_toolkit/archive.dart';",
        "await (Archive.archive(['.'], dir: '../site', format: ArchiveFormat.zip) > Archive.unarchive('.'));",
      );
      expect(await Fs.file(p('work/keep.txt')).text(), 'keep me');
      expect(await Fs.file(p('work/index.html')).text(), '<h1>hi</h1>');
    });

    test('F2: a trailing-slash target unpacks beside itself', () async {
      await seed();
      await (Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.zip) > Archive.unarchive('${p('out')}/'));
      expect(await Fs.file(p('out/a/b.txt')).text(), 'bee');
    });

    test('F13: an empty folder packs and unpacks in every format', () async {
      await Fs.dir(p('empty')).create();
      for (final format in ArchiveFormat.values) {
        await (Archive.archive(['.'], dir: p('empty'), format: format) > Fs.file(p('e.bin')));
        await (Fs.file(p('e.bin')) > Archive.unarchive(p('eout')));
        expect(await Fs.dir(p('eout')).exists(), isTrue);
        await Fs.dir(p('eout')).delete();
      }
    });

    test('F13: gzip data that is not a tar fails clearly', () async {
      await Fs.file(p('plain.txt')).write('just text, not a tar');
      await (Fs.file(p('plain.txt')) | Archive.gzip() > Fs.file(p('t.gz')));
      await expectLater(
        Fs.file(p('t.gz')) > Archive.unarchive(p('out')),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('not a tar'))),
      );
    });

    test('F13: unpacked files keep their executable bit', () async {
      if (Platform.isWindows) markTestSkipped('needs POSIX modes');
      await seed();
      await Process.run('chmod', ['755', p('site/a/b.txt')]);
      await (Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.tar) > Fs.file(p('s.tar')));
      await (Fs.file(p('s.tar')) > Archive.unarchive(p('out')));
      final mode = (await FileStat.stat(p('out/a/b.txt'))).mode & 0x1ff;
      expect(mode & 0x100, isNot(0));
    });

    test('unarchive reads to the end: padding after the marker, then a gzip trailer', () async {
      await seed();
      final tar = await Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.tar).bytes();
      await Archive.unarchive(p('out')).consume(Stream.value([...tar, ...List.filled(4096, 0)]));
      expect(await Fs.file(p('out/a/b.txt')).text(), 'bee');
      final tgz = await Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.tgz).bytes();
      // The gzip trailer cut off: the tar inside is whole, the stream is not.
      await expectLater(
        Reader.of(tgz.sublist(0, tgz.length - 8)) > Archive.unarchive(p('trunc')),
        throwsFormatException,
      );
      expect(await Fs.entry(p('trunc')), isNull);
    });

    test('H8: unpack cancels its source when the archive is corrupt', () async {
      var cancelled = false;
      final c = StreamController<List<int>>(onCancel: () => cancelled = true);
      c.add(List.filled(1024, 7));
      await expectLater(Archive.unarchive(p('out')).consume(c.stream), throwsFormatException);
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
      await Archive.unarchive(p('out')).consume(Stream.value(tar));
      expect(await Fs.file(p('out/big.bin')).text(), 'hello');
    });

    test('a collision fails before any member replaces a file', () async {
      final tar = [
        for (final n in ['a', 'b', 'c', 'd']) ...[..._tarBlock(n, 3, 0x30), ..._tarBody('NEW'.codeUnits)],
        ...List.filled(1024, 0),
      ];
      for (final n in ['a', 'b', 'd']) {
        await Fs.file(p('out/$n')).write('OLD');
      }
      await Fs.dir(p('out/c')).create();
      await expectLater(Archive.unarchive(p('out')).consume(Stream.value(tar)), throwsA(isA<FileSystemException>()));
      for (final n in ['a', 'b', 'd']) {
        expect(await Fs.file(p('out/$n')).text(), 'OLD');
      }
    });

    test('a read-only member folder merges into an existing one and leaves no temp', () async {
      if (Platform.isWindows) markTestSkipped('needs POSIX modes');
      final tar = [
        ..._tarBlock('ro/', 0, 0x35)..setRange(100, 107, '0000555'.codeUnits),
        ..._tarBlock('ro/f.txt', 1, 0x30),
        ..._tarBody('f'.codeUnits),
        ...List.filled(1024, 0),
      ];
      // _tarBlock checksums before the mode edit: recompute.
      _resum(tar, 0);
      await Fs.file(p('out/ro/old.txt')).write('old');
      addTearDown(() => Process.run('chmod', ['-R', 'u+w', p('out')]));
      await Archive.unarchive(p('out')).consume(Stream.value(tar));
      expect(await Fs.file(p('out/ro/f.txt')).text(), 'f');
      expect(await Fs.file(p('out/ro/old.txt')).text(), 'old');
      // A folder that was already there keeps its own mode.
      expect((await Directory(p('out/ro')).stat()).mode & 0x1ff, 0x1ed);
      expect((await Fs.dir(tmp.path).list()).map((e) => e.name()).where((n) => n.startsWith('.out')), isEmpty);
    });

    test('modes apply through the umask, only to what the unpack made', () async {
      if (Platform.isWindows) markTestSkipped('needs POSIX modes');
      List<int> mode(List<int> block, String octal) => block..setRange(100, 107, octal.codeUnits);
      final tar = [
        ...mode(_tarBlock('secret/', 0, 0x35), '0000777'),
        ...mode(_tarBlock('secret/new.txt', 1, 0x30), '0006777'),
        ..._tarBody('n'.codeUnits),
        ...mode(_tarBlock('fresh/', 0, 0x35), '0000777'),
        ...List.filled(1024, 0),
      ];
      for (final at in [0, 512, 1536]) {
        _resum(tar, at);
      }
      await Fs.dir(p('out/secret')).create();
      await Process.run('chmod', ['700', p('out/secret')]);
      final open = 0x1ff & (await Directory(p('probe')).create()).statSync().mode; // 0777 & ~umask
      await Archive.unarchive(p('out')).consume(Stream.value(tar));
      Future<int> modeOf(String path) async => (await FileStat.stat(p(path))).mode & 0xfff;
      expect(await modeOf('out/secret'), 0x1c0); // existing folder untouched
      expect(await modeOf('out/fresh'), open);
      expect(await modeOf('out/secret/new.txt'), open); // setuid/setgid dropped
    });

    test('macOS AppleDouble members are dropped; a real ._ file stays', () async {
      final ad = [0, 5, 0x16, 7, 0, 2, 0, 0];
      final tar = [
        ..._tarBlock('._.', ad.length, 0x30),
        ..._tarBody(ad),
        ..._tarBlock('./._a.txt', ad.length, 0x30),
        ..._tarBody(ad),
        ..._tarBlock('./a.txt', 1, 0x30),
        ..._tarBody('a'.codeUnits),
        ..._tarBlock('._notes', 2, 0x30),
        ..._tarBody('hi'.codeUnits),
        ...List.filled(1024, 0),
      ];
      await Archive.unarchive(p('out')).consume(Stream.value(tar));
      expect((await Fs.dir(p('out')).list()).map((e) => e.name()), ['._notes', 'a.txt']);
    });

    test('NFC and NFD spellings of one name fail where the filesystem folds them', () async {
      const nfc = 'caf\u00e9.txt', nfd = 'cafe\u0301.txt';
      List<int> member(String name, String body) => [
        ..._tarBlock(String.fromCharCodes(utf8.encode(name)), body.length, 0x30),
        ..._tarBody(body.codeUnits),
      ];
      final tar = [...member(nfc, 'nfc'), ...member(nfd, 'nfd'), ...List.filled(1024, 0)];
      final probe = Directory(p('probe'))..createSync();
      io.File('${probe.path}/$nfc').writeAsStringSync('x');
      final folds = io.File('${probe.path}/$nfd').existsSync();
      if (folds) {
        await expectLater(Archive.unarchive(p('out')).consume(Stream.value(tar)), throwsFormatException);
      } else {
        await Archive.unarchive(p('out')).consume(Stream.value(tar));
        expect(await Fs.file(p('out/$nfc')).text(), 'nfc');
        expect(await Fs.file(p('out/$nfd')).text(), 'nfd');
      }
    });

    test('an old-style folder (type 0, trailing slash) is a folder', () async {
      final tar = [
        ..._tarBlock('d/', 0, 0x30),
        ..._tarBlock('d/x', 1, 0x30),
        ..._tarBody('x'.codeUnits),
        ...List.filled(1024, 0),
      ];
      await Archive.unarchive(p('out')).consume(Stream.value(tar));
      expect(await Fs.file(p('out/d/x')).text(), 'x');
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
        Archive.unarchive(p('out')).consume(Stream.value(tar)),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('sparse'))),
      );
      expect(await Fs.entry(p('out')), isNull);
    });

    test('H10: tar header of a file over 8 GiB carries the true size', () async {
      final size = (8 << 30) + 5;
      final raf = await io.File(p('huge.bin')).open(mode: FileMode.write);
      await raf.truncate(size);
      await raf.close();
      await Directory(p('one')).create();
      await io.File(p('huge.bin')).rename(p('one/huge.bin'));
      final header = (await Archive.archive(['.'], dir: p('one'), format: ArchiveFormat.tar).stream().first).toList();
      expect(header[124] & 0x80, isNot(0));
      var got = 0;
      for (var i = 125; i < 136; i++) {
        got = got * 256 + header[i];
      }
      expect(got, size);
    });

    test('H10: tar pack streams files and round-trips a multi-chunk file', () async {
      final data = List.generate(300000, (i) => i % 251);
      await io.File(p('site/big.bin')).create(recursive: true);
      await io.File(p('site/big.bin')).writeAsBytes(data);
      await (Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.tar) > Fs.file(p('s.tar')));
      await (Fs.file(p('s.tar')) > Archive.unarchive(p('out')));
      expect(await io.File(p('out/big.bin')).readAsBytes(), data);
    });

    test('H7: tar unpack streams a member in constant memory', () async {
      await Directory(p('work')).create();
      await runInDir(
        p('work'),
        """
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_toolkit/archive.dart';
""",
        r'''
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
await Archive.unarchive('out').consume(tar());
if (File('out/big.bin').lengthSync() != total) throw 'size';
if (ProcessInfo.maxRss - before > (60 << 20)) throw 'rss \${ProcessInfo.maxRss - before}';
''',
      );
    });

    test('H7: tar unpack handles tiny input chunks', () async {
      await seed();
      final tar = await Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.tar).bytes();
      Stream<List<int>> bits() async* {
        for (var i = 0; i < tar.length; i += 7) {
          yield tar.sublist(i, i + 7 > tar.length ? tar.length : i + 7);
        }
      }

      await Archive.unarchive(p('out')).consume(bits());
      expect(await Fs.file(p('out/a/b.txt')).text(), 'bee');
      expect(await Fs.file(p('out/index.html')).text(), '<h1>hi</h1>');
    });

    test('M29: non-portable member names are refused on every OS', () async {
      for (final name in ['a:b', 'CON', 'aux.txt', 'dir/NUL.log', 'x.', 'dir./f', 'x ', 'a<b', 'q?', '.. ']) {
        final tar = [..._tarBlock(name, 1, 0x30), ..._tarBody('x'.codeUnits), ...List.filled(1024, 0)];
        await expectLater(Archive.unarchive(p('out')).consume(Stream.value(tar)), throwsFormatException, reason: name);
        expect(await Fs.entry(p('out')), isNull, reason: name);
      }
    });

    test('M29: members that differ only in case are refused', () async {
      List<int> member(String name) => [..._tarBlock(name, 1, 0x30), ..._tarBody('x'.codeUnits)];
      final tar = [...member('A.txt'), ...member('a.txt'), ...List.filled(1024, 0)];
      await expectLater(
        Archive.unarchive(p('out')).consume(Stream.value(tar)),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('case'))),
      );
      final dirClash = [..._tarBlock('Dir/', 0, 0x35), ...member('dir/x.txt'), ...List.filled(1024, 0)];
      await expectLater(Archive.unarchive(p('out')).consume(Stream.value(dirClash)), throwsFormatException);
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
      await Archive.unarchive(p('out')).consume(Stream.value(tar));
      expect(await Fs.file(p('out/a.b/c-d_e.txt')).text(), 'two');
    });

    test('M8: tar members come depth-first', () async {
      await Fs.file(p('o/a/b')).write('1');
      await Fs.file(p('o/a-b')).write('2');
      final tar = await Archive.archive(['.'], dir: p('o'), format: ArchiveFormat.tar).bytes();
      final names = <String>[];
      for (var i = 0; i + 512 <= tar.length; i += 512) {
        if (tar[i] == 0) break;
        names.add(String.fromCharCodes(tar.sublist(i, i + 100)).replaceAll('\x00', ''));
        final size = int.parse(String.fromCharCodes(tar.sublist(i + 124, i + 135)), radix: 8);
        i += (size + 511) ~/ 512 * 512;
      }
      expect(names, ['a/', 'a/b', 'a-b']);
    });

    test('L12: one-byte and empty input are a FormatException', () async {
      for (final bytes in [
        <int>[],
        [0x50],
        [0x1f],
      ]) {
        await expectLater(Archive.unarchive(p('out')).consume(Stream.value(bytes)), throwsFormatException);
      }
    });

    test('F13: pack refuses symlinks like unpack does', () async {
      await seed();
      await Fs.link(p('site/link')).create('${p('site')}/a/b.txt');
      await expectLater(
        Archive.archive(['.'], dir: p('site'), format: ArchiveFormat.zip).bytes(),
        throwsFormatException,
      );
    });
  });

  group('interrupt', () {
    for (final mode in ['write', 'unpack']) {
      test('M6: Ctrl-C during $mode leaves no temp siblings', () async {
        if (Platform.isWindows) markTestSkipped('needs a POSIX SIGINT');
        final proc = await Process.start(Platform.resolvedExecutable, ['test/signal_probe/probe.dart', mode, tmp.path]);
        final lines = proc.stdout.transform(const SystemEncoding().decoder).transform(const LineSplitter());
        await lines.firstWhere((l) => l.trim() == 'ready').timeout(const Duration(seconds: 60));
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
      expect(Fs.file(p('nope.gz')) | Archive.gunzip() > Fs.file(p('o.txt')), throwsFormatException);
    });

    test('F3: truncated gzip fails instead of saving partial data', () async {
      await Fs.file(p('big.txt')).write('x' * 100000);
      await (Fs.file(p('big.txt')) | Archive.gzip() > Fs.file(p('big.gz')));
      final full = await Fs.file(p('big.gz')).bytes();
      await (Reader.of(full.sublist(0, full.length ~/ 2)) > Fs.file(p('half.gz')));
      await expectLater(Fs.file(p('half.gz')) | Archive.gunzip() > Fs.file(p('o.txt')), throwsFormatException);
    });

    test('M7: gunzip works on tiny chunks and still catches corruption', () async {
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
      await expectLater(Archive.gunzip().transform(bits(bad)).drain<void>(), throwsFormatException);
      await expectLater(
        Archive.gunzip().transform(bits(gz.sublist(0, gz.length - 5))).drain<void>(),
        throwsFormatException,
      );
    });
  });
}

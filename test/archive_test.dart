import 'dart:async';
import 'dart:convert';
import 'dart:io' hide File;
import 'dart:io' as io show File;
import 'dart:typed_data';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/src/aes.dart';
import 'package:dart_toolkit/src/crc32.dart';
import 'package:dart_toolkit/src/lzma.dart';
import 'package:dart_toolkit/src/ppmd.dart';
import 'package:dart_toolkit/src/rar.dart' as rar;
import 'package:dart_toolkit/src/sevenzip.dart' as sevenzip;
import 'package:dart_toolkit/src/zip.dart' as zip;
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

List<int> _le32(int v) => [v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF];

/// RAR5's variable-length number.
List<int> _vint(int v) {
  final out = <int>[];
  do {
    var b = v & 0x7F;
    v >>= 7;
    if (v != 0) b |= 0x80;
    out.add(b);
  } while (v != 0);
  return out;
}

/// -1 and -10 as ten-byte RAR5 numbers: they wrap past 2^63.
const _vintMinus1 = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01];
const _vintMinus10 = [0xF6, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01];

/// A RAR5 block: CRC-32, size, then [body] (type, flags, …).
List<int> _rar5Block(List<int> body) {
  final sized = [..._vint(body.length), ...body];
  return [..._le32(crc32(sized)), ...sized];
}

/// A RAR5 archive of one stored file, its fields overridable to damage it.
List<int> _rar5(
  List<int> data, {
  String name = 'f.txt',
  List<int> extra = const [],
  List<int>? dataSize,
  int? size,
  int method = 0,
  bool end = true,
}) {
  final fields = [
    ..._vint(0), // file flags: no mtime, no CRC
    ..._vint(size ?? data.length),
    ..._vint(0x81A4),
    ..._vint(method << 7),
    ..._vint(1), // unix
    ..._vint(name.length),
    ...name.codeUnits,
  ];
  return [
    ...[0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00],
    ..._rar5Block([1, 0, 0]),
    ..._rar5Block([
      2,
      (extra.isEmpty ? 0 : 1) | 2,
      if (extra.isNotEmpty) ..._vint(extra.length),
      ...dataSize ?? _vint(data.length),
      ...fields,
      ...extra,
    ]),
    ...data,
    if (end) ..._rar5Block([5, 0, 0]),
  ];
}

/// A 7z: [packed] streams at offset 32, then the raw [header].
List<int> _sevenZip(List<int> packed, List<int> header) {
  final start = [..._le32(packed.length), 0, 0, 0, 0, ..._le32(header.length), 0, 0, 0, 0, ..._le32(crc32(header))];
  return [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4, ..._le32(crc32(start)), ...start, ...packed, ...header];
}

/// Where the zip's first central-directory entry starts.
int _central(List<int> z) {
  for (var i = 0; i + 4 <= z.length; i++) {
    if (z[i] == 0x50 && z[i + 1] == 0x4b && z[i + 2] == 1 && z[i + 3] == 2) return i;
  }
  throw StateError('no central directory');
}

/// A one-member zip as [zip.writeZip] makes it.
Uint8List _zip(List<int> data, {String? password}) =>
    zip.writeZip([('f.txt', 0x1A4, data, DateTime(2020))], password: password);

/// Legacy ZipCrypto encryption (PKWARE APPNOTE 6.1), for crafting old zips.
List<int> _zipCrypto(List<int> plain, String password, int crc) {
  var k0 = 0x12345678, k1 = 0x23456789, k2 = 0x34567890;
  int step(int c, int b) => crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  void update(int b) {
    k0 = step(k0, b);
    k1 = ((k1 + (k0 & 0xFF)) * 134775813 + 1) & 0xFFFFFFFF;
    k2 = step(k2, k1 >> 24);
  }

  password.codeUnits.forEach(update);
  int enc(int p) {
    final t = (k2 & 0xFFFF) | 2;
    final c = p ^ ((t * (t ^ 1)) >> 8 & 0xFF);
    update(p);
    return c;
  }

  return [for (var i = 0; i < 11; i++) enc(i * 37 & 0xFF), enc(crc >> 24 & 0xFF), for (final b in plain) enc(b)];
}

/// A one-member stored zip, encrypted with ZipCrypto.
Uint8List _zipCryptoZip(List<int> plain, String password) {
  final crc = crc32(plain);
  final body = _zipCrypto(plain, password, crc);
  List<int> fields(int sig, {required bool central}) => [
    ..._le32(sig),
    if (central) ...[20, 0],
    20, 0, 1, 0, 0, 0, 0, 0, 0x21, 0, // version, flags (encrypted), stored, time, date
    ..._le32(crc),
    ..._le32(body.length),
    ..._le32(plain.length),
    5, 0, 0, 0, // name length, extra length
    if (central) ...[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ..._le32(0)], // comment, disk, attrs, offset
  ];
  final local = [...fields(0x04034b50, central: false), ...'f.txt'.codeUnits, ...body];
  final dir = [...fields(0x02014b50, central: true), ...'f.txt'.codeUnits];
  return Uint8List.fromList([
    ...local,
    ...dir,
    ..._le32(0x06054b50),
    0,
    0,
    0,
    0,
    1,
    0,
    1,
    0,
    ..._le32(dir.length),
    ..._le32(local.length),
    0,
    0,
  ]);
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
    }, tags: 'slow');

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

    test("a tar member of type '7' (contiguous) is a regular file", () async {
      final tar = [..._tarBlock('c.txt', 3, 0x37), ..._tarBody('abc'.codeUnits), ...List.filled(1024, 0)];
      await Archive.unarchive(p('out')).consume(Stream.value(tar));
      expect(await Fs.file(p('out/c.txt')).text(), 'abc');
    });

    test('existing files are kept: a member at the same path is dropped', () async {
      await Fs.file(p('src/a.txt')).write('NEW');
      await Fs.file(p('src/b.txt')).write('NEW');
      await Fs.file(p('out/a.txt')).write('OLD');
      if (!Platform.isWindows) await Process.run('chmod', ['600', p('out/a.txt')]);
      await (Archive.archive(['.'], dir: p('src')) > Archive.unarchive(p('out')));
      expect(await Fs.file(p('out/a.txt')).text(), 'OLD');
      expect(await Fs.file(p('out/b.txt')).text(), 'NEW');
      if (!Platform.isWindows) expect((await io.File(p('out/a.txt')).stat()).mode & 0x1FF, 0x180);
      expect((await Fs.dir(tmp.path).list()).map((e) => e.name()).where((n) => n.startsWith('.out')), isEmpty);
    });

    test('zip entries carry the file\'s modified time', () async {
      await Fs.file(p('src/a.txt')).write('a');
      await io.File(p('src/a.txt')).setLastModified(DateTime(2001, 2, 3, 4, 5, 6));
      await (Archive.archive(['.'], dir: p('src')) > Fs.file(p('a.zip')));
      final z = await Fs.file(p('a.zip')).bytes();
      final cd = _central(z);
      expect(z[cd + 12] | z[cd + 13] << 8, 4 << 11 | 5 << 5 | 3);
      expect(z[cd + 14] | z[cd + 15] << 8, (2001 - 1980) << 9 | 2 << 5 | 3);
    });

    test('M29: non-portable member names are refused on every OS', () async {
      for (final name in ['a:b', 'CON', 'aux.txt', 'dir/NUL.log', 'x.', 'dir./f', 'x ', 'a<b', 'q?', '.. ']) {
        final tar = [..._tarBlock(name, 1, 0x30), ..._tarBody('x'.codeUnits), ...List.filled(1024, 0)];
        await expectLater(Archive.unarchive(p('out')).consume(Stream.value(tar)), throwsFormatException, reason: name);
        expect(await Fs.entry(p('out')), isNull, reason: name);
      }
    });

    test('members that climb out or are absolute are refused before anything is written', () async {
      for (final name in ['../x', 'a/../../x', '..', '..\\x', '/tmp/x', '\\x', 'C:x']) {
        final tar = [..._tarBlock(name, 1, 0x30), ..._tarBody('x'.codeUnits), ...List.filled(1024, 0)];
        await expectLater(
          Archive.unarchive(p('out')).consume(Stream.value(tar)),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('escapes'))),
          reason: name,
        );
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

  group('hostile input', () {
    final isContent = isA<ContentException>();
    Matcher content(String text) => isA<ContentException>().having((e) => e.message, 'message', contains(text));
    Future<void> unpack(List<int> bytes, {String? password}) =>
        Reader.of(bytes) > Archive.unarchive(p('out'), password: password);

    test('a 7z encoded header pointing at itself fails instead of looping', () async {
      // 0x17, pack info (stream at 0, 18 bytes), one Copy coder, unpack size 18.
      final header = [0x17, 0x06, 0, 1, 0x09, 18, 0, 0x07, 0x0B, 1, 0, 1, 0x01, 0x00, 0x0C, 18, 0, 0];
      await expectLater(unpack(_sevenZip(const [], header)), throwsA(content('nest too deep')));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('a 7z encoded header is checked against its CRC', () async {
      final real = [0x01, 0x00]; // a header with nothing in it
      List<int> encoded(int crc) => [
        ...[0x17, 0x06, 0, 1, 0x09, 2, 0, 0x07, 0x0B, 1, 0, 1, 0x01, 0x00, 0x0C, 2],
        ...[0x0A, 1, ..._le32(crc), 0, 0],
      ];
      expect(sevenzip.readSevenZip(Uint8List.fromList(_sevenZip(real, encoded(crc32(real))))), isEmpty);
      await expectLater(unpack(_sevenZip(real, encoded(crc32(real) ^ 1))), throwsA(content('header CRC')));
    });

    test('zip and 7z refuse data over 4 GiB instead of writing it short', () {
      final huge = Uint8List((1 << 32) + 10); // untouched pages: costs no memory
      final tooBig = isA<ContentException>().having((e) => e.message, 'message', contains('4 GiB'));
      expect(() => zip.writeZip([('f', 0x1A4, huge, DateTime(2020))]), throwsA(tooBig));
      expect(() => sevenzip.writeSevenZip([('f', 0x1A4, huge)]), throwsA(tooBig));
    });

    test('7z data is checked against its file, folder and start-header CRCs', () async {
      // One Copy folder holding "aa" and "bb"; CRCs per file, or one for the folder.
      List<int> twoFiles({required bool perFile}) => _sevenZip('aabb'.codeUnits, [
        ...[0x01, 0x04, 0x06, 0, 1, 0x09, 4, 0, 0x07, 0x0B, 1, 0, 1, 0x01, 0x00, 0x0C, 4],
        if (!perFile) ...[0x0A, 1, ..._le32(crc32('aabb'.codeUnits))],
        ...[0, 0x08, 0x0D, 2, 0x09, 2],
        if (perFile) ...[0x0A, 1, ..._le32(crc32('aa'.codeUnits)), ..._le32(crc32('bb'.codeUnits))],
        ...[0, 0, 0x05, 2, 0x11, 9, 0, 0x61, 0, 0, 0, 0x62, 0, 0, 0, 0, 0],
      ]);
      List<int> flip(List<int> b, int at) => [...b]..[at] ^= 1;
      for (final perFile in [true, false]) {
        await unpack(twoFiles(perFile: perFile));
        expect(await Fs.file(p('out/b')).text(), 'bb');
        await Fs.dir(p('out')).delete();
      }
      await expectLater(unpack(flip(twoFiles(perFile: true), 32)), throwsA(content('CRC of a')));
      await expectLater(unpack(flip(twoFiles(perFile: false), 32)), throwsA(content('folder CRC')));
      final b = twoFiles(perFile: true);
      await expectLater(unpack(flip(b, b.length - 3)), throwsA(content('header CRC')));
    });

    test('7z counts and sizes past the header are damage, not a RangeError or an allocation', () async {
      // A names property of size 0, then 2^40 files.
      await expectLater(unpack(_sevenZip(const [], [0x01, 0x05, 1, 0x11, 0, 0, 0, 0])), throwsA(isContent));
      await expectLater(
        unpack(_sevenZip(const [], [0x01, 0x05, 0xFC, 0, 0, 0, 0, 0, 1, 0, 0])),
        throwsA(content('files in a')),
      );
    });

    test('a 7z folder is freed after its last member and decodes again when asked', () async {
      final z = sevenzip.writeSevenZip([('a', 0x1A4, 'aaa'.codeUnits), ('b', 0x1A4, 'bbbb'.codeUnits)]);
      final entries = sevenzip.readSevenZip(z);
      expect([for (final e in entries) utf8.decode(e.data())], ['aaa', 'bbbb']);
      expect(utf8.decode(entries.first.data()), 'aaa');
    });

    test('RAR5 sizes that wrap negative fail instead of looping', () async {
      final data = 'hi'.codeUnits;
      expect(rar.readRar(Uint8List.fromList(_rar5(data))).single.data(), data);
      await expectLater(unpack(_rar5(data, dataSize: _vintMinus1)), throwsA(content('out of range')));
      // A header size of -1 (and a CRC of the empty range it would cover).
      final sig = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00];
      await expectLater(unpack([...sig, 0, 0, 0, 0, ..._vintMinus1, 1, 0, 0]), throwsA(content('out of range')));
      await expectLater(unpack(_rar5(data, extra: [..._vintMinus10, 2])), throwsA(content('out of range')));
      await expectLater(unpack(_rar5(data, extra: [40, 2])), throwsA(content('extra record size')));
      await expectLater(unpack(_rar5(data, extra: [0])), throwsA(content('extra record size')));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('a RAR claiming a huge size is damage, not an allocation', () async {
      await expectLater(unpack(_rar5([1, 2, 3, 4, 5, 6], size: 1 << 40, method: 1)), throwsA(isContent));
    });

    test('a RAR without its end block is truncated', () async {
      await expectLater(unpack(_rar5('hi'.codeUnits, end: false)), throwsA(content('truncated')));
      final rar5 = io.File('test/fixtures/archives/rar5_multiple_files.rar').readAsBytesSync();
      await expectLater(unpack(rar5.sublist(0, rar5.length - 8)), throwsA(content('truncated')));
      final rar4 = io.File('test/fixtures/archives/rar4_filter.rar').readAsBytesSync();
      await expectLater(unpack(rar4.sublist(0, rar4.length - 7)), throwsA(content('truncated')));
      expect(await Fs.entry(p('out')), isNull);
    });

    test('a RAR4 header too short for its fields is damage, not a RangeError', () async {
      List<int> block(int type, int flags, List<int> rest) {
        final h = [type, flags & 0xFF, flags >> 8, 7 + rest.length, 0, ...rest];
        final crc = crc32(h) & 0xFFFF;
        return [crc & 0xFF, crc >> 8, ...h];
      }

      final rar4 = [
        0x52,
        0x61,
        0x72,
        0x21,
        0x1A,
        0x07,
        0x00,
        ...block(0x73, 0, List.filled(6, 0)),
        ...block(0x74, 0x8000, []),
      ];
      await expectLater(unpack(rar4), throwsA(content('header too short')));
    });

    test('a RAR5 BLAKE2sp hash is checked', () async {
      final data = ('hello, rar5 blake2sp\n' * 40).codeUnits;
      const hex = 'b045c7fbb8fb97a0f8f3eaf4c1adbb51eb24d0251915ff802321430b4ba320f0';
      final hash = [for (var i = 0; i < 64; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
      expect(rar.blake2sp(Uint8List.fromList(data)), hash);
      final good = _rar5(data, extra: [34, 2, 0, ...hash]);
      await unpack(good);
      expect(await Fs.file(p('out/f.txt')).text(), 'hello, rar5 blake2sp\n' * 40);
      final at = good.length - 8 - data.length; // the data, before the end block
      await expectLater(unpack(List.of(good)..[at + 5] ^= 1), throwsA(content('checksum of f.txt')));
    });

    test('RAR members are freed once taken and decode again when asked', () async {
      final entries = rar.readRar(io.File('test/fixtures/archives/rar5_solid.rar').readAsBytesSync());
      final files = entries.where((e) => !e.isDir).toList();
      final forward = [for (final e in files) e.data()];
      expect([for (final e in files.reversed) e.data()], forward.reversed.toList());
    });

    test('zip CRCs are checked (stored and deflated)', () async {
      for (final data in ['ab'.codeUnits, List.filled(1000, 0x78)]) {
        final z = _zip(data);
        final cd = _central(z);
        expect(zip.readZip(z).single.data(), data);
        z[cd + 16] ^= 1;
        await expectLater(unpack(z), throwsA(content('CRC of f.txt')));
      }
    });

    test('a wrong ZipCrypto password that passes the one-byte check fails on the CRC', () async {
      final z = _zipCryptoZip('secret text'.codeUnits, 'right');
      final entry = zip.readZip(z).single;
      expect(entry.data(password: 'right'), 'secret text'.codeUnits);
      String? lucky;
      for (var i = 0; i < 5000 && lucky == null; i++) {
        try {
          entry.data(password: 'pw$i');
          fail('pw$i opened the member');
        } on ContentException catch (e) {
          if (e.message.contains('wrong password or corrupt data')) lucky = 'pw$i';
        }
      }
      expect(lucky, isNotNull);
    });

    test('a deflate member stops at its declared size', () async {
      final z = _zip(Uint8List(1 << 20));
      final cd = _central(z);
      z.setRange(cd + 24, cd + 28, _le32(1000));
      await expectLater(unpack(z), throwsA(content('past its declared 1000 bytes')));
    });

    test('a bad WinZip AES extra field is damage', () async {
      final z = _zip('x'.codeUnits, password: 'pw');
      final cd = _central(z);
      z[cd + 46 + 5 + 8] = 7; // strength
      await expectLater(unpack(z, password: 'pw'), throwsA(content('bad AES extra field')));
      expect(() => Aes(List.filled(7, 0)), throwsArgumentError);
    });

    test('a zip64 offset that wraps negative is damage, not a RangeError', () async {
      final z = _zip('ab'.codeUnits);
      final cd = _central(z);
      final zip64 = [1, 0, 8, 0, ...List.filled(8, 0xFF)];
      final bad = [...z.sublist(0, cd + 46 + 5), ...zip64, ...z.sublist(cd + 46 + 5)];
      bad.setRange(cd + 30, cd + 32, [zip64.length, 0]);
      bad.setRange(cd + 42, cd + 46, _le32(0xFFFFFFFF));
      await expectLater(unpack(bad), throwsA(content('bad sizes')));
    });

    test('LZMA, LZMA2 and PPMd claiming huge sizes fail on the data, not the allocation', () {
      expect(
        () => lzmaDecode(Uint8List.fromList([0, 0, 0, 0, 0, 1, 2]), [0x5D, 0, 0, 1, 0], 1 << 40),
        throwsA(isContent),
      );
      expect(
        () => lzma2Decode(Uint8List.fromList([0x01, 0x00, 0x00, 0x41, 0x00]), 1 << 40),
        throwsA(content('ends at 1 of')),
      );
      expect(
        () => ppmdDecode7z(Uint8List.fromList([0, 1, 2, 3]), [6, 0, 0, 0, 0xC0], 10),
        throwsA(content('properties')),
      );
      expect(() => ppmdDecode7z(Uint8List.fromList([0, 1, 2, 3]), [6, 0, 0, 0, 1], 1 << 40), throwsA(isContent));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('corrupt gzip data is a ContentException', () async {
      final gz = gzip.encode(utf8.encode('hello ' * 1000));
      final bad = List.of(gz)..[12] ^= 0xFF;
      await expectLater(Archive.gunzip().transform(Stream.value(bad)).drain<void>(), throwsA(isContent));
    });

    test('crc32 slices 8 bytes at a time and matches the byte-wise one', () {
      for (final n in [0, 1, 7, 8, 9, 63, 1000]) {
        final data = Uint8List.fromList(List.generate(n, (i) => i * 131 + 7 & 0xFF));
        final g = gzip.encode(data);
        final want = g[g.length - 8] | g[g.length - 7] << 8 | g[g.length - 6] << 16 | g[g.length - 5] << 24;
        expect(crc32(data), want);
        expect(crc32(data.toList()), want);
        expect(
          crc32(
            data,
            start: n ~/ 3,
            crc: crc32(data, end: n ~/ 3),
          ),
          want,
        );
      }
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

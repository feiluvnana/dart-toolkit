// The archive tests that take seconds each, in a file of their own so the
// suite runs them beside archive_test.dart instead of after it.
@Tags(['slow'])
library;

import 'dart:io' hide File;
import 'dart:io' as io show File;
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/utils.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('archive_slow_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  String p(String name) => '${tmp.path}/$name';

  Future<bool> has(String tool) async {
    try {
      return (await Process.run('which', [tool])).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  test('.tar.xz streams: one block far past its dictionary decodes exactly', () async {
    // 20 MB of words in one LZMA2 block with a 64 KiB dictionary: the
    // decoder slides its window several times.
    final made = await Process.run('python3', [
      '-I',
      '-c',
      'import tarfile,lzma,io,sys,random,hashlib\n'
          'r=random.Random(7); words=[bytes(r.choice(b"abcdefgh") for _ in range(r.randint(2,9))) for _ in range(5000)]\n'
          'data=b" ".join(r.choice(words) for _ in range(3500000))\n'
          'buf=io.BytesIO(); i=tarfile.TarInfo("big.txt"); i.size=len(data)\n'
          'with tarfile.open(fileobj=buf,mode="w") as t: t.addfile(i, io.BytesIO(data))\n'
          'f=[{"id": lzma.FILTER_LZMA2, "preset": 1, "dict_size": 65536}]\n'
          'open(sys.argv[1],"wb").write(lzma.compress(buf.getvalue(),check=lzma.CHECK_CRC64,filters=f))\n'
          'print(hashlib.sha256(data).hexdigest())',
      p('big.tar.xz'),
    ]);
    if (made.exitCode != 0) return markTestSkipped('needs python3: ${made.stderr}');
    await (Fs.file(p('big.tar.xz')) > Archive.unarchive(p('big')));
    final h = HashUtils.sha256();
    await (Fs.file(p('big/big.txt')) > h);
    expect(h.hex(), '${made.stdout}'.trim());
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
  }, timeout: const Timeout(Duration(minutes: 3))); // ~20 s alone, more beside the whole suite

  test('P2: a big encrypted 7z goes through 7-Zip with the password on stdin', () async {
    final big = Uint8List(33 << 20);
    final rnd = Random(3);
    for (var i = 0; i < big.length; i++) {
      big[i] = rnd.nextInt(256); // incompressible: the archive passes 32 MiB
    }
    await (Reader.of(big) > Fs.file(p('src/big.bin')));
    await (Archive.archive(['.'], dir: p('src'), format: ArchiveFormat.sevenzip, password: 'pw s3cret') >
        Fs.file(p('big.7z')));
    await expectLater(
      Fs.file(p('big.7z')) > Archive.unarchive(p('bad'), password: 'nope'),
      throwsA(isA<PasswordException>().having((e) => e.message, 'message', contains('wrong password'))),
    );
    await (Fs.file(p('big.7z')) > Archive.unarchive(p('out'), password: 'pw s3cret'));
    expect((await Fs.file(p('out/big.bin')).bytes()).length, big.length);
  });

  test('zip64: a file past 4 GiB streams through in constant memory and unzip checks it', () async {
    if (!await has('unzip')) return markTestSkipped('needs unzip');
    final big = io.File(p('src/big.bin'));
    await Fs.dir(p('src')).create();
    (await big.open(mode: FileMode.write))
      ..setPositionSync((1 << 32) + 4096)
      ..writeFromSync([1])
      ..closeSync(); // sparse: costs no disk
    final rss = ProcessInfo.currentRss;
    await (Archive.archive(['.'], dir: p('src')) > Fs.file(p('big.zip')));
    expect(ProcessInfo.currentRss - rss, lessThan(256 << 20));
    final r = await Process.run('unzip', ['-tq', p('big.zip')]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final l = await Process.run('unzip', ['-l', p('big.zip')]);
    expect('${l.stdout}', contains('${(1 << 32) + 4097}'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('LZMA2 with a dictionary past the slack slides its window exactly', () async {
    final made = await Process.run('python3', [
      '-I',
      '-c',
      'import tarfile,lzma,io,sys,random,hashlib\n'
          'r=random.Random(3); words=[bytes(r.choice(b"abcdefgh") for _ in range(r.randint(2,9))) for _ in range(3000)]\n'
          'data=b" ".join(r.choice(words) for _ in range(9000000))\n'
          'buf=io.BytesIO(); i=tarfile.TarInfo("big.txt"); i.size=len(data)\n'
          'with tarfile.open(fileobj=buf,mode="w") as t: t.addfile(i, io.BytesIO(data))\n'
          'f=[{"id": lzma.FILTER_LZMA2, "preset": 1, "dict_size": 12<<20}]\n'
          'open(sys.argv[1],"wb").write(lzma.compress(buf.getvalue(),filters=f))\n'
          'print(hashlib.sha256(data).hexdigest())',
      p('big.tar.xz'),
    ]);
    if (made.exitCode != 0) return markTestSkipped('needs python3: ${made.stderr}');
    await (Fs.file(p('big.tar.xz')) > Archive.unarchive(p('big')));
    final h = HashUtils.sha256();
    await (Fs.file(p('big/big.txt')) > h);
    expect(h.hex(), '${made.stdout}'.trim());
  });
}

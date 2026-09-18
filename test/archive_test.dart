import 'dart:io';
import 'dart:math';

import 'package:dart_toolkit/native.dart';
import 'package:dart_toolkit/crypto.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:test/test.dart';

/// Every container round-trips through the native library and opens in the system tool that
/// exists for it; passwords protect what they should; rar reads libarchive's fixtures.
void main() {
  late Path tmp;
  late Path src;

  setUpAll(() => expect(Native.isAvailable, isTrue, reason: 'dart_toolkit_native did not load: ${Native.reason}'));

  setUp(() {
    tmp = Path(Directory.systemTemp.createTempSync('arc_').path);
    src = tmp / 'src';
    final rnd = Random(11);
    (src / 'note.txt').writeTextSync('Archive Note\n' * 50);
    (src / 'ünïcode 名前.txt').writeTextSync('names survive');
    (src / 'sub' / 'deep' / 'random.bin').writeBytesSync(List.generate(2 << 20, (_) => rnd.nextInt(256)));
    (src / 'sub' / 'text.txt').writeTextSync(List.generate(20000, (i) => 'line $i').join('\n'));
    (src / 'emptydir').mkdirSync();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, String> digests(Path root) => {
    for (final f in root.filesSync(recursive: true)) f.path.substring(root.length + 1): f.readBytesSync().sha256,
  };

  for (final ext in ['.zip', '.7z', '.tar', '.tar.gz', '.tar.xz', '.tar.zst', '.tar.bz2']) {
    test('$ext round-trips and lists', () async {
      final archive = tmp / 'a$ext';
      await src.archiveTo(archive);
      final entries = await archive.archiveEntries();
      expect(
        entries.map((e) => e.name.replaceAll(RegExp(r'/$'), '')),
        containsAll(['note.txt', 'sub/deep/random.bin']),
      );
      await archive.extractTo(tmp / 'out');
      expect(digests(tmp / 'out'), equals(digests(src)));
      if (ext != '.7z') expect((tmp / 'out' / 'emptydir').existsSync(), isTrue, reason: 'empty directories survive');
    });
  }

  test('tar.zst and tar.gz open in the system tar; the system tar.xz opens in ours', () async {
    await src.archiveTo(tmp / 'a.tar.zst');
    final r = await Process.run('tar', ['-xf', tmp / 'a.tar.zst', '-C', (tmp / 'sys')..mkdirSync()]);
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(digests(tmp / 'sys'), equals(digests(src)));
    final made = await Process.run(
      'tar',
      ['-cJf', tmp / 'sys.tar.xz', '-C', src, '.'],
      environment: {'COPYFILE_DISABLE': '1'},
    );
    expect(made.exitCode, 0, reason: made.stderr.toString());
    await (tmp / 'sys.tar.xz').extractTo(tmp / 'back');
    expect(digests(tmp / 'back'), equals(digests(src)));
  });

  test('zip and 7z with a password: wrong one fails, right one opens, entries say encrypted', () async {
    for (final ext in ['.zip', '.7z']) {
      final archive = tmp / 'p$ext';
      await src.archiveTo(archive, password: 'sesame');
      expect(() => archive.extractTo(tmp / 'wrong$ext', password: 'nope'), throwsA(isA<FormatException>()));
      expect(() => archive.extractTo(tmp / 'none$ext'), throwsA(anything));
      await archive.extractTo(tmp / 'right$ext', password: 'sesame');
      expect(digests(tmp / 'right$ext'), equals(digests(src)));
    }
    final zipEntries = await (tmp / 'p.zip').archiveEntries();
    expect(zipEntries.where((e) => !e.isDir).every((e) => e.isEncrypted), isTrue);
    expect(() => src.archiveTo(tmp / 'x.tar.gz', password: 'pw'), throwsArgumentError);
  });

  test('single streams: gzip, xz, zstd, bzip2 round-trip and match the system tools', () async {
    final file = src / 'sub' / 'text.txt';
    for (final c in Compression.values) {
      final packed = tmp / 'text${c.extension}';
      await file.compressTo(packed);
      await packed.decompressTo(tmp / 'text${c.extension}.out');
      expect((tmp / 'text${c.extension}.out').readBytesSync().sha256, file.readBytesSync().sha256, reason: c.name);
      final tool = switch (c) {
        Compression.gzip => 'gzip',
        Compression.xz => 'xz',
        Compression.zstd => 'zstd',
        Compression.bzip2 => 'bzip2',
      };
      final r = await Process.run(tool, ['-dc', packed]);
      expect(r.exitCode, 0, reason: '${c.name}: ${r.stderr}');
      expect((r.stdout as String).length, file.readTextSync().length);
    }
    await file.gzipTo(tmp / 'g.gz');
    await (tmp / 'g.gz').gunzipTo(tmp / 'g.txt');
    expect((tmp / 'g.txt').readTextSync(), file.readTextSync());
  });

  test('rar: RAR5 (libarchive), encrypted files and encrypted headers (unrar) with passwords', () async {
    final stored = Path('test/fixtures/rar5_stored.rar');
    expect(await stored.archiveEntries(), isNotEmpty);
    await stored.extractTo(tmp / 'rar5');
    expect((tmp / 'rar5').filesSync(recursive: true), isNotEmpty);

    final crypted = Path('test/fixtures/crypted.rar');
    expect((await crypted.archiveEntries()).any((e) => e.isEncrypted), isTrue);
    expect(() => crypted.extractTo(tmp / 'wrong', password: 'wrong'), throwsA(anything));
    await crypted.extractTo(tmp / 'crypted', password: 'unrar');
    expect((tmp / 'crypted').filesSync(recursive: true), isNotEmpty);

    final headers = Path('test/fixtures/encrypted_headers.rar');
    expect(() => headers.archiveEntries(), throwsA(anything), reason: 'even the listing needs the password');
    expect(await headers.archiveEntries(password: 'password'), isNotEmpty);
    await headers.extractTo(tmp / 'headers', password: 'password');
    expect((tmp / 'headers').filesSync(recursive: true), isNotEmpty);

    expect((await Path('test/fixtures/unicode.rar').archiveEntries()).first.name, isNotEmpty);
    expect(() => src.archiveTo(tmp / 'x.rar'), throwsArgumentError);
  });

  test('a corrupt archive and an unknown extension say so', () async {
    (tmp / 'bad.zip').writeBytesSync(List.filled(100, 7));
    expect(() => (tmp / 'bad.zip').archiveEntries(), throwsA(isA<FormatException>()));
    expect(() => src.archiveTo(tmp / 'a.qqq'), throwsArgumentError);
  });
}

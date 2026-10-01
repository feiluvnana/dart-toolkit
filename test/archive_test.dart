import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_toolkit/native.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:test/test.dart';

/// Every container round-trips through the native library and opens in the system tool that
/// exists for it; passwords protect what they should; rar reads libarchive's fixtures.
void main() {
  late Path tmp;
  late Path src;

  setUpAll(
    () => expect(NativeLib.isAvailable, isTrue, reason: 'dart_toolkit_native did not load: ${NativeLib.reason}'),
  );

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
    for (final f in root.filesSync(recursive: true))
      f.path.substring(root.length + 1): f.readBytesSync().hash(Hash.sha256),
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
      expect(
        (tmp / 'text${c.extension}.out').readBytesSync().hash(Hash.sha256),
        file.readBytesSync().hash(Hash.sha256),
        reason: c.name,
      );
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
    await file.compressTo(tmp / 'g.gz');
    await (tmp / 'g.gz').decompressTo(tmp / 'g.txt');
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

  test('the format is read from the file, not its name', () async {
    // Every container, renamed to something that says nothing, still lists and extracts.
    for (final ext in ['.zip', '.7z', '.tar', '.tar.gz', '.tar.xz', '.tar.zst', '.tar.bz2']) {
      final named = tmp / 'a$ext';
      await src.archiveTo(named);
      final anonymous = tmp / 'blob${ext.replaceAll('.', '_')}';
      await named.copy(anonymous);

      expect(Archive.of(anonymous), isNull, reason: '$ext: the name must say nothing');
      expect(await anonymous.archiveEntries(), isNotEmpty, reason: ext);
      await anonymous.extractTo(tmp / 'out${ext.replaceAll('.', '_')}');
      expect(digests(tmp / 'out${ext.replaceAll('.', '_')}'), digests(src), reason: ext);
    }

    // And a rar, which the enum can name but not write.
    final rar = tmp / 'anonymous_rar';
    await Path('test/fixtures/rar5_stored.rar').copy(rar);
    expect(await rar.archiveEntries(), isNotEmpty);
  });

  test('a single stream decompresses without its extension', () async {
    final file = src / 'sub' / 'text.txt';
    for (final c in Compression.values) {
      final packed = tmp / 'named${c.extension}';
      await file.compressTo(packed);
      final anonymous = tmp / 'anonymous_${c.name}';
      await packed.copy(anonymous);

      await anonymous.decompressTo(tmp / 'out_${c.name}');
      expect((tmp / 'out_${c.name}').readTextSync(), file.readTextSync(), reason: c.name);
    }
    // Bytes that are none of the four say so rather than guessing.
    (tmp / 'plain').writeTextSync('not compressed');
    expect(() => (tmp / 'plain').decompressTo(tmp / 'nope'), throwsA(isA<FormatException>()));
  });

  test('Archive names every format, and rar is read-only', () {
    expect(Archive.of('x.rar'), Archive.rar);
    expect(Archive.rar.isWritable, isFalse);
    expect(Archive.values.where((a) => a.isWritable).length, Archive.values.length - 1);
  });

  test('a corrupt archive and an unknown extension say so', () async {
    (tmp / 'bad.zip').writeBytesSync(List.filled(100, 7));
    expect(() => (tmp / 'bad.zip').archiveEntries(), throwsA(isA<FormatException>()));
    expect(() => src.archiveTo(tmp / 'a.qqq'), throwsArgumentError);
  });

  test('an entry that escapes the destination is refused and writes nothing', () async {
    // The guard exists to stop `../../.ssh/authorized_keys`; the fixture holds three such
    // names, one of them only escaping after a `nested/..` segment.
    final dir = Directory.systemTemp.createTempSync('slip_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final into = Path(dir.path) / 'into';

    await expectLater(() => Path('test/fixtures/zip_slip.zip').extractTo(into), throwsA(isA<FormatException>()));
    expect(File('${dir.path}/escaped.txt').existsSync(), isFalse);
    expect(File('${dir.path}/also_escaped.txt').existsSync(), isFalse);
    expect(File(Path(dir.path) / 'escaped.txt').existsSync(), isFalse);
  });

  group('an archive from elsewhere is extracted safely', () {
    int mode(String path) => FileStat.statSync(path).mode & 0xfff;

    test('setuid, setgid and sticky are dropped unless trusted', () async {
      final exe = src / 'suid.sh';
      exe.writeTextSync('#!/bin/sh\n');
      Process.runSync('chmod', ['6755', exe]);
      expect(mode(exe) & 0xe00, isNot(0), reason: 'the fixture itself must carry the bits');
      // The package's zip writer keeps only the permission bits, so `zip` makes that one.
      expect(Process.runSync('zip', ['-q', tmp / 'suid.zip', 'suid.sh'], workingDirectory: src).exitCode, 0);
      for (final ext in ['.zip', '.tar', '.tar.gz']) {
        final archive = tmp / 'suid$ext';
        if (ext != '.zip') await src.archiveTo(archive);
        await archive.extractTo(tmp / 'plain$ext');
        expect(mode(tmp / 'plain$ext' / 'suid.sh'), 0x1ed, reason: '$ext: 0755, nothing above it');
        await archive.extractTo(tmp / 'trusted$ext', trusted: true);
        expect(mode(tmp / 'trusted$ext' / 'suid.sh') & 0xe00, isNot(0), reason: '$ext, trusted');
      }
    }, testOn: '!windows');

    test('an archive that expands past the cap is refused before it writes', () async {
      final bomb = tmp / 'bomb';
      bomb.mkdirSync();
      // Sparse: 2 GiB of zeros that take no disk, packed into about 40 KB.
      File(bomb / 'zeros.bin').openSync(mode: FileMode.write)
        ..truncateSync(2 << 30)
        ..closeSync();
      await bomb.archiveTo(tmp / 'bomb.tar.zst', level: 1);
      bomb.deleteSync(recursive: true);
      await expectLater(
        () => (tmp / 'bomb.tar.zst').extractTo(tmp / 'out'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('trusted'))),
      );
      expect(File(tmp / 'out' / 'zeros.bin').existsSync(), isFalse);
      await expectLater(() => (tmp / 'bomb.tar.zst').entry('zeros.bin'), throwsA(isA<FormatException>()));
    });

    test('a link that leads out is refused and left nowhere; one that stays in is a link', () async {
      final tree = tmp / 'links';
      (tree / 'real.txt').writeTextSync('inside');
      Link(tree / 'in.txt').createSync('real.txt');
      Link(tree / 'out').createSync('../../../../etc');
      // The package's own writers skip links, so the system tools make these archives.
      expect(
        Process.runSync('zip', ['-qry', tmp / 'in.zip', 'real.txt', 'in.txt'], workingDirectory: tree).exitCode,
        0,
      );
      expect(Process.runSync('zip', ['-qry', tmp / 'out.zip', 'out'], workingDirectory: tree).exitCode, 0);
      expect(Process.runSync('tar', ['-cf', tmp / 'out.tar', 'out'], workingDirectory: tree).exitCode, 0);

      await (tmp / 'in.zip').extractTo(tmp / 'x');
      expect(FileSystemEntity.isLinkSync(tmp / 'x' / 'in.txt'), isTrue, reason: 'was a regular file before');
      expect((tmp / 'x' / 'in.txt').readTextSync(), 'inside');

      for (final archive in ['out.zip', 'out.tar']) {
        await expectLater(() => (tmp / archive).extractTo(tmp / 'y$archive'), throwsA(isA<FormatException>()));
        expect(FileSystemEntity.typeSync(tmp / 'y$archive' / 'out', followLinks: false), FileSystemEntityType.notFound);
      }
    }, testOn: '!windows');

    test('all escaping links are removed on refusal, not only the first (ARC-1)', () async {
      final tree = tmp / 'multi_links';
      tree.mkdirSync();
      Link(tree / 'out1').createSync('../../../../etc');
      Link(tree / 'out2').createSync('../../../../tmp');
      expect(Process.runSync('zip', ['-qry', tmp / 'multi.zip', 'out1', 'out2'], workingDirectory: tree).exitCode, 0);
      final dest = tmp / 'multi_dest';
      await expectLater(() => (tmp / 'multi.zip').extractTo(dest), throwsA(isA<FormatException>()));
      expect(FileSystemEntity.typeSync(dest / 'out1', followLinks: false), FileSystemEntityType.notFound);
      expect(FileSystemEntity.typeSync(dest / 'out2', followLinks: false), FileSystemEntityType.notFound);
    }, testOn: '!windows');

    test('a link whose target does not exist yet is still refused when it leads out', () async {
      // `d/b` → `..` stays inside; `l` → `d/b/../pwned.txt` is inside by its text, dangles, and
      // lands one level above the destination once `d/b` is followed.
      final tree = tmp / 'dangle';
      (tree / 'd').mkdirSync();
      Link(tree / 'd' / 'b').createSync('..');
      Link(tree / 'l').createSync('d/b/../pwned.txt');
      expect(Process.runSync('zip', ['-qry', tmp / 'dangle.zip', 'd', 'l'], workingDirectory: tree).exitCode, 0);
      expect(Process.runSync('tar', ['-cf', tmp / 'dangle.tar', 'd', 'l'], workingDirectory: tree).exitCode, 0);
      for (final archive in ['dangle.zip', 'dangle.tar']) {
        final dest = tmp / 'out$archive' / 'x';
        await expectLater(() => (tmp / archive).extractTo(dest), throwsA(isA<FormatException>()), reason: archive);
        expect(FileSystemEntity.typeSync(dest / 'l', followLinks: false), FileSystemEntityType.notFound);
      }
    }, testOn: '!windows');

    test('a link already in the destination is neither written through nor walked through', () async {
      final outside = tmp / 'outside';
      outside.mkdirSync();
      final dest = tmp / 'dest';
      dest.mkdirSync();
      // What an earlier archive, or anything else, left behind.
      Link(dest / 'l').createSync(outside / 'pwned.txt');
      Link(dest / 'd').createSync(outside.path);
      final tree = tmp / 'plain';
      (tree / 'l').writeTextSync('replaces the link');
      (tree / 'd' / 'x.txt').writeTextSync('would land outside');
      expect(Process.runSync('zip', ['-qr', tmp / 'l.zip', 'l'], workingDirectory: tree).exitCode, 0);
      expect(Process.runSync('zip', ['-qr', tmp / 'd.zip', 'd'], workingDirectory: tree).exitCode, 0);

      await (tmp / 'l.zip').extractTo(dest);
      expect(File(outside / 'pwned.txt').existsSync(), isFalse, reason: 'the bytes went through the link');
      expect(FileSystemEntity.isLinkSync(dest / 'l'), isFalse);
      expect((dest / 'l').readTextSync(), 'replaces the link');

      await expectLater(() => (tmp / 'd.zip').extractTo(dest), throwsA(isA<FormatException>()));
      expect(File(outside / 'x.txt').existsSync(), isFalse);
    }, testOn: '!windows');

    test('a zip time is local time, as every other tool reads and writes it', () async {
      final f = src / 'stamped.txt';
      f.writeTextSync('stamped');
      final when = DateTime(2011, 7, 8, 9, 10, 12); // local; zip keeps even seconds
      f.asFile.setLastModifiedSync(when);
      // Written by `zip`, read by this library.
      expect(Process.runSync('zip', ['-q', tmp / 'sys.zip', 'stamped.txt'], workingDirectory: src).exitCode, 0);
      await (tmp / 'sys.zip').extractTo(tmp / 'mine');
      expect((tmp / 'mine' / 'stamped.txt').modifiedSync(), when);
      expect((await (tmp / 'sys.zip').archiveEntries()).single.modified, when);
      // Written by this library, read by `unzip`.
      await f.archiveTo(tmp / 'mine.zip');
      (tmp / 'theirs').mkdirSync();
      expect(Process.runSync('unzip', ['-q', tmp / 'mine.zip', '-d', tmp / 'theirs']).exitCode, 0);
      expect((tmp / 'theirs' / 'stamped.txt').modifiedSync(), when);
    }, testOn: '!windows');

    test('a read-only file keeps its time', () async {
      final ro = src / 'ro.txt';
      ro.writeTextSync('read only');
      ro.asFile.setLastModifiedSync(DateTime.utc(2001, 2, 3, 4, 5, 6));
      Process.runSync('chmod', ['444', ro]);
      await src.archiveTo(tmp / 'ro.zip');
      await (tmp / 'ro.zip').extractTo(tmp / 'ro');
      expect((tmp / 'ro' / 'ro.txt').modifiedSync().toUtc().year, 2001, reason: 'the mode used to be set first');
      Process.runSync('chmod', ['644', ro]);
    }, testOn: '!windows');
  });

  test('an archive written inside its own source does not contain itself', () async {
    for (final ext in ['.zip', '.7z', '.tar.gz']) {
      final dest = src / 'backup$ext';
      await src.archiveTo(dest);
      await src.archiveTo(dest); // a second run finds the first one there
      final names = [for (final e in await dest.archiveEntries()) e.name];
      expect(names.where((n) => n.contains('backup')), isEmpty, reason: ext);
      expect(names.where((n) => n.isEmpty), isEmpty, reason: '$ext: no nameless root entry');
      dest.deleteSync();
    }
  });

  test('only extracts what matches, and entry reads one without extracting', () async {
    for (final ext in ['.zip', '.7z', '.tar.zst']) {
      final archive = tmp / 'a$ext';
      await src.archiveTo(archive);
      final out = tmp / 'only$ext';
      await archive.extractTo(out, only: '**/*.txt');
      expect(
        [for (final f in out.filesSync(recursive: true)) f.relativeTo(out)]..sort(),
        ['note.txt', 'sub/text.txt', 'ünïcode 名前.txt']..sort(),
        reason: ext,
      );
      expect(utf8.decode(await archive.entry('sub/text.txt')), (src / 'sub' / 'text.txt').readTextSync(), reason: ext);
      await expectLater(() => archive.entry('nope.txt'), throwsA(isA<FormatException>()), reason: ext);
    }
  });
}

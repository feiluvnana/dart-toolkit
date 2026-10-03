import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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
      f.path.substring(root.length + 1).replaceAll(r'\', '/'): f.readBytesSync().hash(Hash.sha256),
  };

  for (final ext in ['.zip', '.7z', '.tar', '.tar.gz', '.tar.xz', '.tar.zst', '.tar.bz2']) {
    test('$ext round-trips and lists', () async {
      final archive = tmp / 'a$ext';
      await src.compressTo(archive);
      final entries = await archive.entries();
      expect(
        entries.map((e) => e.name.replaceAll(RegExp(r'/$'), '')),
        containsAll(['note.txt', 'sub/deep/random.bin']),
      );
      await archive.decompressTo(tmp / 'out');
      expect(digests(tmp / 'out'), equals(digests(src)));
      if (ext != '.7z') expect((tmp / 'out' / 'emptydir').existsSync(), isTrue, reason: 'empty directories survive');
    });
  }

  test('tar.zst and tar.gz open in the system tar; the system tar.xz opens in ours', () async {
    await src.compressTo(tmp / 'a.tar.zst');
    final r = await Process.run('tar', ['-xf', tmp / 'a.tar.zst', '-C', (tmp / 'sys')..mkdirSync()]);
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(digests(tmp / 'sys'), equals(digests(src)));
    final made = await Process.run(
      'tar',
      ['-cJf', tmp / 'sys.tar.xz', '-C', src, '.'],
      environment: {'COPYFILE_DISABLE': '1'},
    );
    expect(made.exitCode, 0, reason: made.stderr.toString());
    await (tmp / 'sys.tar.xz').decompressTo(tmp / 'back');
    expect(digests(tmp / 'back'), equals(digests(src)));
  }, testOn: '!windows');

  test('zip and 7z with a password: wrong one fails, right one opens, entries say encrypted', () async {
    for (final ext in ['.zip', '.7z']) {
      final archive = tmp / 'p$ext';
      await src.compressTo(archive, password: 'sesame');
      expect(() => archive.decompressTo(tmp / 'wrong$ext', password: 'nope'), throwsA(isA<FormatException>()));
      expect(() => archive.decompressTo(tmp / 'none$ext'), throwsA(anything));
      await archive.decompressTo(tmp / 'right$ext', password: 'sesame');
      expect(digests(tmp / 'right$ext'), equals(digests(src)));
    }
    final zipEntries = await (tmp / 'p.zip').entries();
    expect(zipEntries.where((e) => !e.isDir).every((e) => e.isEncrypted), isTrue);
    final szEntries = await (tmp / 'p.7z').entries(password: 'sesame');
    expect(szEntries.where((e) => !e.isDir).every((e) => e.isEncrypted), isTrue);
    expect(() => src.compressTo(tmp / 'x.tar.gz', password: 'pw'), throwsFormatException);
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
      ProcessResult? r;
      try {
        r = await Process.run(tool, ['-dc', packed]);
      } on ProcessException {
        // External tool not available on this platform.
      }
      if (r != null) {
        expect(r.exitCode, 0, reason: '${c.name}: ${r.stderr}');
        expect((r.stdout as String).length, file.readTextSync().length);
      }
    }
    await file.compressTo(tmp / 'g.gz');
    await (tmp / 'g.gz').decompressTo(tmp / 'g.txt');
    expect((tmp / 'g.txt').readTextSync(), file.readTextSync());
  });

  test('rar: RAR5 (libarchive), encrypted files and encrypted headers (unrar) with passwords', () async {
    final stored = Path('test/fixtures/rar5_stored.rar');
    expect(await stored.entries(), isNotEmpty);
    await stored.decompressTo(tmp / 'rar5');
    expect((tmp / 'rar5').filesSync(recursive: true), isNotEmpty);

    final crypted = Path('test/fixtures/crypted.rar');
    expect((await crypted.entries()).any((e) => e.isEncrypted), isTrue);
    expect(() => crypted.decompressTo(tmp / 'wrong', password: 'wrong'), throwsA(anything));
    await crypted.decompressTo(tmp / 'crypted', password: 'unrar');
    expect((tmp / 'crypted').filesSync(recursive: true), isNotEmpty);

    final headers = Path('test/fixtures/encrypted_headers.rar');
    expect(() => headers.entries(), throwsA(anything), reason: 'even the listing needs the password');
    expect(await headers.entries(password: 'password'), isNotEmpty);
    await headers.decompressTo(tmp / 'headers', password: 'password');
    expect((tmp / 'headers').filesSync(recursive: true), isNotEmpty);

    expect((await Path('test/fixtures/unicode.rar').entries()).first.name, isNotEmpty);
    expect(() => src.compressTo(tmp / 'x.rar'), throwsFormatException);
  });

  test('the format is read from the file, not its name', () async {
    // Every container, renamed to something that says nothing, still lists and extracts.
    for (final ext in ['.zip', '.7z', '.tar', '.tar.gz', '.tar.xz', '.tar.zst', '.tar.bz2']) {
      final named = tmp / 'a$ext';
      await src.compressTo(named);
      final anonymous = tmp / 'blob${ext.replaceAll('.', '_')}';
      await named.copy(anonymous);

      expect(anonymous.ext, isEmpty, reason: '$ext: the name must say nothing');
      expect(await anonymous.entries(), isNotEmpty, reason: ext);
      await anonymous.decompressTo(tmp / 'out${ext.replaceAll('.', '_')}');
      expect(digests(tmp / 'out${ext.replaceAll('.', '_')}'), digests(src), reason: ext);
    }

    // And a rar.
    final rar = tmp / 'anonymous_rar';
    await Path('test/fixtures/rar5_stored.rar').copy(rar);
    expect(await rar.entries(), isNotEmpty);
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

  test('rar and a tar with a password are refused by name, before anything is made', () async {
    final out = tmp / 'made' / 'here';
    await expectLater(
      () => src.compressTo(out / 'x.rar'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('rar can only be read'))),
    );
    await expectLater(
      () => src.compressTo(out / 'x.tar.gz', password: 'pw'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('tar has no encryption'))),
    );
    expect((tmp / 'made').existsSync(), isFalse, reason: 'not even the destination folder');
    // An extension that is no format lists the ones that can be written, which rar is not.
    await expectLater(
      () => src.compressTo(tmp / 'a.qqq'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          allOf(contains('.tar.zst'), isNot(contains('.rar'))),
        ),
      ),
    );
  });

  test('a corrupt archive and an unknown extension say so', () async {
    (tmp / 'bad.zip').writeBytesSync(List.filled(100, 7));
    expect(() => (tmp / 'bad.zip').entries(), throwsA(isA<FormatException>()));
    expect(() => src.compressTo(tmp / 'a.qqq'), throwsArgumentError);
  });

  test('an entry that escapes the destination is refused and writes nothing', () async {
    // The guard exists to stop `../../.ssh/authorized_keys`; the fixture holds three such
    // names, one of them only escaping after a `nested/..` segment.
    final dir = Directory.systemTemp.createTempSync('slip_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final into = Path(dir.path) / 'into';

    await expectLater(() => Path('test/fixtures/zip_slip.zip').decompressTo(into), throwsA(isA<FormatException>()));
    expect(File('${dir.path}/escaped.txt').existsSync(), isFalse);
    expect(File('${dir.path}/also_escaped.txt').existsSync(), isFalse);
    expect(File(Path(dir.path) / 'escaped.txt').existsSync(), isFalse);
  });

  group('an archive from elsewhere is extracted safely', () {
    int mode(String path) => FileStat.statSync(path).mode & 0xfff;

    test('setuid, setgid and sticky are dropped unless trusted', () async {
      final exe = src / 'suid.sh';
      exe.writeTextSync('#!/bin/sh\n');
      exe.chmodSync('6755');
      expect(mode(exe) & 0xe00, isNot(0), reason: 'the fixture itself must carry the bits');
      // The package's zip writer keeps only the permission bits, so `zip` makes that one.
      expect(Process.runSync('zip', ['-q', tmp / 'suid.zip', 'suid.sh'], workingDirectory: src).exitCode, 0);
      for (final ext in ['.zip', '.tar', '.tar.gz']) {
        final archive = tmp / 'suid$ext';
        if (ext != '.zip') await src.compressTo(archive);
        await archive.decompressTo(tmp / 'plain$ext');
        expect(mode(tmp / 'plain$ext' / 'suid.sh'), 0x1ed, reason: '$ext: 0755, nothing above it');
        await archive.decompressTo(tmp / 'trusted$ext', trusted: true);
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
      await bomb.compressTo(tmp / 'bomb.tar.zst', level: 1);
      bomb.deleteSync(recursive: true);
      await expectLater(
        () => (tmp / 'bomb.tar.zst').decompressTo(tmp / 'out'),
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

      await (tmp / 'in.zip').decompressTo(tmp / 'x');
      expect(FileSystemEntity.isLinkSync(tmp / 'x' / 'in.txt'), isTrue, reason: 'was a regular file before');
      expect((tmp / 'x' / 'in.txt').readTextSync(), 'inside');

      for (final archive in ['out.zip', 'out.tar']) {
        await expectLater(() => (tmp / archive).decompressTo(tmp / 'y$archive'), throwsA(isA<FormatException>()));
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
      await expectLater(() => (tmp / 'multi.zip').decompressTo(dest), throwsA(isA<FormatException>()));
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
        await expectLater(() => (tmp / archive).decompressTo(dest), throwsA(isA<FormatException>()), reason: archive);
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

      await (tmp / 'l.zip').decompressTo(dest);
      expect(File(outside / 'pwned.txt').existsSync(), isFalse, reason: 'the bytes went through the link');
      expect(FileSystemEntity.isLinkSync(dest / 'l'), isFalse);
      expect((dest / 'l').readTextSync(), 'replaces the link');

      await expectLater(() => (tmp / 'd.zip').decompressTo(dest), throwsA(isA<FormatException>()));
      expect(File(outside / 'x.txt').existsSync(), isFalse);
    }, testOn: '!windows');

    test('a zip time is local time, as every other tool reads and writes it', () async {
      final f = src / 'stamped.txt';
      f.writeTextSync('stamped');
      final when = DateTime(2011, 7, 8, 9, 10, 12); // local; zip keeps even seconds
      f.asFile.setLastModifiedSync(when);
      // Written by `zip`, read by this library.
      expect(Process.runSync('zip', ['-q', tmp / 'sys.zip', 'stamped.txt'], workingDirectory: src).exitCode, 0);
      await (tmp / 'sys.zip').decompressTo(tmp / 'mine');
      expect((tmp / 'mine' / 'stamped.txt').modifiedSync(), when);
      expect((await (tmp / 'sys.zip').entries()).single.modified, when);
      // Written by this library, read by `unzip`.
      await f.compressTo(tmp / 'mine.zip');
      (tmp / 'theirs').mkdirSync();
      expect(Process.runSync('unzip', ['-q', tmp / 'mine.zip', '-d', tmp / 'theirs']).exitCode, 0);
      expect((tmp / 'theirs' / 'stamped.txt').modifiedSync(), when);
    }, testOn: '!windows');

    test('a read-only file keeps its time', () async {
      final ro = src / 'ro.txt';
      ro.writeTextSync('read only');
      ro.asFile.setLastModifiedSync(DateTime.utc(2001, 2, 3, 4, 5, 6));
      ro.chmodSync('444');
      await src.compressTo(tmp / 'ro.zip');
      await (tmp / 'ro.zip').decompressTo(tmp / 'ro');
      expect((tmp / 'ro' / 'ro.txt').modifiedSync().toUtc().year, 2001, reason: 'the mode used to be set first');
      ro.chmodSync('644');
    }, testOn: '!windows');
  });

  test('an archive written inside its own source does not contain itself', () async {
    for (final ext in ['.zip', '.7z', '.tar.gz']) {
      final dest = src / 'backup$ext';
      await src.compressTo(dest);
      await src.compressTo(dest); // a second run finds the first one there
      final names = [for (final e in await dest.entries()) e.name];
      expect(names.where((n) => n.contains('backup')), isEmpty, reason: ext);
      expect(names.where((n) => n.isEmpty), isEmpty, reason: '$ext: no nameless root entry');
      dest.deleteSync();
    }
  });

  test('only extracts what matches, and entry reads one without extracting', () async {
    for (final ext in ['.zip', '.7z', '.tar.zst']) {
      final archive = tmp / 'a$ext';
      await src.compressTo(archive);
      final out = tmp / 'only$ext';
      await archive.decompressTo(out, only: '**/*.txt');
      expect(
        [for (final f in out.filesSync(recursive: true)) f.relativeTo(out).replaceAll(r'\', '/')]..sort(),
        ['note.txt', 'sub/text.txt', 'ünïcode 名前.txt']..sort(),
        reason: ext,
      );
      expect(utf8.decode(await archive.entry('sub/text.txt')), (src / 'sub' / 'text.txt').readTextSync(), reason: ext);
      await expectLater(() => archive.entry('nope.txt'), throwsA(isA<FormatException>()), reason: ext);
    }
  });

  test('ARC-2 & ARC-3: compression level validation and zip level 0 (Stored)', () async {
    final note = src / 'note.txt';
    // Invalid bzip2 level 0
    await expectLater(
      () => note.compressTo(tmp / 'bad.bz2', codec: Compression.bzip2, level: 0),
      throwsA(isA<FormatException>()),
    );
    // Invalid gzip negative level
    await expectLater(
      () => note.compressTo(tmp / 'bad.gz', codec: Compression.gzip, level: -5),
      throwsA(isA<FormatException>()),
    );
    // Invalid gzip level > 9
    await expectLater(
      () => note.compressTo(tmp / 'bad.gz', codec: Compression.gzip, level: 10),
      throwsA(isA<FormatException>()),
    );
    // Valid zstd negative level
    final zst = tmp / 'fast.zst';
    await note.compressTo(zst, codec: Compression.zstd, level: -1);
    expect(zst.existsSync(), isTrue);
    await zst.decompressTo(tmp / 'fast.txt');
    expect((tmp / 'fast.txt').readTextSync(), note.readTextSync());

    // Zip with level: 0 (Stored)
    final zipStored = tmp / 'stored.zip';
    await src.compressTo(zipStored, level: 0);
    final entries = await zipStored.entries();
    final noteEntry = entries.firstWhere((e) => e.name == 'note.txt');
    expect(noteEntry.compressedSize, equals(noteEntry.size));
    await zipStored.decompressTo(tmp / 'stored_out');
    expect(digests(tmp / 'stored_out'), equals(digests(src)));
  });

  test('ARC-4: 7z encryption flag and executable bit', () async {
    final archive = tmp / 'enc.7z';
    await src.compressTo(archive, password: 'secret');
    final entries = await archive.entries(password: 'secret');
    expect(entries.where((e) => !e.isDir).every((e) => e.isEncrypted), isTrue);

    if (!Platform.isWindows) {
      final script = src / 'run.sh';
      script.writeTextSync('#!/bin/sh\necho ok\n');
      script.chmodSync('755');
      final sz = tmp / 'exec.7z';
      await src.compressTo(sz);
      final out = tmp / 'exec_out';
      await sz.decompressTo(out);
      final stat = File((out / 'run.sh').path).statSync();
      expect(stat.mode & 0x1ED, 0x1ED); // 0755
    }
  });

  test('ARC-5: archive preserves symlinks in zip and tar', () async {
    final link = src / 'note_link.txt';
    Link(link.path).createSync('note.txt');
    for (final ext in ['.zip', '.tar', '.tar.gz']) {
      final arc = tmp / 'sym$ext';
      await src.compressTo(arc);
      final out = tmp / 'sym_out$ext';
      await arc.decompressTo(out);
      final outLink = Link((out / 'note_link.txt').path);
      expect(outLink.existsSync(), isTrue, reason: ext);
      expect(outLink.targetSync(), 'note.txt', reason: ext);
    }
  }, testOn: '!windows');

  test('ARC-6: directory permissions and mtimes are restored in reverse order', () async {
    final privDir = src / 'private_dir';
    privDir.mkdirSync();
    (privDir / 'secret.txt').writeTextSync('secret');
    privDir.chmodSync('700');

    for (final ext in ['.zip', '.7z', '.tar']) {
      final arc = tmp / 'perm$ext';
      await src.compressTo(arc);
      final out = tmp / 'perm_out$ext';
      await arc.decompressTo(out);
      final stat = Directory((out / 'private_dir').path).statSync();
      expect(stat.mode & 0x1FF, 0x1C0, reason: '$ext directory should restore 0700 mode');
    }
    privDir.chmodSync('755');
  }, testOn: '!windows');

  test('a stream large enough for every core round-trips through zstd and xz', () async {
    // 33 MiB is past the size at which both encoders go multi-threaded; xz at level 0 keeps
    // its blocks small enough that every worker gets some.
    final big = tmp / 'big.log';
    final mib = utf8.encode(
      [for (var i = 0; i < 1 << 14; i++) '${i * 2654435761 % 100000}'.padLeft(63, '-')].join('\n'),
    );
    final sink = big.asFile.openWrite();
    for (var i = 0; i < 33; i++) {
      sink.add(mib);
    }
    await sink.close();
    expect(big.sizeSync(), greaterThan(32 << 20));
    final want = await big.hash(Hash.xxh3);
    for (final (ext, level) in [('.zst', null), ('.xz', 0)]) {
      await big.compressTo(tmp / 'big$ext', level: level);
      await (tmp / 'big$ext').decompressTo(tmp / 'back$ext');
      expect(await (tmp / 'back$ext').hash(Hash.xxh3), want, reason: ext);
    }
    await (tmp / 'big.log').compressTo(tmp / 'big.tar.zst');
    await (tmp / 'big.tar.zst').decompressTo(tmp / 'tar');
    expect(await (tmp / 'tar' / 'big.log').hash(Hash.xxh3), want);
  });

  test('ARC-7: glob with braces and character classes in extractTo(only:)', () async {
    final arc = tmp / 'glob.zip';
    await src.compressTo(arc);

    final outBraces = tmp / 'braces_out';
    await arc.decompressTo(outBraces, only: '{note.txt,sub/text.txt}');
    expect(
      [for (final f in outBraces.filesSync(recursive: true)) f.relativeTo(outBraces).replaceAll(r'\', '/')]..sort(),
      ['note.txt', 'sub/text.txt']..sort(),
    );

    final outClasses = tmp / 'classes_out';
    await arc.decompressTo(outClasses, only: '[n]ote.txt');
    expect([for (final f in outClasses.filesSync(recursive: true)) f.relativeTo(outClasses)], ['note.txt']);
  });

  test('only: a leading ] is one of the set, and one brace alternative is literal', () async {
    final tree = tmp / 'names';
    for (final n in [']', 'a', 'b{1}.txt', 'b1.txt']) {
      (tree / n).writeTextSync(n);
    }
    final arc = tmp / 'names.zip';
    await tree.compressTo(arc);
    Future<List<String>> only(String glob) async {
      final out = tmp / 'only_${glob.hashCode}';
      await arc.decompressTo(out, only: glob);
      return [for (final f in out.filesSync()) f.name]..sort();
    }

    expect(await only('[]]'), [']']);
    expect(await only('[!]]'), ['a']);
    expect(await only('b{1}.txt'), ['b{1}.txt']);
  });

  test('a read-only directory in a tar extracts, and keeps its mode', () async {
    (src / 'ro' / 'f.txt').writeTextSync('hi');
    (src / 'ro').chmodSync('555');
    addTearDown(() {
      for (final d in [src / 'ro', tmp / 'out' / 'ro']) {
        if (d.existsSync()) d.chmodSync('755');
      }
    });
    await src.compressTo(tmp / 'ro.tar.gz');
    await (tmp / 'ro.tar.gz').decompressTo(tmp / 'out');
    expect((tmp / 'out' / 'ro' / 'f.txt').readTextSync(), 'hi');
    expect(FileStat.statSync(tmp / 'out' / 'ro').mode & 0x1ff, 0x16d); // 0555
  }, testOn: '!windows');

  test('an archive named bare, in the folder it archives, does not contain the last one', () async {
    // In a child process: the working directory is the whole test runner's.
    (tmp / 'self.dart').writeTextSync('''
import 'package:dart_toolkit/fs.dart';
void main() async {
  for (final ext in ['zip', 'tar.gz', '7z']) {
    await Path('.').compressTo('self.\$ext');
    await Path('.').compressTo('self.\$ext');
  }
}
''');
    final r = await Process.run(Platform.resolvedExecutable, [
      '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
      tmp / 'self.dart',
    ], workingDirectory: src);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    for (final ext in ['zip', 'tar.gz', '7z']) {
      expect((await (src / 'self.$ext').entries()).map((e) => e.name), isNot(contains('self.$ext')), reason: ext);
    }
  });

  test('a FIFO in the tree is skipped, not waited on', () async {
    (src / 'pipe').asFile.parent.createSync(recursive: true);
    expect(Process.runSync('mkfifo', [src / 'pipe']).exitCode, 0);
    for (final ext in ['zip', '7z', 'tar']) {
      await src.compressTo(tmp / 'p.$ext').timeout(const Duration(seconds: 10));
      expect((await (tmp / 'p.$ext').entries()).map((e) => e.name), isNot(contains('pipe')), reason: ext);
    }
  }, testOn: '!windows');

  group('Archive progress reporting', () {
    test('archive() streams progress events and archiveTo(onProgress:) receives them', () async {
      final destStream = tmp / 'progress_stream.zip';
      final streamEvents = await src.compress(destStream).toList();
      expect(streamEvents, isNotEmpty);
      expect(streamEvents.last.isDone, isTrue);
      expect(streamEvents.last.status, 'done');
      expect(streamEvents.last.completed, equals(streamEvents.last.total));
      expect(streamEvents.last.ratio, equals(1.0));

      final callbackEvents = <ArchiveProgress>[];
      final destCallback = tmp / 'progress_cb.zip';
      await src.compressTo(destCallback, onProgress: (p) => callbackEvents.add(p));
      expect(callbackEvents, isNotEmpty);
      expect(callbackEvents.last.isDone, isTrue);
      expect(callbackEvents.last.ratio, equals(1.0));
      expect(destCallback.existsSync(), isTrue);
    });

    test('extract() streams progress events and extractTo(onProgress:) receives them', () async {
      final archive = tmp / 'extract_test.zip';
      await src.compressTo(archive);

      final outStream = tmp / 'out_progress_stream';
      final extractEvents = await archive.decompress(outStream).toList();
      expect(extractEvents, isNotEmpty);
      expect(extractEvents.last.isDone, isTrue);
      expect(digests(outStream), equals(digests(src)));

      final outCb = tmp / 'out_progress_cb';
      final cbEvents = <ArchiveProgress>[];
      await archive.decompressTo(outCb, onProgress: (p) => cbEvents.add(p));
      expect(cbEvents, isNotEmpty);
      expect(cbEvents.last.isDone, isTrue);
      expect(digests(outCb), equals(digests(src)));
    });

    test('compress() and decompress() stream progress events', () async {
      final file = src / 'sub' / 'text.txt';
      final compressed = tmp / 'comp.gz';
      final compEvents = await file.compress(compressed).toList();
      expect(compEvents, isNotEmpty);
      expect(compEvents.last.isDone, isTrue);
      expect(compEvents.last.bytes, greaterThan(0));

      final decompressed = tmp / 'decomp.txt';
      final decompEvents = await compressed.decompress(decompressed).toList();
      expect(decompEvents, isNotEmpty);
      expect(decompEvents.last.isDone, isTrue);
      expect(decompressed.readTextSync(), file.readTextSync());
    });
  });
}

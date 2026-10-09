import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/native.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Every container round-trips through the native library and opens in the system tool that
/// exists for it; passwords protect what they should; rar reads libarchive's fixtures.
void main() {
  late Path tmp;
  late Path src;

  setUpAll(() async {
    final native = await Native.check();
    expect(native.missing['native'], isNull, reason: 'dart_toolkit_native did not load: ${native.reason}');
  });

  setUp(() async {
    tmp = tempDir('arc_');
    src = tmp / 'src';
    final rnd = Random(11);
    await (src / 'note.txt').writeText('Archive Note\n' * 50);
    await (src / 'ünïcode 名前.txt').writeText('names survive');
    await (src / 'sub' / 'deep' / 'random.bin').writeBytes(List.generate(2 << 20, (_) => rnd.nextInt(256)));
    await (src / 'sub' / 'text.txt').writeText(List.generate(20000, (i) => 'line $i').join('\n'));
    await (src / 'emptydir').mkdir();
  });

  Future<Map<String, String>> digests(Path root) async => {
    for (final f in await root.files(only: '**').toList())
      f.relativeTo(root).replaceAll(r'\', '/'): Hash.sha256.bytes(await f.readBytes()).hex,
  };

  Future<List<String>> names(String archive, {Secret? password}) async => [
    for (final e in (await Archive.read(archive, password: password)).entries)
      if (!e.isDir) e.name,
  ]..sort();

  /// What is in the temporary folder itself, by name.
  Future<List<String>> here() async => [for (final e in await tmp.entries().toList()) e.name]..sort();

  Future<List<String>> tree(Path root) async =>
      [for (final f in await root.files(only: '**').toList()) f.relativeTo(root).replaceAll(r'\', '/')]..sort();

  for (final ext in ['.zip', '.7z', '.tar', '.tar.gz', '.tar.xz', '.tar.zst', '.tar.bz2']) {
    test('$ext round-trips and lists', () async {
      final archive = tmp / 'a$ext';
      expect(await src.archive(to: archive), archive);
      final entries = (await Archive.read(archive)).entries;
      expect(
        entries.map((e) => e.name.replaceAll(RegExp(r'/$'), '')),
        containsAll(['note.txt', 'sub/deep/random.bin']),
      );
      expect(await archive.unarchive(into: tmp / 'out'), tmp / 'out');
      expect(await digests(tmp / 'out'), await digests(src));
      if (ext != '.7z') expect(await (tmp / 'out' / 'emptydir').exists(), isTrue, reason: 'empty folders survive');
    });
  }

  test('tar.zst opens in the system tar; the system tar.xz opens in ours', () async {
    await src.archive(to: tmp / 'a.tar.zst');
    final r = await Process.run('tar', ['-xf', tmp / 'a.tar.zst', '-C', await (tmp / 'sys').mkdir()]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(await digests(tmp / 'sys'), await digests(src));
    final made = await Process.run(
      'tar',
      ['-cJf', tmp / 'sys.tar.xz', '-C', src, '.'],
      environment: {'COPYFILE_DISABLE': '1'},
    );
    expect(made.exitCode, 0, reason: '${made.stderr}');
    await (tmp / 'sys.tar.xz').unarchive(into: tmp / 'back');
    expect(await digests(tmp / 'back'), await digests(src));
  }, testOn: '!windows');

  test('the format is the destination\'s extension; what has none, or is RAR, is an ArgumentError', () async {
    expect(() => src.archive(to: tmp / 'a.qqq'), throwsArgumentError);
    expect(() => src.archive(to: tmp / 'x.rar'), throwsArgumentError);
    expect(ArchiveFormat.of('a.tgz'), ArchiveFormat.tarGz);
    expect(ArchiveFormat.of('a.tar.gz'), ArchiveFormat.tarGz);
    expect(ArchiveFormat.of('a.gz'), ArchiveFormat.gz);
    expect(ArchiveFormat.of('A.ZIP'), ArchiveFormat.zip);
    expect(ArchiveFormat.of('a.txt'), isNull);
    expect(ArchiveFormat.gz.isStream, isTrue);
    expect(ArchiveFormat.tarGz.isStream, isFalse);
  });

  test('a single stream takes one file; password, only and flatten on one are an ArgumentError (ARC-6)', () async {
    final note = src / 'note.txt';
    expect(() => note.archive(to: tmp / 'n.gz', password: const Secret('pw')), throwsArgumentError);
    expect(() => src.archive(to: tmp / 'n.gz', only: '*'), throwsArgumentError);
    await expectLater(src.archive(to: tmp / 'folder.gz'), throwsArgumentError);
    await expectLater(note.archive(to: tmp / 'n.zip', only: '*'), throwsArgumentError);
    final gz = await note.archive(to: tmp / 'n.gz');
    for (final call in [
      () => gz.unarchive(into: tmp / 'o1', password: const Secret('pw')),
      () => gz.unarchive(into: tmp / 'o2', flatten: true),
      () => gz.unarchive(into: tmp / 'o3', only: '*'),
    ]) {
      await expectLater(call(), throwsArgumentError);
    }
    expect(await (tmp / 'o1').exists(), isFalse);
  });

  test('a single stream always lands in a folder: x.gz into out is out/x (ARC-5)', () async {
    final file = src / 'sub' / 'text.txt';
    for (final (ext, tool) in [('.gz', 'gzip'), ('.xz', 'xz'), ('.zst', 'zstd'), ('.bz2', 'bzip2')]) {
      final packed = await file.archive(to: tmp / 'text.txt$ext');
      expect(await packed.unarchive(into: tmp / 'out$ext'), tmp / 'out$ext');
      expect(await Hash.sha256.file(tmp / 'out$ext' / 'text.txt'), await Hash.sha256.file(file), reason: tool);
      // Without its extension, it is read from its bytes and keeps its name.
      final anonymous = await packed.copy(to: tmp / 'anonymous${ext.substring(1)}');
      await anonymous.unarchive(into: tmp / 'anon$ext');
      expect(await tree(tmp / 'anon$ext'), ['anonymous${ext.substring(1)}'], reason: ext);
      ProcessResult? r;
      try {
        r = await Process.run(tool, ['-dc', packed]);
      } on ProcessException {
        // External tool not available on this platform.
      }
      if (r != null) expect((r.exitCode, (r.stdout as String).length), (0, (await file.readText()).length));
    }
    await (tmp / 'plain').writeText('not compressed');
    await expectLater((tmp / 'plain').unarchive(into: tmp / 'nope'), throwsFormatException);
  });

  test('zip and 7z with a password: wrong one fails, right one opens, entries say encrypted', () async {
    const pw = Secret('sesame');
    for (final ext in ['.zip', '.7z']) {
      final archive = await src.archive(to: tmp / 'p$ext', password: pw);
      await expectLater(
        archive.unarchive(into: tmp / 'wrong$ext', password: const Secret('nope')),
        throwsA(isA<PasswordException>()),
        reason: ext,
      );
      await expectLater(archive.unarchive(into: tmp / 'none$ext'), throwsA(anything));
      await archive.unarchive(into: tmp / 'right$ext', password: pw);
      expect(await digests(tmp / 'right$ext'), await digests(src));
    }
    expect((await Archive.read(tmp / 'p.zip')).entries.where((e) => !e.isDir).every((e) => e.isEncrypted), isTrue);
    final sz = await Archive.read(tmp / 'p.7z', password: pw);
    expect(sz.entries.where((e) => !e.isDir).every((e) => e.isEncrypted), isTrue);
    await expectLater(
      src.archive(to: tmp / 'x.tar.gz', password: pw),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('tar has no encryption'))),
    );
    expect(await (tmp / 'x.tar.gz').exists(), isFalse);
  });

  test('a password never prints', () async {
    final archive = await src.archive(to: tmp / 'p.zip', password: const Secret('hunter2'));
    final outcome = await archive.unarchive(into: tmp / 'o', password: const Secret('swordfish')).settled;
    expect('$outcome', isNot(contains('swordfish')));
    expect('$outcome', isNot(contains('hunter2')));
  });

  test('Archive.detect reads the format from the content, else the name (ARC-12)', () async {
    for (final (ext, format) in [
      ('.zip', ArchiveFormat.zip),
      ('.7z', ArchiveFormat.sevenZip),
      ('.tar', ArchiveFormat.tar),
      ('.tar.gz', ArchiveFormat.tarGz),
      ('.tar.xz', ArchiveFormat.tarXz),
      ('.tar.zst', ArchiveFormat.tarZst),
      ('.tar.bz2', ArchiveFormat.tarBz2),
    ]) {
      final named = await src.archive(to: tmp / 'a$ext');
      final blob = await named.copy(to: tmp / 'blob${ext.replaceAll('.', '_')}');
      expect(await Archive.detect(blob), format, reason: ext);
      expect((await Archive.read(blob)).entries, isNotEmpty, reason: ext);
      await blob.unarchive(into: tmp / 'out${ext.replaceAll('.', '_')}');
      expect(await digests(tmp / 'out${ext.replaceAll('.', '_')}'), await digests(src), reason: ext);
    }
    final gz = await (src / 'note.txt').archive(to: tmp / 'note.gz');
    expect(await Archive.detect(gz), ArchiveFormat.gz, reason: 'a .gz is a format unarchive accepts');
    final notTar = await gz.copy(to: tmp / 'plain.tar.gz');
    expect(await Archive.detect(notTar), ArchiveFormat.gz, reason: 'named a tarball, holding one file');
    await (tmp / 'text.txt').writeText('not an archive');
    expect(await Archive.detect(tmp / 'text.txt'), isNull);
    expect(
      await Archive.detect(await Path('test/fixtures/rar5_stored.rar').copy(to: tmp / 'anon_rar')),
      ArchiveFormat.rar,
    );
    await expectLater(Archive.detect(tmp / 'none'), throwsA(isA<PathNotFoundException>()));
  });

  test('a later part of a RAR volume set is refused, naming the first (ARC-8)', () async {
    for (final (later, first) in [
      ('x.part2.rar', 'x.part1.rar'),
      ('y.part03.rar', 'y.part01.rar'),
      ('z.r00', 'z.rar'),
    ]) {
      final part = await (tmp / later).writeText('not really');
      await expectLater(
        part.unarchive(into: tmp / 'out'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', endsWith('unarchive $first'))),
      );
    }
  });

  test('a failed extraction leaves the destination as it was, made or not', () async {
    final archive = await src.archive(to: tmp / 'locked.zip', password: const Secret('sesame'));
    for (final flatten in [false, true]) {
      final made = tmp / 'made_$flatten';
      await expectLater(
        archive.unarchive(into: made, password: const Secret('nope'), flatten: flatten),
        throwsFormatException,
      );
      expect(await made.exists(), isFalse);
    }
    final kept = tmp / 'kept';
    await (kept / 'mine.txt').writeText('mine');
    await expectLater(archive.unarchive(into: kept, password: const Secret('nope')), throwsFormatException);
    expect(await tree(kept), ['mine.txt']);
    expect(await tmp.entries(only: '.*').toList(), isEmpty, reason: 'no staging folder left');
  });

  test('rar: RAR5, encrypted files and encrypted headers with passwords', () async {
    final stored = Path('test/fixtures/rar5_stored.rar');
    expect((await Archive.read(stored)).entries, isNotEmpty);
    await stored.unarchive(into: tmp / 'rar5');
    expect(await tree(tmp / 'rar5'), isNotEmpty);

    final crypted = Path('test/fixtures/crypted.rar');
    expect((await Archive.read(crypted)).entries.any((e) => e.isEncrypted), isTrue);
    await expectLater(crypted.unarchive(into: tmp / 'wrong', password: const Secret('wrong')), throwsA(anything));
    await crypted.unarchive(into: tmp / 'crypted', password: const Secret('unrar'));
    expect(await tree(tmp / 'crypted'), isNotEmpty);

    final headers = Path('test/fixtures/encrypted_headers.rar');
    await expectLater(Archive.read(headers), throwsA(anything), reason: 'even the listing needs the password');
    expect((await Archive.read(headers, password: const Secret('password'))).entries, isNotEmpty);
    await headers.unarchive(into: tmp / 'headers', password: const Secret('password'));
    expect(await tree(tmp / 'headers'), isNotEmpty);
    expect((await Archive.read('test/fixtures/unicode.rar')).entries.first.name, isNotEmpty);
  });

  test('a corrupt archive is a FormatException naming it', () async {
    await (tmp / 'bad.zip').writeBytes(List.filled(100, 7));
    await expectLater(
      Archive.read(tmp / 'bad.zip'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('bad.zip'))),
    );
  });

  test('an entry that escapes the destination is refused and writes nothing', () async {
    final into = tmp / 'slip' / 'into';
    await expectLater(Path('test/fixtures/zip_slip.zip').unarchive(into: into), throwsA(isA<FormatException>()));
    expect(await tmp.files(only: '**/escaped.txt').toList(), isEmpty);
    expect(await tmp.files(only: '**/also_escaped.txt').toList(), isEmpty);
    expect(await into.exists(), isFalse);
  });

  test('a link to a file is archived as that file, under its own name', () async {
    final data = await (tmp / 'data.txt').writeText('payload');
    await (tmp / 'link.txt').symlink(data);
    for (final ext in ['zip', 'tar.gz', '7z']) {
      final out = await (tmp / 'link.txt').archive(to: tmp / 'out.$ext');
      expect(await names(out), ['link.txt'], reason: '$ext keeps the file the link names');
    }
  }, testOn: '!windows');

  group('an archive from elsewhere is extracted safely', () {
    int mode(String path) => FileStat.statSync(path).mode & 0xfff;

    test('setuid, setgid and sticky are dropped unless unsafe', () async {
      final exe = await (src / 'suid.sh').writeText('#!/bin/sh\n');
      await exe.chmod('6755');
      expect(mode(exe) & 0xe00, isNot(0), reason: 'the fixture itself must carry the bits');
      expect(Process.runSync('zip', ['-q', tmp / 'suid.zip', 'suid.sh'], workingDirectory: src).exitCode, 0);
      for (final ext in ['.zip', '.tar', '.tar.gz']) {
        final archive = tmp / 'suid$ext';
        if (ext != '.zip') await src.archive(to: archive);
        await archive.unarchive(into: tmp / 'plain$ext');
        expect(mode(tmp / 'plain$ext' / 'suid.sh'), 0x1ed, reason: '$ext: 0755, nothing above it');
        await archive.unarchive(into: tmp / 'unsafe$ext', unsafe: true);
        expect(mode(tmp / 'unsafe$ext' / 'suid.sh') & 0xe00, isNot(0), reason: '$ext, unsafe');
      }
    }, testOn: '!windows');

    test('an archive that expands past the cap is refused before it writes, as reads are', () async {
      final bomb = await (tmp / 'bomb').mkdir();
      // Sparse: 2 GiB of zeros that take no disk, packed into about 40 KB.
      File(bomb / 'zeros.bin').openSync(mode: FileMode.write)
        ..truncateSync(2 << 30)
        ..closeSync();
      await bomb.archive(to: tmp / 'bomb.tar.zst', level: 1);
      await bomb.delete(recursive: true);
      await expectLater(
        (tmp / 'bomb.tar.zst').unarchive(into: tmp / 'out'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('unsafe: true'))),
      );
      expect(await (tmp / 'out').exists(), isFalse);
      final archive = await Archive.read(tmp / 'bomb.tar.zst');
      await expectLater(archive.entry('zeros.bin'), throwsA(isA<FormatException>()));
      await expectLater(
        archive.contents().toList(),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('unsafe: true'))),
      );
    });

    test('flatten keeps an extracted link instead of deleting it with its folder', () async {
      final links = tmp / 'flat_links';
      await (links / 'top' / 'real.txt').writeText('inside');
      await (links / 'top' / 'in.txt').symlink('real.txt');
      expect(Process.runSync('zip', ['-qry', tmp / 'flat.zip', 'top'], workingDirectory: links).exitCode, 0);
      await (tmp / 'flat.zip').unarchive(into: tmp / 'flat_out', flatten: true);
      expect(await (tmp / 'flat_out' / 'in.txt').isLink(), isTrue);
      expect(await (tmp / 'flat_out' / 'in.txt').readText(), 'inside');
      expect(await (tmp / 'flat_out' / 'top').exists(), isFalse);
    }, testOn: '!windows');

    test('a link that leads out is refused and left nowhere; one that stays in is a link', () async {
      final links = tmp / 'links';
      await (links / 'real.txt').writeText('inside');
      await (links / 'in.txt').symlink('real.txt');
      await (links / 'out').symlink('../../../../etc');
      expect(
        Process.runSync('zip', ['-qry', tmp / 'in.zip', 'real.txt', 'in.txt'], workingDirectory: links).exitCode,
        0,
      );
      expect(Process.runSync('zip', ['-qry', tmp / 'out.zip', 'out'], workingDirectory: links).exitCode, 0);
      expect(Process.runSync('tar', ['-cf', tmp / 'out.tar', 'out'], workingDirectory: links).exitCode, 0);
      await (tmp / 'in.zip').unarchive(into: tmp / 'x');
      expect(await (tmp / 'x' / 'in.txt').isLink(), isTrue);
      expect(await (tmp / 'x' / 'in.txt').readText(), 'inside');
      for (final archive in ['out.zip', 'out.tar']) {
        await expectLater((tmp / archive).unarchive(into: tmp / 'y$archive'), throwsA(isA<FormatException>()));
        expect(await (tmp / 'y$archive' / 'out').exists(), isFalse);
      }
    }, testOn: '!windows');

    test('a link whose target does not exist yet is still refused when it leads out', () async {
      final dangle = tmp / 'dangle';
      await (dangle / 'd').mkdir();
      await (dangle / 'd' / 'b').symlink('..');
      await (dangle / 'l').symlink('d/b/../pwned.txt');
      expect(Process.runSync('zip', ['-qry', tmp / 'dangle.zip', 'd', 'l'], workingDirectory: dangle).exitCode, 0);
      expect(Process.runSync('tar', ['-cf', tmp / 'dangle.tar', 'd', 'l'], workingDirectory: dangle).exitCode, 0);
      for (final archive in ['dangle.zip', 'dangle.tar']) {
        final dest = tmp / 'out$archive' / 'x';
        await expectLater((tmp / archive).unarchive(into: dest), throwsA(isA<FormatException>()), reason: archive);
        expect(await (dest / 'l').exists(), isFalse);
      }
    }, testOn: '!windows');

    test('a link already in the destination is neither written through nor walked through', () async {
      final outside = await (tmp / 'outside').mkdir();
      final dest = await (tmp / 'dest').mkdir();
      await (dest / 'l').symlink(outside / 'pwned.txt');
      await (dest / 'd').symlink(outside);
      final plain = tmp / 'plain';
      await (plain / 'l').writeText('replaces the link');
      await (plain / 'd' / 'x.txt').writeText('would land outside');
      expect(Process.runSync('zip', ['-qr', tmp / 'l.zip', 'l'], workingDirectory: plain).exitCode, 0);
      expect(Process.runSync('zip', ['-qr', tmp / 'd.zip', 'd'], workingDirectory: plain).exitCode, 0);

      await (tmp / 'l.zip').unarchive(into: dest);
      expect(await (dest / 'l').isLink(), isTrue, reason: 'skip leaves what is there');
      await (tmp / 'l.zip').unarchive(into: dest, conflict: Conflict.rename);
      expect(await (dest / 'l (1)').readText(), 'replaces the link');
      await (tmp / 'l.zip').unarchive(into: dest, conflict: Conflict.overwrite);
      expect(await (outside / 'pwned.txt').exists(), isFalse, reason: 'the bytes never went through the link');
      expect((await (dest / 'l').isLink(), await (dest / 'l').readText()), (false, 'replaces the link'));

      await (tmp / 'd.zip').unarchive(into: dest);
      await (tmp / 'd.zip').unarchive(into: dest, conflict: Conflict.rename);
      expect(await (outside / 'x.txt').exists(), isFalse, reason: 'a link to a folder is not merged into');
      expect(await (dest / 'd (1)' / 'x.txt').readText(), 'would land outside');
      await (tmp / 'd.zip').unarchive(into: dest, conflict: Conflict.overwrite);
      expect(await (outside / 'x.txt').exists(), isFalse);
      expect((await (dest / 'd').isLink(), await (dest / 'd' / 'x.txt').readText()), (false, 'would land outside'));
    }, testOn: '!windows');

    test('a zip time is local time, as every other tool reads and writes it', () async {
      final f = await (src / 'stamped.txt').writeText('stamped');
      final when = DateTime(2011, 7, 8, 9, 10, 12); // local; zip keeps even seconds
      File(f).setLastModifiedSync(when);
      expect(Process.runSync('zip', ['-q', tmp / 'sys.zip', 'stamped.txt'], workingDirectory: src).exitCode, 0);
      await (tmp / 'sys.zip').unarchive(into: tmp / 'mine');
      expect(await (tmp / 'mine' / 'stamped.txt').modified(), when);
      expect((await Archive.read(tmp / 'sys.zip')).entries.single.modified, when);
      await f.archive(to: tmp / 'mine.zip');
      await (tmp / 'theirs').mkdir();
      expect(Process.runSync('unzip', ['-q', tmp / 'mine.zip', '-d', tmp / 'theirs']).exitCode, 0);
      expect(await (tmp / 'theirs' / 'stamped.txt').modified(), when);
    }, testOn: '!windows');

    test('a read-only file keeps its time; a read-only folder in a tar keeps its mode', () async {
      final ro = await (src / 'ro.txt').writeText('read only');
      File(ro).setLastModifiedSync(DateTime.utc(2001, 2, 3, 4, 5, 6));
      await ro.chmod('444');
      await (src / 'rodir' / 'f.txt').writeText('hi');
      await (src / 'rodir').chmod('555');
      addTearDown(() async {
        for (final d in [src / 'rodir', tmp / 'ro' / 'rodir', tmp / 'rt' / 'rodir']) {
          if (await d.exists()) await d.chmod('755');
        }
      });
      await src.archive(to: tmp / 'ro.zip');
      await (tmp / 'ro.zip').unarchive(into: tmp / 'ro');
      expect((await (tmp / 'ro' / 'ro.txt').modified()).toUtc().year, 2001, reason: 'the time is set before the mode');
      await src.archive(to: tmp / 'ro.tar.gz');
      await (tmp / 'ro.tar.gz').unarchive(into: tmp / 'rt');
      expect(await (tmp / 'rt' / 'rodir' / 'f.txt').readText(), 'hi');
      expect(mode(tmp / 'rt' / 'rodir'), 0x16d);
    }, testOn: '!windows');
  });

  test('an archive written inside its own source does not contain itself, run after run', () async {
    for (final ext in ['.zip', '.7z', '.tar.gz']) {
      final dest = src / 'backup$ext';
      await src.archive(to: dest);
      await src.archive(to: dest, conflict: Conflict.overwrite); // a second run finds the first there
      final listed = await names(dest);
      expect(listed.where((n) => n.contains('backup')), isEmpty, reason: ext);
      expect(listed.where((n) => n.isEmpty), isEmpty, reason: '$ext: no nameless root entry');
      await dest.delete();
    }
  });

  test('an archive named bare, in the folder it archives, does not contain the last one', () async {
    await (tmp / 'self.dart').writeText('''
import 'package:dart_toolkit/archive.dart';
void main() async {
  for (final ext in ['zip', 'tar.gz', '7z']) {
    await Path('.').archive(to: 'self.\$ext');
    await Path('.').archive(to: 'self.\$ext', conflict: Conflict.overwrite);
  }
}
''');
    final r = await Process.run(Platform.resolvedExecutable, [
      '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
      tmp / 'self.dart',
    ], workingDirectory: src);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    for (final ext in ['zip', 'tar.gz', '7z']) {
      expect(await names(src / 'self.$ext'), isNot(contains('self.$ext')), reason: ext);
    }
  });

  group('writes are atomic (X-5, ARC-2)', () {
    test('a destination there is skipped by default, replaced only when asked, never cut short', () async {
      final zip = await src.archive(to: tmp / 'a.zip');
      final before = await zip.readBytes();
      await (src / 'more.txt').writeText('more');
      final again = src.archive(to: zip);
      expect(await again, zip);
      expect((await again.settled as Done).fresh, isFalse);
      expect(await zip.readBytes(), before, reason: 'a rerun leaves last run\'s archive');
      final reader = File(zip).openSync();
      await src.archive(to: zip, conflict: Conflict.overwrite);
      expect(reader.readSync(4), before.sublist(0, 4), reason: 'the old archive was replaced, not truncated');
      reader.closeSync();
      expect(await names(zip), contains('more.txt'));
      expect(await src.archive(to: zip, conflict: Conflict.rename), tmp / 'a (1).zip');
      await expectLater(src.archive(to: zip, conflict: Conflict.fail), throwsA(isA<PathExistsException>()));
    });

    test('a failed archive leaves the destination as it was, and no temporary file', () async {
      final zip = await src.archive(to: tmp / 'a.tar.bz2');
      final before = await zip.readBytes();
      await expectLater(src.archive(to: zip, level: 0, conflict: Conflict.overwrite), throwsFormatException);
      expect(await zip.readBytes(), before);
      expect(await here(), ['a.tar.bz2', 'src']);
    });

    test('a cancelled archive stops part way, leaves the old one, and the library still works (ARC-3)', () async {
      final big = await (tmp / 'big').mkdir();
      final rnd = Random(3);
      for (var i = 0; i < 4; i++) {
        await (big / 'f$i.bin').writeBytes(List.generate(16 << 20, (_) => rnd.nextInt(256)));
      }
      final old = await (tmp / 'big.tar.xz').writeText('the old one');
      final task = big.archive(to: old, level: 9, conflict: Conflict.overwrite);
      await task.statuses.firstWhere((s) => s is Running<Object?, Path> && s.received > 0);
      task.cancel('enough');
      expect(await task.settled, isA<Stopped<Object?, Path>>());
      expect(await old.readText(), 'the old one');
      expect(await here(), ['big', 'big.tar.xz', 'src']);
      expect(await src.archive(to: tmp / 'after.zip'), tmp / 'after.zip');
    });

    test('a cancelled extraction stops part way and leaves no staging folder (ARC-3, ARC-4)', () async {
      final zip = await (src / 'sub' / 'deep').archive(to: tmp / 'deep.tar.xz');
      for (final unsafe in [false, true]) {
        final task = zip.unarchive(into: tmp / 'out_$unsafe', unsafe: unsafe);
        task.cancel('enough');
        expect(await task.settled, isA<Stopped<Object?, Path>>());
        expect(await (tmp / 'out_$unsafe').exists(), isFalse);
      }
      expect(await here(), ['deep.tar.xz', 'src']);
      await zip.unarchive(into: tmp / 'out');
      expect(await tree(tmp / 'out'), ['random.bin']);
    });
  });

  group('progress', () {
    test('archive and unarchive report bytes, name their entries, and label the item', () async {
      final archive = src.archive(to: tmp / 'p.zip');
      final seen = <Running<Object?, Path>>[];
      archive.statuses.listen((s) => s is Running<Object?, Path> ? seen.add(s) : null);
      expect(await archive, tmp / 'p.zip');
      expect(archive.label, '${tmp.name}${Platform.pathSeparator}src');
      expect(seen.where((r) => r.unit == Unit.bytes && r.total != null), isNotEmpty);
      expect(seen.any((r) => r.step != null && r.step!.isNotEmpty), isTrue);
      final out = (tmp / 'p.zip').unarchive(into: tmp / 'out');
      final heard = <Running<Object?, Path>>[];
      out.statuses.listen((s) => s is Running<Object?, Path> ? heard.add(s) : null);
      await out;
      expect(heard.where((r) => r.total != null), isNotEmpty);
      expect(await digests(tmp / 'out'), await digests(src));
    });

    test('a zip byte total counts encrypted entries and only the ones extracted', () async {
      final bytes = tmp / 'bytes_src';
      await (bytes / 'docs' / 'a.txt').writeText('a' * 100);
      await (bytes / 'b.bin').writeText('b' * 900);
      const pw = Secret('pw');
      final zip = await bytes.archive(to: tmp / 'bytes.zip', password: pw);
      for (final (only, want) in [(null, 1000), ('docs/*', 100)]) {
        final task = zip.unarchive(into: tmp / 'bytes_$want', password: pw, only: only);
        final totals = <int?>{};
        task.statuses.listen((s) => s is Running<Object?, Path> && s.unit == Unit.bytes ? totals.add(s.total) : null);
        await task;
        expect(totals, contains(want), reason: 'only: $only');
      }
    });

    test('a stream unarchive starts without blocking the caller on a large tar', () async {
      final many = await (tmp / 'many').mkdir();
      for (var i = 0; i < 3000; i++) {
        File('$many/f$i.txt').writeAsStringSync('$i');
      }
      await many.archive(to: tmp / 'many.tar.gz');
      final odd = await (tmp / 'many.tar.gz').move(to: tmp / 'many.bin');
      final started = DateTime.now();
      final task = odd.unarchive(into: tmp / 'many_out');
      expect(DateTime.now().difference(started).inMilliseconds, lessThan(5));
      await task;
      expect(await (tmp / 'many_out').files().length, 3000);
    });
  });

  group('Archive.read', () {
    for (final ext in ['.zip', '.7z', '.tar', '.tar.xz']) {
      test('$ext: contents gives each file once, with the bytes entry reads, no folders', () async {
        final archive = await Archive.read(await src.archive(to: tmp / 'c$ext'));
        final files = {
          for (final e in archive.entries)
            if (!e.isDir) e.name: Hash.sha256.bytes(await archive.entry(e.name)),
        };
        final heard = {await for (final (:entry, :bytes) in archive.contents()) entry.name: Hash.sha256.bytes(bytes)};
        expect(heard, files);
        final note = (await archive.contents().toList()).firstWhere((f) => f.entry.name == 'note.txt');
        expect((note.entry.size, note.entry.isDir), (note.bytes.length, false));
      });
    }

    test('a missing entry is a MissingException naming it (ARC-7)', () async {
      for (final ext in ['.zip', '.7z', '.tar.zst']) {
        final archive = await Archive.read(await src.archive(to: tmp / 'a$ext'));
        expect(utf8.decode(await archive.entry('sub/text.txt')), await (src / 'sub' / 'text.txt').readText());
        await expectLater(
          archive.entry('nope.txt'),
          throwsA(isA<MissingException>().having((e) => '$e', 'text', 'Missing entry nope.txt in ${tmp / 'a$ext'}')),
          reason: ext,
        );
      }
      await expectLater(Archive.read(tmp / 'none.zip'), throwsA(isA<PathNotFoundException>()));
    });

    test('only picks as unarchive(only:) does', () async {
      final archive = await Archive.read(await src.archive(to: tmp / 'only.7z'));
      final listed = [await for (final f in archive.contents(only: '**/*.txt')) f.entry.name]..sort();
      expect(listed, ['note.txt', 'sub/text.txt', 'ünïcode 名前.txt']..sort());
      await (tmp / 'only.7z').unarchive(into: tmp / 'o', only: '**/*.txt');
      expect(await tree(tmp / 'o'), listed);
    });

    test('a password opens it; a wrong one is a PasswordException', () async {
      for (final ext in ['.zip', '.7z']) {
        final path = await src.archive(to: tmp / 'p$ext', password: const Secret('sesame'));
        final archive = await Archive.read(path, password: const Secret('sesame'));
        final files = await archive.contents().toList();
        expect(files.map((f) => f.entry.name), contains('sub/deep/random.bin'), reason: ext);
        expect(files.every((f) => f.entry.isEncrypted), isTrue, reason: ext);
      }
      final wrong = await Archive.read(tmp / 'p.zip', password: const Secret('nope'));
      await expectLater(wrong.contents().toList(), throwsA(isA<PasswordException>()));
    });

    test('rar reads in one pass too', () async {
      final crypted = await Archive.read('test/fixtures/crypted.rar', password: const Secret('unrar'));
      final files = await crypted.contents().toList();
      expect(files, isNotEmpty);
      for (final (:entry, :bytes) in files) {
        expect(bytes, await crypted.entry(entry.name));
      }
    });

    test('stopping early ends the pass, and the archive reads again', () async {
      final archive = await Archive.read(await src.archive(to: tmp / 'stop.tar.zst'));
      await for (final _ in archive.contents()) {
        break;
      }
      final sub = archive.contents().listen(null);
      await sub.cancel();
      expect((await archive.contents().toList()).length, 4);
    });

    test('a paused listener holds the pass back, and resuming delivers the rest', () async {
      final archive = await Archive.read(await src.archive(to: tmp / 'paused.zip'));
      final heard = <String>[];
      final done = Completer<void>();
      late final StreamSubscription<({ArchiveEntry entry, Uint8List bytes})> sub;
      sub = archive.contents().listen((f) {
        heard.add(f.entry.name);
        if (heard.length == 1) {
          sub.pause();
          Timer(const Duration(milliseconds: 100), sub.resume);
        }
      }, onDone: done.complete);
      await done.future;
      expect(heard.length, 4);
    });

    test('a cancelled scope stops the pass', () async {
      final archive = await Archive.read(await src.archive(to: tmp / 'cancel.zip'));
      final token = CancelToken();
      await expectLater(
        Cancel.scope(() async {
          await for (final _ in archive.contents()) {
            token.cancel();
            await Future<void>.delayed(Duration.zero);
          }
        }, token: token),
        throwsA(isA<CancelledException>()),
      );
    });
  });

  group('archive(only:) and original:', () {
    for (final ext in ['.zip', '.7z', '.tar.gz']) {
      test('$ext: only is a glob, as files(only:) reads it; nothing matched is an empty archive', () async {
        await src.archive(to: tmp / 'only$ext', only: '**/*.txt');
        expect(await names(tmp / 'only$ext'), ['note.txt', 'sub/text.txt', 'ünïcode 名前.txt']..sort());
        await src.archive(to: tmp / 'none$ext', only: '*.nothing');
        expect(await names(tmp / 'none$ext'), isEmpty);
      });
    }

    test('original: delete takes only what went in; trash moves it; inside the source is refused', () async {
      await src.archive(to: tmp / 'moved.zip', only: '**/*.txt', original: Original.delete);
      expect(await tree(src), ['sub/deep/random.bin']);
      expect(await (src / 'emptydir').exists(), isTrue);
      final gone = await (tmp / 'gone' / 'f.txt').writeText('f');
      await gone.parent.archive(to: tmp / 'gone.zip', original: Original.delete);
      expect(await gone.parent.exists(), isFalse);
      expect(() => src.archive(to: src / 'inside.zip', original: Original.delete), throwsArgumentError);
      final zip = await src.archive(to: tmp / 'x.zip');
      await zip.unarchive(into: tmp / 'x', original: Original.delete);
      expect(await zip.exists(), isFalse);
    });
  });

  test('a level outside the format\'s range is refused; zip level 0 stores; zstd goes negative', () async {
    final note = src / 'note.txt';
    await expectLater(note.archive(to: tmp / 'bad.bz2', level: 0), throwsA(isA<FormatException>()));
    expect(() => note.archive(to: tmp / 'bad.gz', level: -5), throwsArgumentError);
    await expectLater(note.archive(to: tmp / 'bad.gz', level: 10), throwsA(isA<FormatException>()));
    await note.archive(to: tmp / 'fast.zst', level: -1);
    await (tmp / 'fast.zst').unarchive(into: tmp / 'fast');
    expect(await (tmp / 'fast' / 'fast').readText(), await note.readText());
    final stored = await src.archive(to: tmp / 'stored.zip', level: 0);
    final entry = (await Archive.read(stored)).entries.firstWhere((e) => e.name == 'note.txt');
    expect(entry.compressedSize, entry.size);
  });

  test('every container keeps the executable bit, a link as a link (a 7z too), a folder its 0700', () async {
    final script = await (src / 'run.sh').writeText('#!/bin/sh\necho ok\n');
    await script.chmod('755');
    await (src / 'note_link.txt').symlink('note.txt');
    await (src / 'private_dir' / 'secret.txt').writeText('secret');
    await (src / 'private_dir').chmod('700');
    for (final ext in ['.zip', '.7z', '.tar', '.tar.gz']) {
      final out = tmp / 'out$ext';
      await (await src.archive(to: tmp / 'a$ext')).unarchive(into: out);
      expect(FileStat.statSync(out / 'run.sh').mode & 0x1ed, 0x1ed, reason: ext);
      expect(FileStat.statSync(out / 'private_dir').mode & 0x1ff, 0x1c0, reason: ext);
      expect(Link(out / 'note_link.txt').targetSync(), 'note.txt', reason: ext);
    }
    final contents = [await for (final f in (await Archive.read(tmp / 'a.7z')).contents()) f.entry.name];
    expect(contents, isNot(contains('note_link.txt')), reason: 'contents leaves links out, as for zip');
  }, testOn: '!windows');

  test(r'only: takes a \ before a character to mean it', () async {
    await (src / 'a*b.txt').writeText('star');
    await (src / 'axb.txt').writeText('x');
    final zip = await src.archive(to: tmp / 'esc.zip');
    await zip.unarchive(into: tmp / 'esc', only: r'a\*b.txt');
    expect([await for (final f in (tmp / 'esc').files()) f.name], ['a*b.txt']);
    await (src / '[a' / 'b]').writeText('set');
    await (await src.archive(to: tmp / 'set.zip')).unarchive(into: tmp / 'set', only: '[a/b]');
    expect(
      [await for (final f in (tmp / 'set').files(only: '**')) f.relativeTo(tmp / 'set')],
      ['[a/b]'],
      reason: 'a set never spans a /, in Rust as in Dart',
    );
  }, testOn: '!windows');

  test('unarchive into a mount point that is there moves in by renames on its own volume', () async {
    final mount = tmp / 'mnt';
    await mount.mkdir();
    final image = tmp / 'v.dmg';
    if ((await Process.run('hdiutil', [
              'create',
              '-quiet',
              '-size',
              '20m',
              '-fs',
              'APFS',
              '-volname',
              'TK',
              image,
            ])).exitCode !=
            0 ||
        (await Process.run('hdiutil', ['attach', '-quiet', '-nobrowse', '-mountpoint', mount, image])).exitCode != 0) {
      markTestSkipped('hdiutil cannot make a volume here');
      return;
    }
    addTearDown(() => Process.run('hdiutil', ['detach', '-force', '-quiet', mount]));
    final zip = await src.archive(to: tmp / 'm.zip');
    await zip.unarchive(into: mount);
    expect(await (mount / 'note.txt').readText(), startsWith('Archive Note'));
    expect([await for (final e in tmp.entries()) e.name], isNot(contains(startsWith('.mnt'))));
  }, testOn: 'mac-os');

  test('a stream large enough for every core round-trips through zstd and xz', () async {
    final big = tmp / 'big.log';
    final mib = utf8.encode(
      [for (var i = 0; i < 1 << 14; i++) '${i * 2654435761 % 100000}'.padLeft(63, '-')].join('\n'),
    );
    final sink = File(big).openWrite();
    for (var i = 0; i < 33; i++) {
      sink.add(mib);
    }
    await sink.close();
    final want = await Hash.xxh3.file(big);
    for (final (ext, level) in [('.zst', null), ('.xz', 0)]) {
      await big.archive(to: tmp / 'big.log$ext', level: level);
      await (tmp / 'big.log$ext').unarchive(into: tmp / 'back$ext');
      expect(await Hash.xxh3.file(tmp / 'back$ext' / 'big.log'), want, reason: ext);
    }
  });

  test('only: takes braces and character classes, a leading ] and a literal brace', () async {
    final arc = await src.archive(to: tmp / 'glob.zip');
    await arc.unarchive(into: tmp / 'braces', only: '{note.txt,sub/text.txt}');
    expect(await tree(tmp / 'braces'), ['note.txt', 'sub/text.txt']);
    await arc.unarchive(into: tmp / 'classes', only: '[n]ote.txt');
    expect(await tree(tmp / 'classes'), ['note.txt']);
    final odd = tmp / 'names';
    for (final n in [']', 'a', 'b{1}.txt', 'b1.txt']) {
      await (odd / n).writeText(n);
    }
    final named = await odd.archive(to: tmp / 'names.zip');
    Future<List<String>> only(String glob) async {
      final out = tmp / 'only_${glob.hashCode}';
      await named.unarchive(into: out, only: glob);
      return tree(out);
    }

    expect(await only('[]]'), [']']);
    expect(await only('[!]]'), ['a']);
    expect(await only('b{1}.txt'), ['b{1}.txt']);
  });

  test('a FIFO in the tree is skipped, not waited on', () async {
    expect(Process.runSync('mkfifo', [src / 'pipe']).exitCode, 0);
    for (final ext in ['zip', '7z', 'tar']) {
      await src.archive(to: tmp / 'p.$ext').timeout(const Duration(seconds: 10));
      expect(await names(tmp / 'p.$ext'), isNot(contains('pipe')), reason: ext);
    }
  }, testOn: '!windows');

  group('conflict settles each file already there, flattened or not (FS-5, FS-12)', () {
    late Path zip;
    setUp(() async => zip = await src.archive(to: tmp / 'c.zip'));

    /// A destination holding a file of its own at `note.txt` and at `sub/text.txt`.
    Future<Path> occupied(String name) async {
      final out = tmp / name;
      await (out / 'note.txt').writeText('mine');
      await (out / 'sub' / 'text.txt').writeText('mine too');
      return out;
    }

    test('fail refuses before writing anything', () async {
      final out = await occupied('fail');
      await expectLater(zip.unarchive(into: out, conflict: Conflict.fail), throwsA(isA<PathExistsException>()));
      expect(await tree(out), ['note.txt', 'sub/text.txt']);
      expect(await tmp.entries(only: '.*').toList(), isEmpty, reason: 'no staging folder left');
    });

    test('skip, the default, keeps the old files and adds the rest; a rerun does nothing', () async {
      final out = await occupied('skip');
      final first = zip.unarchive(into: out);
      await first;
      expect((await first.settled as Done).fresh, isTrue);
      expect((await (out / 'note.txt').readText(), await (out / 'sub' / 'text.txt').readText()), ('mine', 'mine too'));
      expect(await (out / 'sub' / 'deep' / 'random.bin').exists(), isTrue);
      expect(await (out / 'note (1).txt').exists(), isFalse);
      expect(
        (await zip.unarchive(into: out).settled as Done).fresh,
        isFalse,
        reason: 'a rerun neither doubles nor destroys',
      );
      expect(await (out / 'note (1).txt').exists(), isFalse);
    });

    test('rename puts the incoming file beside the old one', () async {
      final out = await occupied('rename');
      await zip.unarchive(into: out, conflict: Conflict.rename);
      expect(await (out / 'note.txt').readText(), 'mine');
      expect(await (out / 'note (1).txt').readText(), await (src / 'note.txt').readText());
      expect(await (out / 'sub' / 'text (1).txt').readText(), await (src / 'sub' / 'text.txt').readText());
    });

    test('overwrite replaces', () async {
      final out = await occupied('over');
      await zip.unarchive(into: out, conflict: Conflict.overwrite);
      expect(await digests(out), await digests(src));
    });

    test('a single stream onto an existing file follows the policy', () async {
      final gz = await (src / 'note.txt').archive(to: tmp / 'n.gz');
      final out = tmp / 'nout';
      await (out / 'n').writeText('mine');
      await expectLater(gz.unarchive(into: out, conflict: Conflict.fail), throwsA(isA<PathExistsException>()));
      await gz.unarchive(into: out);
      expect(await (out / 'n').readText(), 'mine');
      await gz.unarchive(into: out, conflict: Conflict.rename);
      expect(await (out / 'n (1)').readText(), await (src / 'note.txt').readText());
    });

    test('flattened: two of one name are settled, and a folder of a file\'s name takes neither', () async {
      final clash = tmp / 'clash';
      await (clash / 'a' / 'photo.jpg').writeText('photo 1');
      await (clash / 'b' / 'photo.jpg').writeText('photo 2');
      await (clash / 'c' / 'docs').writeText('the file');
      final flat = await clash.archive(to: tmp / 'clash.zip');
      final renamed = tmp / 'renamed';
      await (renamed / 'docs' / 'keep.txt').writeText('mine');
      await flat.unarchive(into: renamed, flatten: true, conflict: Conflict.rename);
      expect(
        {await (renamed / 'photo.jpg').readText(), await (renamed / 'photo (1).jpg').readText()},
        {'photo 1', 'photo 2'},
      );
      expect(
        (await (renamed / 'docs' / 'keep.txt').readText(), await (renamed / 'docs (1)').readText()),
        ('mine', 'the file'),
      );
      final skipped = tmp / 'skipped';
      await (skipped / 'photo.jpg').writeText('existing');
      await flat.unarchive(into: skipped, flatten: true);
      expect(
        (await (skipped / 'photo.jpg').readText(), await (skipped / 'photo (1).jpg').exists()),
        ('existing', false),
      );
      await expectLater(
        flat.unarchive(into: tmp / 'failed', flatten: true, conflict: Conflict.fail),
        throwsA(isA<PathExistsException>()),
        reason: 'two files want photo.jpg',
      );
    });
  });

  group('a zip from any system keeps its names', () {
    /// A one-entry stored zip whose name is [name] in raw bytes, the UTF-8 flag off.
    Uint8List zipNamed(List<int> name, List<int> body) {
      final crc = ByteData.sublistView(Hash.crc32.bytes(body).bytes).getUint32(0);
      final local = ByteData(30)
        ..setUint32(0, 0x04034b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint32(14, crc, Endian.little)
        ..setUint32(18, body.length, Endian.little)
        ..setUint32(22, body.length, Endian.little)
        ..setUint16(26, name.length, Endian.little);
      final central = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 20, Endian.little)
        ..setUint32(16, crc, Endian.little)
        ..setUint32(20, body.length, Endian.little)
        ..setUint32(24, body.length, Endian.little)
        ..setUint16(28, name.length, Endian.little);
      final end = ByteData(22)
        ..setUint32(0, 0x06054b50, Endian.little)
        ..setUint16(8, 1, Endian.little)
        ..setUint16(10, 1, Endian.little)
        ..setUint32(12, 46 + name.length, Endian.little)
        ..setUint32(16, 30 + name.length + body.length, Endian.little);
      return Uint8List.fromList([
        ...local.buffer.asUint8List(),
        ...name,
        ...body,
        ...central.buffer.asUint8List(),
        ...name,
        ...end.buffer.asUint8List(),
      ]);
    }

    test('a UTF-8 name without the flag lists, extracts and reads back as written', () async {
      final zip = await (tmp / 'a.zip').writeBytes(zipNamed(utf8.encode('ảnh/写真.txt'), utf8.encode('hi')));
      final archive = await Archive.read(zip);
      expect(archive.entries.map((e) => e.name), ['ảnh/写真.txt']);
      await zip.unarchive(into: tmp / 'out');
      expect(await (tmp / 'out' / 'ảnh' / '写真.txt').readText(), 'hi');
      expect(utf8.decode(await archive.entry('ảnh/写真.txt')), 'hi');
    });

    test('a name that is not UTF-8 still reads as CP437', () async {
      final zip = await (tmp / 'b.zip').writeBytes(zipNamed([0x82, 0x74, 0x2E, 0x74], utf8.encode('hi')));
      expect((await Archive.read(zip)).entries.map((e) => e.name), ['ét.t']);
    });
  });
}

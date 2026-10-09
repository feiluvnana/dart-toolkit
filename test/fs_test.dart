import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_toolkit/path.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart' hide Retry;

import 'support.dart';

void main() {
  late Path dir;
  setUp(() => dir = tempDir('tk_fs_'));

  int mode(String path) => FileStat.statSync(path).mode & 0xfff;
  List<String> names(Iterable<Path> paths) => [for (final f in paths) f.name];
  List<String> rel(Iterable<Path> paths, Path root) =>
      [for (final f in paths) f.relativeTo(root).replaceAll(r'\', '/')]..sort();

  group('typed text', () {
    test('a Glob is checked when made, matches paths, and goes where a glob does', () async {
      final songs = '**/*.{mp3,flac}'.glob;
      expect(
        [songs.matches('a/b/c.mp3'), songs.matches('c.flac'), songs.matches(r'a\\x.mp3'), songs.matches('c.wav')],
        [true, true, true, false],
      );
      expect(() => Glob(''), throwsFormatException);
      expect(() => '*.{mp3,flac'.glob, throwsFormatException);
      expect(() => '[ab'.glob, throwsFormatException);
      expect(Glob('*.[ch]'), '*.[ch]', reason: 'a Glob is the text it was made from');
      final dir = tempDir();
      await (dir / 'a.mp3').writeText('');
      await (dir / 'b.txt').writeText('');
      expect([await for (final f in dir.files(only: '*.mp3'.glob)) f.name], ['a.mp3']);
    });

    test('a Mode is checked when made; chmod takes it or plain text', () {
      expect(('755'.mode.bits, Mode('u+x').isSymbolic), (0x1ed, true));
      expect(() => '8'.mode, throwsFormatException);
    });
  });

  group('parts', () {
    test('/ joins and normalizes; name, stem, ext, parent, segments', () {
      const root = Path('test_dir');
      expect(root / 'sub' / 'file.txt', p.join('test_dir', 'sub', 'file.txt'));
      expect('base'.path / 'child', p.join('base', 'child'));
      expect(dir / 'a' / '..' / 'b', dir / 'b');
      final track = Path('folder/subfolder/track.part.mp3');
      expect((track.name, track.stem, track.ext), ('track.part.mp3', 'track.part', 'mp3'));
      expect(track.parent, p.dirname(track));
      expect(track.segments, ['folder', 'subfolder', 'track.part.mp3']);
      expect((Path('folder/readme').stem, Path('folder/readme').ext), ('readme', ''));
    });

    test('absolute, relativeTo, withExt, normalized', () {
      final f = dir / 'a' / 'song.mp3';
      expect(f.isAbsolute, isTrue);
      expect(Path('x/y').isAbsolute, isFalse);
      expect(Path('x/y').absolute, Path.cwd / 'x' / 'y');
      expect(f.relativeTo(dir), p.join('a', 'song.mp3'));
      expect(f.withExt('flac').name, 'song.flac');
      expect(f.withExt('.flac').name, 'song.flac');
      expect(f.withExt('').name, 'song');
      expect(Path('a/b/../b/c').normalized, Path('a/b/c').normalized);
      expect(<Path, int>{Path('a/b/c').normalized: 1}[Path('a/./b//c').normalized], 1);
    });

    test('sanitized and filename', () {
      expect(Path(r'folder/invalid:*?"<>| name.mp3').sanitized, isNot(contains('*')));
      expect('AIR / Farewell song'.filename, 'AIR _ Farewell song');
      expect('  spaced   out  '.filename, 'spaced out');
      expect(''.filename, '_');
      expect('nul.txt'.filename, '_nul.txt');
      expect('report. '.filename, 'report');
      expect('..'.filename, '__');
      expect('a\x00b\x1fc'.filename, 'abc');
      expect('/x/foo:'.path.sanitized, '/x/foo_');
      final fn = '${'a' * 300}.txt'.filename;
      expect((utf8.encode(fn).length <= 255, fn.endsWith('.txt')), (true, true));
      final target = 'Key BOX'.path / 'DISC01' / '${'AIR / Farewell'.filename}.mp3';
      expect(target.segments, hasLength(3));
    });

    test('places: here is the test file, home refuses without HOME, tempDir cleans up', () async {
      expect(Path.here, Path.cwd / 'test' / 'fs_test.dart');
      late Path seen;
      expect(
        await Path.tempDir((d) async {
          seen = d;
          await (d / 'a' / 'b.txt').writeText('x');
          return 42;
        }),
        42,
      );
      expect(await seen.exists(), isFalse);
    });
  });

  group('questions', () {
    test('type, exists, isDir and isFile follow links; type does not', () async {
      final f = await (dir / 'f.txt').writeText('x');
      final d = await (dir / 'd').mkdir();
      final lf = await (dir / 'lf').symlink(f);
      final ld = await (dir / 'ld').symlink(d);
      expect([await f.isFile(), await d.isFile(), await lf.isFile(), await ld.isFile()], [true, false, true, false]);
      expect([await f.isDir(), await d.isDir(), await lf.isDir(), await ld.isDir()], [false, true, false, true]);
      expect([await ld.type(), await f.type(), await d.type()], [PathType.link, PathType.file, PathType.dir]);
      expect([await ld.isLink(), await d.isLink()], [true, false]);
      final dangling = await (dir / 'dangling').symlink(dir / 'none');
      expect([await dangling.exists(), await dangling.isFile(), await (dir / 'none').exists()], [true, false, false]);
    }, testOn: '!windows');

    test('size and modified of a path that is not there throw, where olderThan says true', () async {
      final gone = dir / 'gone';
      await expectLater(gone.size(), throwsA(isA<PathNotFoundException>()));
      await expectLater(gone.modified(), throwsA(isA<PathNotFoundException>()));
      expect(await gone.olderThan(1.h), isTrue);
      final cache = await (dir / 'cache.json').writeText('{}');
      expect(await cache.olderThan(1.h), isFalse);
      await cache.touch(at: DateTime.now().subtract(2.h));
      expect(await cache.olderThan(1.h), isTrue);
    });

    test('size of a folder adds up every file below it, links not followed; a link is its target', () async {
      for (var i = 0; i < 50; i++) {
        await (dir / 'd${i % 5}' / 'f$i').writeBytes(List.filled(i, 0));
      }
      await (dir / 'link').symlink(dir / 'd0');
      expect(await dir.size(), 1225);
      await (dir / 'one.bin').writeBytes(List.filled(1234, 1));
      await (dir / 'l.bin').symlink(dir / 'one.bin');
      expect(await (dir / 'l.bin').size(), 1234);
    }, testOn: '!windows');

    test('free is the volume\'s, and agrees with df (FS-35)', () async {
      final free = await dir.free();
      expect(free, greaterThan(0));
      expect(await (await (dir / 'f').writeText('x')).free(), closeTo(free, free / 50 + (1 << 30)));
      final df = Process.runSync('df', ['-k', dir]);
      final available = int.parse('${df.stdout}'.trim().split('\n').last.split(RegExp(r'\s+'))[3]) * 1024;
      expect((free - available).abs(), lessThan(available ~/ 50 + (1 << 30)));
      await expectLater((dir / 'none').free(), throwsA(isA<PathNotFoundException>()));
    }, testOn: 'mac-os || linux');
  });

  group('reading and writing', () {
    test('writes answer the path, make folders, and read back', () async {
      final f = dir / 'deep' / 'a.txt';
      expect(await f.writeText('x'), f);
      expect(await f.readText(), 'x');
      expect(await f.writeBytes([1, 2]), f);
      expect(await f.readBytes(), [1, 2]);
      expect(await f.writeLines(['a', 'b']), f);
      expect(await f.readLines(), ['a', 'b']);
      expect(await f.appendText('c\n'), f);
      expect(await f.appendBytes(utf8.encode('d\n')), f);
      expect(await f.append(Stream.value(utf8.encode('e\n'))), f);
      expect(await f.readText(), 'a\nb\nc\nd\ne\n');
      expect(await f.replaceText('c', 'z'), f);
      expect(await f.readText(), 'a\nb\nz\nd\ne\n');
      expect(await (dir / 'new' / 'more.txt').appendText('made'), dir / 'new' / 'more.txt');
    });

    test('write is atomic: a failed source keeps the old file and leaves no temp (FS-23)', () async {
      final src = await (dir / 'src.bin').writeBytes(List.generate(300000, (i) => i % 251));
      final copy = await (dir / 'sub' / 'copy.bin').write(src.chunks());
      expect(await copy.readBytes(), await src.readBytes());
      await copy.writeText('kept');
      Stream<List<int>> broken() async* {
        yield [1, 2, 3];
        throw StateError('source failed');
      }

      await expectLater(copy.write(broken()), throwsStateError);
      expect(await copy.readText(), 'kept');
      expect(names(await copy.parent.entries().toList()), ['copy.bin']);
    });

    test('readBytes and chunks take a range; past the end is empty, a bad one an ArgumentError (FS-8)', () async {
      final f = await (dir / 'sample.bin').writeBytes(List.generate(50, (i) => i));
      expect(await f.readBytes(start: 2, end: 5), [2, 3, 4]);
      expect(await f.readBytes(start: 48), [48, 49]);
      expect(await f.readBytes(end: 3), [0, 1, 2]);
      expect(await f.readBytes(start: 100, end: 200), isEmpty);
      expect(await f.readBytes(start: 45, end: 200), [45, 46, 47, 48, 49]);
      await expectLater(f.readBytes(start: -1), throwsArgumentError);
      await expectLater(f.readBytes(start: 5, end: 2), throwsArgumentError);
      expect(await f.chunks(start: 10, end: 14).expand((c) => c).toList(), [10, 11, 12, 13]);
      expect(() => f.chunks(start: -1), throwsArgumentError);
    });

    test('lines decode across reads and end lines at \\r\\n and \\r', () async {
      final first = 'a' * ((64 << 10) - 1);
      final f = await (dir / 'big.txt').writeBytes([
        ...utf8.encode(first), ...utf8.encode('é\r\n'), //
        ...List.filled((64 << 10) - 4, 0x62), 0x0d, 0x0a, ...utf8.encode('c\rd'),
      ]);
      expect(await f.lines().toList(), ['$firsté', 'b' * ((64 << 10) - 4), 'c', 'd']);
      await expectLater((dir / 'none.txt').lines().toList(), throwsA(isA<PathNotFoundException>()));
    });

    test('a write replaces the file whole, keeping its mode, through a link, never a device', () async {
      final f = await (dir / 'conf.ini').writeText('old');
      await f.chmod('600');
      final reader = File(f).openSync();
      await f.writeText('new');
      expect(String.fromCharCodes(reader.readSync(10)), 'old', reason: 'a reader keeps the old file');
      reader.closeSync();
      expect((await f.readText(), mode(f)), ('new', 0x180));
      final link = await (dir / 'link.txt').symlink(f);
      await link.writeText('through');
      expect((await link.type(), await f.readText()), (PathType.link, 'through'));
      final ro = await (dir / 'ro.txt').writeText('keep');
      await ro.chmod('444');
      await expectLater(ro.writeText('nope'), throwsA(isA<FileSystemException>()));
      expect(await ro.readText(), 'keep');
      expect(await Path('/dev/null').writeText('x'), '/dev/null');
      expect(names(await dir.entries().toList())..sort(), ['conf.ini', 'link.txt', 'ro.txt']);
    }, testOn: '!windows');

    test('a write that fails after its temp file opened leaves the old file and no temp', () async {
      final f = await (dir / 'secret').writeText('old');
      await expectLater(f.writeBytes(_Faulty()), throwsStateError);
      expect(await f.readText(), 'old');
      expect(names(await dir.entries().toList()), ['secret']);
    });

    test('temp names are random, so writers in two isolates do not share one', () async {
      final f = dir / 'shared.txt';
      await Future.wait([
        for (var i = 0; i < 4; i++)
          Isolate.run(() async {
            for (var j = 0; j < 20; j++) {
              await f.writeText('$i' * 100000);
            }
          }),
      ]);
      expect(RegExp(r'^(\d)\1{99999}$').hasMatch(await f.readText()), isTrue);
      expect(names(await dir.entries().toList()), ['shared.txt']);
    });

    test('touch makes a file, sets its time, and a folder\'s too (FS-19)', () async {
      final f = dir / 't.txt';
      expect(await f.touch(at: DateTime(2020, 1, 2)), f);
      expect(File(f).statSync().modified, DateTime(2020, 1, 2));
      await f.touch(at: DateTime(2021, 3, 4));
      expect(File(f).statSync().modified, DateTime(2021, 3, 4));
      final d = await (dir / 'd').mkdir();
      await d.touch(at: DateTime(2019, 5, 6));
      expect(Directory(d).statSync().modified, DateTime(2019, 5, 6));
    }, testOn: '!windows');

    test('chmod takes octal and symbolic modes; a missing path is a PathNotFoundException (FS-28)', () async {
      final f = await (dir / 'run.sh').writeText('#!/bin/sh\n');
      expect(await f.chmod('640'), f);
      expect(mode(f), 0x1a0);
      await f.chmod('+x');
      expect(mode(f), 0x1e9);
      await f.chmod('go-rwx,u=rw');
      expect(mode(f), 0x180);
      await f.chmod('a+r,u+s');
      expect(mode(f), 0x9a4);
      final d = await (dir / 'd').mkdir();
      await d.chmod('a-x');
      await d.chmod('u+X');
      expect(mode(d) & 0x1c0, 0x1c0);
      await expectLater(f.chmod('rwx'), throwsFormatException);
      expect(await f.chmod('640'.mode), f, reason: 'a Mode is a String');
      expect(() => 'rwx'.mode, throwsFormatException);
      expect(() => Mode('999'), throwsFormatException);
      expect(() => Mode(''), throwsFormatException);
      expect(() => Mode('u+x,'), throwsFormatException);
      expect(('6755'.mode.bits, '6755'.mode.isSymbolic), (0xded, false));
      expect(('go-w'.mode.bits, Mode('go-w').isSymbolic, '${Mode('a=r')}'), (null, true, 'a=r'));
      await expectLater((dir / 'none').chmod('644'), throwsA(isA<PathNotFoundException>()));
      await expectLater((dir / 'none').chmod('+x'), throwsA(isA<PathNotFoundException>()));
    }, testOn: '!windows');

    test('chmod without who leaves the umask bits alone, as chmod(1) does', () async {
      final umask = int.parse('${Process.runSync('/bin/sh', ['-c', 'umask']).stdout}'.trim(), radix: 8);
      final f = await (dir / 'f').writeText('');
      await f.chmod('444');
      await f.chmod('+w');
      expect(mode(f), 0x124 | (0x92 & ~umask));
      await f.chmod('a+w');
      expect(mode(f), 0x1b6);
    }, testOn: '!windows');
  });

  group('listings', () {
    setUp(() async {
      for (final f in [
        'lib/a.dart',
        'lib/b.md',
        'lib/c.txt',
        'lib/src/d.dart',
        'lib/src/deep/e.dart',
        'test/x1.dart',
        'test/y2.dart',
        'doc/z.md',
        'top.dart',
      ]) {
        await (dir / f).writeText('x');
      }
    });

    Future<List<String>> files(String? only) async => rel(await dir.files(only: only).toList(), dir);

    test('without only, this folder\'s own; ** is recursive; a glob goes no deeper than its segments', () async {
      expect(await files(null), ['top.dart']);
      expect(rel(await dir.dirs().toList(), dir), ['doc', 'lib', 'test']);
      expect(rel(await dir.entries().toList(), dir), ['doc', 'lib', 'test', 'top.dart']);
      expect(await files('**/*.dart'), [
        'lib/a.dart',
        'lib/src/d.dart',
        'lib/src/deep/e.dart',
        'test/x1.dart',
        'test/y2.dart',
        'top.dart',
      ]);
      expect(await files('lib/*.dart'), ['lib/a.dart']);
      expect(await files('lib/**/*.dart'), ['lib/a.dart', 'lib/src/d.dart', 'lib/src/deep/e.dart']);
      expect(await files('*.dart'), ['top.dart']);
      expect(await files('lib/src/deep/e.dart'), ['lib/src/deep/e.dart']);
      expect(await files('nope/**/*.dart'), isEmpty, reason: 'a folder the glob names that is not there');
      expect(rel(await dir.dirs(only: '**').toList(), dir), ['doc', 'lib', 'lib/src', 'lib/src/deep', 'test']);
    });

    test('braces, sets, and a lone [', () async {
      expect(await files('lib/**/*.{dart,md}'), ['lib/a.dart', 'lib/b.md', 'lib/src/d.dart', 'lib/src/deep/e.dart']);
      expect(await files('{lib,doc}/*.md'), ['doc/z.md', 'lib/b.md']);
      expect(await files('{lib/src,test}/*.dart'), ['lib/src/d.dart', 'test/x1.dart', 'test/y2.dart']);
      expect(await files('test/[xy][0-9].dart'), ['test/x1.dart', 'test/y2.dart']);
      expect(await files('test/[!x]*.dart'), ['test/y2.dart']);
      await (dir / 'odd[.txt').writeText('x');
      expect(await files('odd[.txt'), ['odd[.txt']);
      for (final n in [']', 'b{1}.txt', 'b1.txt']) {
        await (dir / n).writeText('');
      }
      expect(await files('[]]'), [']']);
      expect(await files('b{1}.txt'), ['b{1}.txt']);
      expect((await files('{b1,b{1}}.txt')).toSet(), {'b1.txt', 'b{1}.txt'});
    });

    test('a missing folder is a PathNotFoundException; a bad glob an ArgumentError (FS-28)', () async {
      for (final only in [null, '**', '*.txt', 'sub/*.txt']) {
        await expectLater((dir / 'gone').files(only: only).toList(), throwsA(isA<PathNotFoundException>()));
      }
      await expectLater((dir / 'gone').dirs().toList(), throwsA(isA<PathNotFoundException>()));
      expect(() => dir.files(only: '/etc/*'), throwsArgumentError);
      expect(() => dir.files(minSize: -1), throwsArgumentError);
      expect(() => dir.files(newerThan: Duration.zero), throwsArgumentError);
      expect(() => dir.dirs(order: Order.largest), throwsArgumentError);
    });

    test('links are listed as themselves, never followed, by every listing (FS-17)', () async {
      await (dir / 'ln').symlink(dir / 'lib');
      await (dir / 'lf').symlink(dir / 'top.dart');
      expect(await files(null), ['lf', 'ln', 'top.dart']);
      expect(await files('**/*.dart'), isNot(contains(startsWith('ln/'))));
      expect(rel(await dir.dirs().toList(), dir), ['doc', 'lib', 'test']);
      expect(rel(await dir.entries().toList(), dir), ['doc', 'lf', 'lib', 'ln', 'test', 'top.dart']);
    }, testOn: '!windows');

    test('hidden: false leaves out dot names below the folder and never enters a dot folder', () async {
      final root = dir / '.config' / 'app';
      await (root / 'a.txt').writeText('a');
      await (root / 'sub' / 'b.txt').writeText('b');
      await (root / '.git' / 'c.txt').writeText('c');
      await (root / 'sub' / '.d.txt').writeText('d');
      expect(rel(await root.files(only: '**', hidden: false).toList(), root), ['a.txt', 'sub/b.txt']);
      expect(rel(await root.files(hidden: false).toList(), root), ['a.txt']);
      expect(rel(await root.files(only: '**').toList(), root), ['.git/c.txt', 'a.txt', 'sub/.d.txt', 'sub/b.txt']);
    });

    test('minSize and newerThan filter; the order shares their stats', () async {
      await (dir / 'big.txt').writeText('12345678901234567890');
      await (dir / 'top.dart').touch(at: DateTime.now().subtract(5.h));
      expect(names(await dir.files(minSize: 10).toList()), ['big.txt']);
      expect(names(await dir.files(newerThan: 2.h).toList()), ['big.txt']);
      expect(names(await dir.files(only: '*', order: Order.largest).toList()), ['big.txt', 'top.dart']);
    });

    test('order sorts every listing; above the worker threshold the same', () async {
      final now = DateTime.now();
      await (dir / 'p' / 'a10.jpg').writeText('xx').then((f) => f.touch(at: now.subtract(3.h)));
      await (dir / 'p' / 'a2.jpg').writeText('xxxx').then((f) => f.touch(at: now.subtract(1.h)));
      await (dir / 'p' / 'sub' / 'a1.jpg').writeText('x').then((f) => f.touch(at: now.subtract(2.h)));
      final p0 = dir / 'p';
      expect(names(await p0.files(only: '**/*.jpg', order: Order.newest).toList()), ['a2.jpg', 'a1.jpg', 'a10.jpg']);
      expect(names(await p0.files(only: '**/*.jpg', order: Order.oldest).toList()), ['a10.jpg', 'a1.jpg', 'a2.jpg']);
      expect(names(await p0.files(only: '**', order: Order.smallest).toList()), ['a1.jpg', 'a10.jpg', 'a2.jpg']);
      expect(names(await p0.entries(order: Order.natural).toList()), ['a2.jpg', 'a10.jpg', 'sub']);
      final many = await (dir / 'many').mkdir();
      for (var i = 0; i < 2100; i++) {
        File('$many/f$i.txt').writeAsStringSync('x' * (i % 7));
      }
      final sorted = await many.files(order: Order.largest).toList();
      expect((FileStat.statSync(sorted.first).size, FileStat.statSync(sorted.last).size), (6, 0));
    });

    test('ignore: leaves out matches and never enters an ignored folder', () async {
      await (dir / 'lib' / 'a.g.dart').writeText('');
      await (dir / 'build' / 'out.dart').writeText('');
      await (dir / 'node_modules' / 'x' / 'y.dart').writeText('');
      await (dir / 'lib' / 'build' / 'deep.dart').writeText('');
      await (dir / 'out' / 'o.dart').writeText('');
      await (dir / 'lib' / 'out' / 'kept.dart').writeText('');
      final ignore = ['build/', 'node_modules', '*.g.dart', '/out', 'test/', 'src/'];
      expect(await dir.files(only: '**/*.dart', ignore: ignore, order: Order.natural).map((f) => f.name).toList(), [
        'a.dart',
        'kept.dart',
        'top.dart',
      ]);
      expect(await dir.files(only: 'lib/**/*.dart', ignore: ['lib/']).toList(), isEmpty);
      expect(names(await dir.files(only: 'lib/*.dart', ignore: ['*.dart', '!a.g.dart']).toList()), ['a.g.dart']);
    });

    test('gitignore: honours .gitignore files on the way, scoped to their folder, and skips .git', () async {
      final g = await (dir / 'g').mkdir();
      await (g / '.gitignore').writeText('# comment\nbuild/\n*.log\n!keep.log\n/top.txt\n');
      await (g / '.git' / 'HEAD').writeText('ref');
      for (final f in ['a.log', 'keep.log', 'top.txt', 'build/x.txt', 'src/top.txt', 'src/gen/g.txt']) {
        await (g / f).writeText('');
      }
      await (g / 'src' / '.gitignore').writeText('gen/\r\nsecret.txt\n');
      await (g / 'src' / 'secret.txt').writeText('');
      await (g / 'other' / 'secret.txt').writeText('');
      final all = await g.files(only: '**', gitignore: true).toList();
      expect(rel(all.where((f) => !f.endsWith('.gitignore')), g), ['keep.log', 'other/secret.txt', 'src/top.txt']);
      expect(rel(await g.files(only: 'src/**/*.txt', gitignore: true).toList(), g), ['src/top.txt']);
      expect(await g.files(only: 'build/*.txt', gitignore: true).toList(), isEmpty);
      expect(names(await g.files(only: '**').toList()), containsAll(['HEAD', 'g.txt', 'x.txt']));
    });

    test('a folder below that cannot be read is skipped; a listing under .. is normalized', () async {
      await (dir / 'shut' / 'b.txt').writeText('b');
      Process.runSync('chmod', ['000', dir / 'shut']);
      addTearDown(() => Process.runSync('chmod', ['755', dir / 'shut']));
      expect(await files('**/*.txt'), ['lib/c.txt']);
      expect(rel(await dir.dirs(only: '**').toList(), dir), contains('shut'));
      final odd = Path('$dir/x/../lib/../.');
      expect(await odd.files().toList(), [dir / 'top.dart']);
    }, testOn: '!windows');
  });

  group('copy and move', () {
    test('exactly one of to: and into:; into keeps the name (FS-15)', () async {
      final f = await (dir / 'a.txt').writeText('x');
      expect(() => f.copy(), throwsArgumentError);
      expect(() => f.copy(to: 'b', into: 'c'), throwsArgumentError);
      expect(() => f.move(), throwsArgumentError);
      expect(await f.copy(into: dir / 'backup'), dir / 'backup' / 'a.txt');
      expect(await f.copy(to: dir / 'b.txt'), dir / 'b.txt');
      expect(await (dir / 'b.txt').move(into: dir / 'done'), dir / 'done' / 'b.txt');
      expect(await (dir / 'done' / 'b.txt').readText(), 'x');
    });

    test('one conflict meaning per file: skip by default, Done(fresh: false) (FS-12, FS-13)', () async {
      final src = await (dir / 'note.txt').writeText('new');
      final taken = await (dir / 'taken.txt').writeText('old');
      final skipped = src.copy(to: taken);
      expect(await skipped, taken);
      expect(await skipped.settled, isA<Done<Object?, Path>>().having((d) => d.fresh, 'fresh', isFalse));
      final fresh = src.copy(to: dir / 'free.txt');
      expect((await fresh.settled as Done).fresh, isTrue);
      expect(await src.move(to: taken), taken);
      expect((await taken.readText(), await src.exists()), ('old', true), reason: 'skip leaves both');
      await expectLater(
        src.copy(to: taken, conflict: Conflict.fail),
        throwsA(isA<PathExistsException>().having((e) => e.message, 'message', 'Cannot copy $src: $taken exists')),
      );
      expect(await src.copy(to: taken, conflict: Conflict.rename), dir / 'taken (1).txt');
      expect(await src.copy(to: taken, conflict: Conflict.rename), dir / 'taken (2).txt');
      expect(await src.copy(to: taken, conflict: Conflict.overwrite), taken);
      expect(await taken.readText(), 'new');
      await taken.writeText('older');
      await File(taken).setLastModified(DateTime.now().add(1.h));
      expect((await src.copy(to: taken, conflict: Conflict.newer).settled as Done).fresh, isFalse);
      expect(await src.move(to: taken, conflict: Conflict.rename), dir / 'taken (3).txt');
      expect(await src.exists(), isFalse);
    });

    test('two copies asking for a free name at once get two names (X-4)', () async {
      final a = await (dir / 'a' / 'f.txt').writeText('a');
      final b = await (dir / 'b' / 'f.txt').writeText('b');
      await (dir / 'out' / 'f.txt').writeText('there');
      final landed = await Future.wait([
        a.copy(into: dir / 'out', conflict: Conflict.rename),
        b.copy(into: dir / 'out', conflict: Conflict.rename),
      ]);
      expect(landed.toSet(), hasLength(2));
      expect({for (final f in landed) await f.readText()}, {'a', 'b'});
    });

    test('an overwrite is a rename over, never a delete first (X-6)', () async {
      final src = await (dir / 'src.txt').writeText('new');
      final dst = await (dir / 'dst.txt').writeText('old');
      final reader = File(dst).openSync();
      await src.move(to: dst, conflict: Conflict.overwrite);
      expect(String.fromCharCodes(reader.readSync(10)), 'old', reason: 'the old inode was replaced, not truncated');
      reader.closeSync();
      expect(await dst.readText(), 'new');
      // A folder over a file is refused, and both stay.
      final folder = await (dir / 'folder' / 'x').writeText('x');
      await expectLater(folder.parent.move(to: dst, conflict: Conflict.overwrite), throwsA(isA<FileSystemException>()));
      expect((await folder.exists(), await dst.readText()), (true, 'new'));
    });

    test('folders merge, the policy applied to each file inside (FS-5)', () async {
      await (dir / 'src' / 'a.txt').writeText('new a');
      await (dir / 'src' / 'sub' / 'b.txt').writeText('new b');
      await (dir / 'dst' / 'a.txt').writeText('old a');
      await (dir / 'dst' / 'keep.txt').writeText('keep');
      final copy = (dir / 'src').copy(to: dir / 'dst');
      expect(await copy, dir / 'dst');
      expect(
        [
          await (dir / 'dst' / 'a.txt').readText(),
          await (dir / 'dst' / 'sub' / 'b.txt').readText(),
          await (dir / 'dst' / 'keep.txt').readText(),
        ],
        ['old a', 'new b', 'keep'],
      );
      expect((await copy.settled as Done).fresh, isTrue, reason: 'b.txt was new');
      expect(
        ((await (dir / 'src').copy(to: dir / 'dst').settled) as Done).fresh,
        isFalse,
        reason: 'a rerun does nothing',
      );
      await (dir / 'src').copy(to: dir / 'dst', conflict: Conflict.overwrite);
      expect(await (dir / 'dst' / 'a.txt').readText(), 'new a');
      await (dir / 'src' / 'a.txt').writeText('newer a');
      await (dir / 'src').move(to: dir / 'dst');
      expect(await (dir / 'src' / 'a.txt').readText(), 'newer a', reason: 'a skipped file stays in the source');
      await (dir / 'src').move(to: dir / 'dst', conflict: Conflict.overwrite);
      expect((await (dir / 'src').exists(), await (dir / 'dst' / 'a.txt').readText()), (false, 'newer a'));
    });

    test('a stopped copy leaves no half file and no temp file (X-8, FS-7)', () async {
      final big = await (dir / 'big.bin').writeBytes(List.filled(200 << 20, 7));
      final task = big.copy(to: dir / 'copy.bin');
      await task.statuses.firstWhere((s) => s is Running<Object?, Path> && s.received > 0);
      task.cancel('enough');
      expect(await task.settled, isA<Stopped<Object?, Path>>());
      expect(names(await dir.entries().toList()), ['big.bin']);
    });

    test('a large copy reports its bytes; a folder its files', () async {
      final big = await (dir / 'src' / 'a.bin').writeBytes(List.filled(80 << 20, 7));
      await (dir / 'src' / 'sub' / 'b.txt').writeText('bee');
      final seen = <Running<Object?, Path>>[];
      final one = big.copy(to: dir / 'one.bin');
      one.statuses.listen((s) => s is Running<Object?, Path> ? seen.add(s) : null);
      await one;
      expect(seen.where((r) => r.unit == Unit.bytes).last.received, 80 << 20);
      expect(one.label, p.join('src', 'a.bin'));
      final items = <Running<Object?, Path>>[];
      final tree = (dir / 'src').copy(to: dir / 'tree');
      tree.statuses.listen((s) => s is Running<Object?, Path> ? items.add(s) : null);
      await tree;
      expect(items.last.unit, Unit.items);
      expect((items.last.received, items.last.total), (2, 2));
      expect(await (dir / 'tree' / 'a.bin').size(), 80 << 20);
    });

    test('links are copied and moved as links; modes of copied folders come back last', () async {
      await (dir / 'src' / 'f.txt').writeText('hello');
      await (dir / 'src' / 'l.txt').symlink('f.txt');
      await (dir / 'src' / 'ro' / 'x').writeText('x');
      await (dir / 'src' / 'ro').chmod('555');
      await (dir / 'src' / 'private').mkdir();
      await (dir / 'src' / 'private').chmod('700');
      addTearDown(() async {
        for (final d in [dir / 'src' / 'ro', dir / 'dst' / 'ro']) {
          if (await d.exists()) await d.chmod('755');
        }
      });
      await (dir / 'src').copy(to: dir / 'dst');
      expect(await (dir / 'dst' / 'l.txt').type(), PathType.link);
      expect(await (dir / 'dst' / 'l.txt').readText(), 'hello');
      expect((mode(dir / 'dst' / 'ro'), mode(dir / 'dst' / 'private')), (0x16d, 0x1c0));
      await (dir / 'src' / 'l.txt').copy(to: dir / 'one.txt');
      expect(await (dir / 'one.txt').type(), PathType.link);
      await (dir / 'one.txt').move(to: dir / 'moved.txt');
      expect(await (dir / 'moved.txt').type(), PathType.link);
    }, testOn: '!windows');

    test('a folder is never copied or moved into itself, however spelled', () async {
      final src = await (dir / 'a' / 'f').writeText('x').then((f) => f.parent);
      final real = Path(Directory(dir).resolveSymbolicLinksSync());
      await expectLater(src.copy(to: real / 'a' / 'sub'), throwsA(isA<FileSystemException>()));
      await expectLater(src.copy(to: src), throwsA(isA<FileSystemException>()));
      await expectLater(Path('$dir/a/../a').move(into: src), throwsA(isA<FileSystemException>()));
      expect(names(await src.entries(only: '**').toList()), ['f']);
    });

    test('a missing source is a PathNotFoundException that makes nothing', () async {
      final gone = dir / 'gone';
      await expectLater(gone.copy(to: dir / 'to'), throwsA(isA<PathNotFoundException>()));
      await expectLater(gone.move(to: dir / 'made' / 'up'), throwsA(isA<PathNotFoundException>()));
      expect(await (dir / 'made').exists(), isFalse);
    });

    test('an overwrite onto the source itself keeps it', () async {
      final f = await (dir / 'a' / 'b.txt').writeText('x');
      expect(await f.copy(to: f, conflict: Conflict.overwrite), f);
      expect(await f.move(to: f, conflict: Conflict.overwrite), f);
      expect(await f.readText(), 'x');
      if (Platform.isMacOS) {
        expect(await (await f.move(to: dir / 'a' / 'B.txt', conflict: Conflict.overwrite)).readText(), 'x');
      }
    });

    test('a move to another volume copies, then deletes the source', () async {
      final far = await _otherVolume();
      if (far == null) return markTestSkipped('no second volume: a RAM disk on macOS, /dev/shm on Linux');
      final bytes = List.generate(3 << 20, (i) => i * 31 & 0xff);
      final file = await (dir / 'big.bin').writeBytes(bytes);
      expect(await file.move(to: far / 'big.bin'), far / 'big.bin');
      expect(await (far / 'big.bin').readBytes(), bytes);
      expect(await file.exists(), isFalse);
      final tree = dir / 'tree';
      await (tree / 'sub' / 'b.txt').writeText('bee');
      await (tree / 'run.sh').writeText('#!/bin/sh\n');
      await (tree / 'run.sh').chmod('755');
      await tree.move(into: far);
      expect((await tree.exists(), await (far / 'tree' / 'sub' / 'b.txt').readText()), (false, 'bee'));
      expect(mode(far / 'tree' / 'run.sh'), 0x1ed);
    }, testOn: 'mac-os || linux');
  });

  group('delete, deleteEmpty, mkdir, symlink, trash', () {
    test('delete: nothing there is Done(fresh: false); a full folder needs recursive', () async {
      final d = await (dir / 'd' / 'f.txt').writeText('x').then((f) => f.parent);
      await expectLater(d.delete(), throwsA(isA<FileSystemException>()));
      await d.delete(recursive: true);
      expect(await d.exists(), isFalse);
      expect((await d.delete().settled as Done).fresh, isFalse);
      final target = await (dir / 'keep.txt').writeText('k');
      final link = await (dir / 'l').symlink(target);
      await link.delete();
      expect((await link.exists(), await target.exists()), (false, true), reason: 'a link, never its target');
    }, testOn: '!windows');

    test('deleteEmpty removes empty folders deepest first and keeps the rest; missing is an error', () async {
      await (dir / 'a' / 'b' / 'c').mkdir();
      await (dir / 'k' / 'keep.txt').writeText('x');
      await dir.deleteEmpty();
      expect(
        [await (dir / 'a').exists(), await (dir / 'k' / 'keep.txt').exists(), await dir.exists()],
        [false, true, true],
      );
      await expectLater((dir / 'gone').deleteEmpty(), throwsA(isA<PathNotFoundException>()));
    });

    test('mkdir and symlink answer the path; mkdir of a folder there is not fresh', () async {
      final d = dir / 'x' / 'y';
      expect(await d.mkdir(), d);
      expect((await d.mkdir().settled as Done).fresh, isFalse);
      expect(await (dir / 'l' / 'link').symlink('../x'), dir / 'l' / 'link');
    });

    test(
      'trash keeps the name when the trash has none, and numbers a second one',
      () => Env.scope(() async {
        Env.set('HOME', dir);
        Env.set('XDG_DATA_HOME', '$dir/.local/share');
        final bin = Platform.isMacOS ? '$dir/.Trash' : '$dir/.local/share/Trash/files';
        final f = await (dir / 'gone.txt').writeText('x');
        await f.trash();
        expect((await f.exists(), File('$bin/gone.txt').existsSync()), (false, true));
        await (dir / 'gone.txt').writeText('y');
        await (dir / 'gone.txt').trash();
        expect(File('$bin/gone (1).txt').readAsStringSync(), 'y');
        expect((await (dir / 'none').trash().settled as Done).fresh, isFalse);
      }),
      testOn: 'mac-os || linux',
    );

    test(
      'a Linux .trashinfo has the path percent-encoded and the date to the second',
      () => Env.scope(() async {
        Env.set('XDG_DATA_HOME', '$dir/share');
        final f = await (dir / 'a b%c é.txt').writeText('x');
        await f.trash();
        final info = File('$dir/share/Trash/info/a b%c é.txt.trashinfo').readAsLinesSync();
        expect(info[1], 'Path=${Uri.file(f).path}');
        expect(info[2], matches(RegExp(r'^DeletionDate=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$')));
      }),
      testOn: 'linux',
    );

    test('trash on another volume uses that volume\'s trash, never a copy home (X-7, FS-34)', () async {
      final far = await _otherVolume();
      if (far == null) return markTestSkipped('no second volume');
      await Env.scope(() async {
        Env.set('HOME', dir);
        final f = await (far / 'away.txt').writeText('x');
        await f.trash();
        expect(await f.exists(), isFalse);
        expect(File('$dir/.Trash/away.txt').existsSync(), isFalse, reason: 'not copied to the home volume');
        final bins = await far.files(only: '**/away.txt').toList();
        expect(bins, hasLength(1));
      });
    }, testOn: 'mac-os');
  });

  group('renames', () {
    Future<Renames> plan(String? Function(Path f) fn, {Conflict conflict = Conflict.skip}) =>
        dir.files().plan(fn, conflict: conflict);

    test('plan, apply and undo, a cycle included', () async {
      for (final (n, t) in [('a', 'AAA'), ('b', 'BBB'), ('c', 'CCC')]) {
        await (dir / '$n.txt').writeText(t);
      }
      String? cycle(Path f) => switch (f.name) {
        'a.txt' => 'b.txt',
        'b.txt' => 'c.txt',
        'c.txt' => 'a.txt',
        _ => null,
      };
      final renames = await plan(cycle);
      expect(renames, hasLength(3));
      expect('$renames', contains('a.txt -> b.txt'));
      expect(await (dir / 'a.txt').readText(), 'AAA', reason: 'a plan touches nothing');
      expect(() => renames.undo(), throwsStateError, reason: 'nothing was applied (FS-22)');
      expect(await renames.apply(), hasLength(3));
      expect(
        [
          for (final n in ['a', 'b', 'c']) await (dir / '$n.txt').readText(),
        ],
        ['CCC', 'AAA', 'BBB'],
      );
      expect(() => renames.apply(), throwsStateError);
      await renames.undo();
      expect(
        [
          for (final n in ['a', 'b', 'c']) await (dir / '$n.txt').readText(),
        ],
        ['AAA', 'BBB', 'CCC'],
      );
      expect(names(await dir.entries().toList())..sort(), ['a.txt', 'b.txt', 'c.txt'], reason: 'no temp names left');
    });

    test('a rename onto a file that stays is a clash, never an overwrite (X-2)', () async {
      await (dir / 'a.txt').writeText('A');
      await (dir / 'b.txt').writeText('B');
      await expectLater(
        plan((f) => f.name == 'a.txt' ? 'b.txt' : null, conflict: Conflict.fail),
        throwsA(isA<PathExistsException>()),
      );
      expect(await plan((f) => f.name == 'a.txt' ? 'b.txt' : null), isEmpty, reason: 'skip leaves it');
      await (dir / 'c.txt').writeText('C');
      final r = await plan(
        (f) => switch (f.name) {
          'a.txt' => 'b.txt',
          'c.txt' => 'a.txt',
          _ => null,
        },
      );
      expect(r, isEmpty, reason: 'a skip keeps a.txt in place, so c.txt cannot take its name');
      await r.apply();
      expect(
        [
          for (final n in ['a', 'b', 'c']) await (dir / '$n.txt').readText(),
        ],
        ['A', 'B', 'C'],
      );
    });

    test('a case-only rename onto another file is a clash where case tells files apart (X-3)', () async {
      await (dir / 'Readme.md').writeText('one');
      if (await (dir / 'README.md').exists()) {
        // A disk that does not tell case apart: one file, and renaming it is allowed.
        await (await plan((f) => 'README.md')).apply();
        expect(names(await dir.entries().toList()), ['README.md']);
        return;
      }
      await (dir / 'README.md').writeText('two');
      await expectLater(
        plan((f) => f.name == 'Readme.md' ? 'README.md' : null, conflict: Conflict.fail),
        throwsA(isA<PathExistsException>()),
      );
      expect(await (dir / 'README.md').readText(), 'two');
    });

    test('rename to free names gives every file its own (X-4)', () async {
      for (final n in ['x', 'y', 'z']) {
        await (dir / '$n.txt').writeText(n);
      }
      await (dir / 'all.txt').writeText('taken');
      await (await plan((f) => f.name == 'all.txt' ? null : 'all.txt', conflict: Conflict.rename)).apply();
      expect(names(await dir.files().toList()).toSet(), {'all.txt', 'all (1).txt', 'all (2).txt', 'all (3).txt'});
      expect({for (final f in await dir.files().toList()) await f.readText()}, {'taken', 'x', 'y', 'z'});
    });

    test('two files wanting one name: skip keeps the second, fail and overwrite refuse', () async {
      await (dir / '1.txt').writeText('1');
      await (dir / '2.txt').writeText('2');
      expect(await plan((f) => 'same.txt'), hasLength(1));
      await expectLater(plan((f) => 'same.txt', conflict: Conflict.fail), throwsA(isA<FileSystemException>()));
      await expectLater(plan((f) => 'same.txt', conflict: Conflict.overwrite), throwsA(isA<FileSystemException>()));
      expect(() => plan((f) => 'x', conflict: Conflict.newer), throwsArgumentError);
    });

    test('overwrite replaces what is on disk; a file taken since the plan fails its item', () async {
      await (dir / 'a.txt').writeText('A');
      await (dir / 'b.txt').writeText('B');
      await (dir / 'c.txt').writeText('C');
      final over = await plan((f) => f.name == 'a.txt' ? 'b.txt' : null, conflict: Conflict.overwrite);
      await over.apply();
      expect((await (dir / 'b.txt').readText(), await (dir / 'a.txt').exists()), ('A', false));
      final later = await plan((f) => f.name == 'c.txt' ? 'd.txt' : null);
      await (dir / 'd.txt').writeText('D');
      final outcome = await later.apply().settled;
      expect(outcome.single, isA<Failed<Object?, Path>>().having((f) => f.error, 'error', isA<PathExistsException>()));
      expect((await (dir / 'c.txt').readText(), await (dir / 'd.txt').readText()), ('C', 'D'));
    });
  });

  group('watching and locks', () {
    test('changes batches a burst of writes, outlives atomic writes, hides their temps', () async {
      final f = await (dir / 'w.txt').writeText('0');
      final onFile = <FileChanges>[], onDir = <FileChanges>[];
      final a = f.changes(debounce: 100.ms).listen(onFile.add);
      final b = dir.changes(debounce: 300.ms).listen(onDir.add);
      await Future<void>.delayed(800.ms);
      onFile.clear();
      onDir.clear();
      for (var i = 1; i <= 3; i++) {
        await f.writeText('$i');
        await Future<void>.delayed(400.ms);
      }
      for (final n in ['a', 'b', 'c']) {
        await (dir / '$n.txt').writeText(n);
      }
      await Future<void>.delayed(800.ms);
      await a.cancel();
      await b.cancel();
      expect(onFile.length, greaterThanOrEqualTo(3), reason: 'every write is heard');
      expect(onFile.expand((b) => b.all).toSet(), {f});
      expect(onDir.expand((b) => b.all).map((e) => e.name).toSet(), {'w.txt', 'a.txt', 'b.txt', 'c.txt'});
      expect(onDir.last.all.map((e) => e.name).toSet(), {'a.txt', 'b.txt', 'c.txt'}, reason: 'a burst is one batch');
    });

    test('changes on a missing folder fails; it ends with its Cancel.scope (FS-37)', () async {
      await expectLater((dir / 'nope' / 'f.txt').changes().first.timeout(2.s), throwsA(isA<PathNotFoundException>()));
      final token = CancelToken();
      final done = Cancel.scope(() async {
        await for (final _ in dir.changes()) {}
      }, token: token);
      await Future<void>.delayed(100.ms);
      token.cancel();
      await expectLater(done.timeout(2.s), throwsA(isA<CancelledException>()));
      expect(() => dir.changes(debounce: Duration.zero), throwsArgumentError);
    });

    test('tail sees appends, a partial line once whole, truncation and rotation', () async {
      final f = await (dir / 'app.log').writeText('before\n');
      final lines = <String>[];
      final sub = f.tail().listen(lines.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(150.ms);
      await f.appendText('one\npar');
      await _until(() => lines.contains('one'));
      await f.appendText('tial\n');
      await _until(() => lines.contains('partial'));
      await f.writeText('two\n');
      await _until(() => lines.contains('two'));
      await f.move(to: dir / 'app.log.1');
      await f.writeText('rotated, and longer than what was there\n');
      await _until(() => lines.contains('rotated, and longer than what was there'));
      expect(lines, ['one', 'partial', 'two', 'rotated, and longer than what was there']);
    });

    test('tail sees a rotation that keeps the size and the first bytes', () async {
      final f = await (dir / 'same.log').writeText('start\n');
      final lines = <String>[];
      final sub = f.tail().listen(lines.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(150.ms);
      await f.appendText('aaaa\n');
      await _until(() => lines.contains('aaaa'));
      await f.move(to: dir / 'same.log.1');
      await f.writeText('start\nbbbb\n');
      await _until(() => lines.contains('bbbb'));
      expect(lines, ['aaaa', 'start', 'bbbb']);
    });

    test('tail waits for a missing file and ends with its Cancel.scope', () async {
      final f = dir / 'later.log';
      final token = CancelToken();
      final lines = <String>[];
      final done = Cancel.scope(() async {
        await for (final line in f.tail()) {
          lines.add(line);
        }
      }, token: token);
      await Future<void>.delayed(150.ms);
      await f.writeText('hello\n');
      await _until(() => lines.contains('hello'));
      token.cancel();
      await expectLater(done.timeout(2.s), throwsA(isA<CancelledException>()));
      expect(lines, ['hello']);
    });

    test('lock is exclusive in the isolate; held, wait: false is a FileSystemException naming it (FS-29)', () async {
      final lock = dir / 'locks' / 'job.lock';
      final order = <String>[];
      Future<void> job(String id) => lock.lock(() async {
        order.add('$id+');
        await Future<void>.delayed(20.ms);
        order.add('$id-');
      });
      await Future.wait([job('a'), job('b')]);
      expect(order, ['a+', 'a-', 'b+', 'b-']);
      await lock.lock(() async {
        await expectLater(
          lock.lock(() {}, wait: false),
          throwsA(isA<FileSystemException>().having((e) => e.path, 'path', lock)),
        );
      });
      expect(await lock.lock(() => 'x'), 'x');
    });

    test('lock is exclusive across isolates, and a link to the file is the same lock (FS-36)', () async {
      final lock = dir / 'job.lock';
      final link = await (dir / 'link.lock').symlink(lock.path).then((l) => l);
      await lock.writeText('');
      await lock.lock(() async {
        final elsewhere = await Isolate.run(() async {
          try {
            await lock.lock(() {}, wait: false);
            return 'got it';
          } on FileSystemException catch (e) {
            return e.message;
          }
        });
        expect(elsewhere, contains('held by'));
        await expectLater(link.lock(() {}, wait: false), throwsA(isA<FileSystemException>()));
      });
      expect(await Isolate.run(() => lock.lock(() => 'free', wait: false)), 'free');
    }, testOn: '!windows');

    test('lock across processes: wait: false throws, a wait ends on release, a crash releases', () async {
      final lock = dir / 'job.lock';
      final script = await (dir / 'hold.dart').writeText('''
import 'dart:io';
import 'package:dart_toolkit/path.dart';
Future<void> main(List<String> args) async {
  await Path(args[0]).lock(() async {
    print('locked');
    await stdin.drain<void>();
  });
}
''');
      final packages = File('.dart_tool/package_config.json').absolute.path;
      Future<Process> hold() async {
        final child = await Process.start(Platform.resolvedExecutable, ['--packages=$packages', script, lock]);
        expect((await child.stdout.transform(utf8.decoder).first).trim(), 'locked');
        return child;
      }

      var child = await hold();
      await expectLater(
        lock.lock(() {}, wait: false),
        throwsA(isA<FileSystemException>().having((e) => e.message, 'message', contains('another process'))),
      );
      await expectLater(Cancel.scope(() => lock.lock(() {}), timeout: 150.ms), throwsA(isA<CancelledException>()));
      var got = false;
      final waiting = lock.lock(() => got = true);
      await Future<void>.delayed(100.ms);
      expect(got, isFalse);
      await child.stdin.close();
      await waiting.timeout(10.s);
      expect(got, isTrue);
      expect(await child.exitCode, 0);
      child = await hold();
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
      expect(await lock.lock(() => 'free', wait: false), 'free');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

/// Polls [done] until it holds, for at most five seconds.
Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Bytes that fail to be read: a write that breaks after its temp file is open.
class _Faulty with ListMixin<int> {
  @override
  int length = 100000;

  @override
  int operator [](int i) => throw StateError('no byte $i');

  @override
  void operator []=(int i, int v) {}
}

/// A fresh folder on a volume other than the system temp's, gone when the test ends: a RAM disk
/// on macOS, a folder in `/dev/shm` on Linux. Null when neither can be had.
Future<Path?> _otherVolume() async {
  if (Platform.isMacOS) {
    final attach = await Process.run('hdiutil', ['attach', '-nomount', 'ram://32768']);
    if (attach.exitCode != 0) return null;
    final device = '${attach.stdout}'.trim().split(RegExp(r'\s+')).first;
    addTearDown(() => Process.run('hdiutil', ['detach', device, '-force']));
    final erase = await Process.run('diskutil', ['erasevolume', 'HFS+', 'tk_move_$pid', device]);
    if (erase.exitCode != 0) return null;
    final info = await Process.run('diskutil', ['info', device]);
    final mount = RegExp(r'Mount Point:\s*(.+)').firstMatch('${info.stdout}')?.group(1)?.trim();
    return mount == null || mount.isEmpty ? null : Path(mount);
  }
  if (Platform.isLinux && Directory('/dev/shm').existsSync()) {
    final Directory shm;
    try {
      shm = Directory('/dev/shm').createTempSync('tk_move_');
    } on FileSystemException {
      return null;
    }
    addTearDown(() => shm.deleteSync(recursive: true));
    Future<String> device(String path) async => '${(await Process.run('stat', ['-c', '%d', path])).stdout}'.trim();
    return await device(shm.path) == await device(Directory.systemTemp.path) ? null : Path(shm.path);
  }
  return null;
}

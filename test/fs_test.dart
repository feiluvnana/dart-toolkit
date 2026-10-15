import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io;

import 'package:dart_toolkit/fs.dart';
import 'package:test/test.dart';

import 'support/child.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fs_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  String p(String name) => '${tmp.path}/$name';

  group('Fs', () {
    test('sanitize makes one portable name that never leaves its folder', () {
      expect(Fs.sanitize('Re:Zero / 第1話 <raw>?'), 'Re_Zero _ 第1話 _raw__');
      expect(Fs.sanitize('../../etc/passwd'), '_.._.._etc_passwd');
      expect(Fs.sanitize('CON.txt'), '_CON.txt');
      expect(Fs.sanitize('-rf'), '_-rf');
      expect(Fs.sanitize('name. '), 'name');
      expect(Fs.sanitize('  '), '_');
      final long = Fs.sanitize('話' * 200);
      expect(utf8.encode(long).length, lessThanOrEqualTo(255));
      expect(long, '話' * 85);
    });

    test('entry tells file, folder, link and nothing apart', () async {
      await Fs.file(p('a.txt')).write('x');
      await Fs.dir(p('sub')).create();
      await Fs.link(p('lnk')).create(p('a.txt'));
      expect(await Fs.entry(p('a.txt')), isA<File>());
      expect(await Fs.entry(p('sub')), isA<Dir>());
      expect(await Fs.entry(p('lnk')), isA<Link>());
      expect(await Fs.entry(p('missing')), isNull);
    });

    test('a trailing slash never follows a link', () async {
      await Fs.dir(p('sub')).create();
      await Fs.link(p('ln')).create(p('sub'));
      expect(await Fs.entry('${p('ln')}/'), isA<Link>());
    });

    test('handles do no I/O and compare by path', () {
      expect(Fs.file(p('x')), Fs.file(p('x')));
      expect(Fs.file(p('x')), isNot(Fs.dir(p('x'))));
    });

    test('dir().dir().file() builds a path', () async {
      final f = Fs.dir(p('a')).dir('b').file('c.txt');
      expect(f.path(), p('a/b/c.txt'));
      await f.write('deep');
      expect(await Fs.file(p('a/b/c.txt')).text(), 'deep');
    });
  });

  group('Entry', () {
    test('path(from:) is relative to a folder', () async {
      final root = Fs.dir(p('site'));
      expect(root.dir('a').file('b.txt').path(from: root), 'a/b.txt');
      expect(await Future.value(root.file('c.txt')).path(from: root), 'c.txt');
    });

    test('path/name/parent', () async {
      final f = Fs.file(p('a.txt'));
      expect(f.path(), p('a.txt'));
      expect(f.name(), 'a.txt');
      expect(f.parent().path(), tmp.path);
    });

    test('exists is true only for its own kind', () async {
      await Fs.file(p('a.txt')).write('x');
      await Fs.dir(p('sub')).create();
      expect(await Fs.file(p('a.txt')).exists(), isTrue);
      expect(await Fs.file(p('sub')).exists(), isFalse);
      expect(await Fs.dir(p('a.txt')).exists(), isFalse);
      expect(await Fs.file(p('missing')).exists(), isFalse);
    });

    test('delete removes and is a no-op when nothing is there', () async {
      await Fs.file(p('a.txt')).write('x');
      await Fs.file(p('a.txt')).delete();
      expect(await Fs.entry(p('a.txt')), isNull);
      await Fs.file(p('a.txt')).delete();
      await Fs.dir(p('sub')).create();
      await Fs.dir(p('sub')).delete();
      expect(await Fs.entry(p('sub')), isNull);
    });

    test('copy and move keep the type and make parents', () async {
      await Fs.file(p('a.txt')).write('x');
      final c = await Fs.file(p('a.txt')).copy(p('d/e.txt'));
      expect(c, isA<File>());
      expect(await Fs.file(p('d/e.txt')).text(), 'x');
      final m = await Fs.file(p('d/e.txt')).move(p('f.txt'));
      expect(m, isA<File>());
      expect(await Fs.entry(p('d/e.txt')), isNull);
    });

    test('dir copy is recursive, links as links', () async {
      await Fs.file(p('src/a.txt')).write('a');
      await Fs.file(p('src/nested/b.txt')).write('b');
      await Fs.link(p('src/lnk')).create(p('src/a.txt'));
      final c = await Fs.dir(p('src')).copy(p('dst'));
      expect(c, isA<Dir>());
      expect(await Fs.file(p('dst/a.txt')).text(), 'a');
      expect(await Fs.file(p('dst/nested/b.txt')).text(), 'b');
      expect(await Fs.entry(p('dst/lnk')), isA<Link>());
    });

    test('F8: move into a non-empty folder throws and keeps the source', () async {
      await Fs.file(p('src/a.txt')).write('a');
      await Fs.file(p('dst/b.txt')).write('b');
      await expectLater(Fs.dir(p('src')).move(p('dst')), throwsA(isA<FileSystemException>()));
      expect(await Fs.file(p('src/a.txt')).exists(), isTrue);
      expect(await Fs.file(p('dst/b.txt')).text(), 'b');
    });

    test('F9: copy into itself and missing sources fail before writing', () async {
      await Fs.file(p('src/a.txt')).write('a');
      await expectLater(Fs.dir(p('src')).copy(p('src/sub')), throwsArgumentError);
      expect(await Fs.entry(p('src/sub')), isNull);
      await expectLater(Fs.file(p('missing.txt')).copy(p('dst.txt')), throwsA(isA<FileSystemException>()));
      expect(await Fs.entry(p('dst.txt')), isNull);
    });

    test('dir copy into an existing tree merges, replacing files and links', () async {
      await Fs.file(p('src/a.txt')).write('new');
      await Fs.file(p('src/nested/b.txt')).write('b');
      await Fs.link(p('src/lnk')).create('a.txt');
      await Fs.file(p('dst/a.txt')).write('old');
      await Fs.file(p('dst/keep.txt')).write('k');
      await Fs.file(p('outside.txt')).write('o');
      await Fs.link(p('dst/lnk')).create(p('outside.txt'));
      await Fs.dir(p('src')).copy(p('dst'));
      expect(await Fs.file(p('dst/a.txt')).text(), 'new');
      expect(await Fs.file(p('dst/nested/b.txt')).text(), 'b');
      expect(await Fs.file(p('dst/keep.txt')).text(), 'k');
      expect(await Fs.link(p('dst/lnk')).target(), 'a.txt');
      expect(await Fs.file(p('outside.txt')).text(), 'o');
    });

    test('a merging dir copy keeps nested folder modes and mtimes', () async {
      if (Platform.isWindows) markTestSkipped('needs POSIX modes');
      await Fs.file(p('src/a/b/f.txt')).write('f');
      await Process.run('chmod', ['700', p('src/a')]);
      await Process.run('touch', ['-t', '200102030405.06', p('src/a/b'), p('src/a')]);
      await Fs.dir(p('dst')).create();
      await Fs.dir(p('src')).copy(p('dst'));
      expect((await Directory(p('dst/a')).stat()).mode & 0xfff, 448);
      expect((await Directory(p('dst/a/b')).stat()).modified.year, 2001);
      expect((await Directory(p('dst/a')).stat()).modified.year, 2001);
    });

    test('a merging dir copy replaces a dest link to a folder, never follows it', () async {
      await Fs.file(p('src/sub/f.txt')).write('f');
      await Fs.dir(p('elsewhere')).create();
      await Fs.link(p('dst/sub')).create(p('elsewhere'));
      await Fs.dir(p('src')).copy(p('dst'));
      expect(await Fs.entry(p('dst/sub')), isA<Dir>());
      expect(await Fs.file(p('dst/sub/f.txt')).text(), 'f');
      expect(await Fs.dir(p('elsewhere')).list(), isEmpty);
    });

    test('dir copy over a file/folder collision throws before writing', () async {
      await Fs.file(p('src/a.txt')).write('a');
      await Fs.file(p('src/x')).write('file');
      await Fs.dir(p('dst/x')).create();
      await expectLater(Fs.dir(p('src')).copy(p('dst')), throwsA(isA<FileSystemException>()));
      expect(await Fs.entry(p('dst/a.txt')), isNull);
    });

    test('a dir is not a file: copy and move check the kind', () async {
      await Fs.dir(p('d')).create();
      await expectLater(Fs.file(p('d')).copy(p('e')), throwsA(isA<FileSystemException>()));
      await expectLater(Fs.dir(p('missing')).move(p('e')), throwsA(isA<FileSystemException>()));
      expect(await Fs.entry(p('e')), isNull);
    });

    test('File/Dir go through links; Link asks about itself (regression: exists() false while text() read)', () async {
      await Fs.file(p('a.txt')).write('x');
      await Fs.file(p('d/b.txt')).write('b');
      await Fs.link(p('ln.txt')).create(p('a.txt'));
      await Fs.link(p('ld')).create(p('d'));
      expect(await Fs.file(p('ln.txt')).exists(), isTrue);
      expect(await Fs.dir(p('ld')).exists(), isTrue);
      expect(await Fs.link(p('ln.txt')).exists(), isTrue);
      expect(await Fs.link(p('a.txt')).exists(), isFalse);
      expect(await Fs.dir(p('ln.txt')).exists(), isFalse);
      // copy follows: a real file / folder at the destination.
      expect(await (await Fs.file(p('ln.txt')).copy(p('c.txt'))).text(), 'x');
      expect(await Fs.entry(p('c.txt')), isA<File>());
      await Fs.dir(p('ld')).copy(p('cd'));
      expect(await Fs.entry(p('cd')), isA<Dir>());
      expect(await Fs.file(p('cd/b.txt')).text(), 'b');
      // move moves the link itself.
      await Fs.file(p('ln.txt')).move(p('m.txt'));
      expect(await Fs.entry(p('m.txt')), isA<Link>());
      await Fs.dir(p('ld')).move(p('md'));
      expect(await Fs.entry(p('md')), isA<Link>());
      // delete through a File/Dir handle takes the link, never the target.
      await Fs.file(p('m.txt')).delete();
      await Fs.dir(p('md')).delete();
      expect(await Fs.entry(p('m.txt')), isNull);
      expect(await Fs.entry(p('md')), isNull);
      expect(await Fs.file(p('a.txt')).text(), 'x');
      expect(await Fs.file(p('d/b.txt')).text(), 'b');
    });

    test('delete of the wrong kind throws (regression: silently kept it)', () async {
      await Fs.file(p('a.txt')).write('x');
      await Fs.dir(p('d')).create();
      await expectLater(Fs.dir(p('a.txt')).delete(), throwsA(isA<FileSystemException>()));
      await expectLater(Fs.file(p('d')).delete(), throwsA(isA<FileSystemException>()));
      await expectLater(Fs.link(p('a.txt')).delete(), throwsA(isA<FileSystemException>()));
      expect(await Fs.file(p('a.txt')).exists(), isTrue);
      expect(await Fs.dir(p('d')).exists(), isTrue);
    });

    test('a missing source carries the OS error (regression: empty OSError)', () async {
      final e = await Fs.file(p('missing.txt')).copy(p('x')).then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<PathNotFoundException>());
      expect((e as PathNotFoundException).osError?.errorCode, isNot(0));
      expect(e.osError?.message, isNotEmpty);
    });

    test('handles compare by normalized path (regression: a/./b != a/b)', () {
      expect(Fs.file(p('d/./a.txt')), Fs.file(p('d/a.txt')));
      expect(Fs.dir(p('d/x/..')).hashCode, Fs.dir(p('d')).hashCode);
      expect(Fs.dir(p('d/x/..')), Fs.dir(p('d')));
    });

    test('an unreadable file fails the copy as a catchable error', () async {
      if (Platform.isWindows) markTestSkipped('needs POSIX modes');
      for (var i = 0; i < 50; i++) {
        await Fs.file(p('src/d$i/f.txt')).write('x');
      }
      await Fs.file(p('src/zz')).write('secret');
      await Process.run('chmod', ['000', p('src/zz')]);
      addTearDown(() => Process.run('chmod', ['600', p('src/zz')]));
      await Fs.dir(p('dst')).create();
      await expectLater(Fs.dir(p('src')).copy(p('dst')), throwsA(isA<FileSystemException>()));
    });

    test('F16: dir copy keeps folder modes and mtimes', () async {
      await Fs.file(p('src/a.txt')).write('a');
      await Fs.dir(p('src')).copy(p('dst'));
      final srcStat = await Directory(p('src')).stat();
      final dstStat = await Directory(p('dst')).stat();
      expect(dstStat.modified.millisecondsSinceEpoch ~/ 1000, srcStat.modified.millisecondsSinceEpoch ~/ 1000);
      expect(dstStat.mode & 0xfff, srcStat.mode & 0xfff);
    });
  });

  group('File', () {
    test('text(or:) and bytes(or:) answer a missing file; json(or:) too', () async {
      final f = Fs.file(p('missing.txt'));
      expect(await f.text(or: 'none'), 'none');
      expect(await f.bytes(or: const [1]), [1]);
      await expectLater(f.text(), throwsA(isA<PathNotFoundException>()));
      await Fs.dir(p('d')).create();
      await expectLater(Fs.file(p('d')).text(or: ''), throwsA(isA<FileSystemException>()));
      await f.write('here');
      expect(await f.text(or: 'none'), 'here');
    });

    test('write replaces, append adds, size counts', () async {
      final f = Fs.file(p('a.txt'));
      await f.write('hi');
      expect(await f.text(), 'hi');
      await f.write('yo');
      expect(await f.text(), 'yo');
      await f.append('!');
      expect(await f.text(), 'yo!');
      expect(await f.size(), 3);
    });

    test('bytes go through Reader.of, the one Writer path', () async {
      await (Reader.of([1, 2, 3]) > Fs.file(p('b.bin')));
      expect(await Fs.file(p('b.bin')).bytes(), [1, 2, 3]);
    });

    test('streams in chunks and reads back', () async {
      final f = Fs.file(p('big.bin'));
      await (Reader.of(List.filled(200000, 7)) > f);
      var n = 0;
      await for (final _ in f.stream()) {
        n++;
      }
      expect(n, greaterThan(1));
      expect(await f.size(), 200000);
    });

    test('reading a missing file throws', () async {
      expect(Fs.file(p('missing')).text(), throwsA(isA<FileSystemException>()));
    });

    test('a 250-byte name writes, links and unpacks (the temp name fits)', () async {
      final name = 'a' * 250;
      await Fs.file(p(name)).write('x');
      expect(await Fs.file(p(name)).text(), 'x');
      await Fs.link(p('l' * 250)).create(p(name));
      await (Reader.of(utf8.encode('hello')) > Fs.file(p('b' * 230)));
      expect(await Fs.file(p('b' * 230)).text(), 'hello');
    });

    test('as a Writer it stores atomically', () async {
      await (_Mem('data') > Fs.file(p('out.txt')));
      expect(await Fs.file(p('out.txt')).text(), 'data');
    });

    test('a failed run keeps the old content and no temp file', () async {
      final f = Fs.file(p('keep.txt'));
      await f.write('OLD');
      await expectLater(_Boom() > f, throwsStateError);
      expect(await f.text(), 'OLD');
      final leftovers = await Directory(tmp.path).list().where((e) => e.path.contains('.tmp')).toList();
      expect(leftovers, isEmpty);
    });

    test('Future mirrors match', () async {
      final f = Future.value(Fs.file(p('m.txt')));
      await f.write('x');
      expect(await f.text(), 'x');
      expect(await f.size(), 1);
      expect(await f.exists(), isTrue);
      expect(await f.name(), 'm.txt');
      expect((await f.parent()).path(), tmp.path);
      await f.delete();
      expect(await f.exists(), isFalse);
    });

    test('overwriting a 0600 file never exposes the new bytes in a 0644 temp', () async {
      if (Platform.isWindows) markTestSkipped('needs POSIX modes');
      await Fs.file(p('token')).write('old');
      await Process.run('chmod', ['600', p('token')]);
      final modes = <int>[];
      Stream<List<int>> slow() async* {
        yield [1];
        for (final e in Directory(tmp.path).listSync()) {
          if (e.path.contains('.token.tmp')) modes.add(e.statSync().mode & 0x1ff);
        }
        yield [2];
      }

      await Fs.file(p('token')).consume(slow());
      expect(modes, [0x180]);
    });

    test('F7: writes keep the old mode and go through symlinks', () async {
      if (Platform.isWindows) markTestSkipped('needs POSIX modes');
      final f = Fs.file(p('run.sh'));
      await f.write('#!/bin/sh\necho hi\n');
      await Process.run('chmod', ['755', p('run.sh')]);
      await f.write('#!/bin/sh\necho new\n');
      expect((await FileStat.stat(p('run.sh'))).mode & 0x1ff, 0x1ff & 493);
      await Fs.link(p('link.sh')).create(p('run.sh'));
      await Fs.file(p('link.sh')).write('via link');
      expect(await FileSystemEntity.isLink(p('link.sh')), isTrue);
      expect(await Fs.file(p('run.sh')).text(), 'via link');
    });
  });

  group('temp, home, lock, modified', () {
    test('Fs.temp hands a fresh folder to the body and deletes it after, failures too', () async {
      String? kept;
      final n = await Fs.temp((d) async {
        kept = d.path();
        await d.file('x/y.txt').write('y');
        return 3;
      }, prefix: 'scope');
      expect(n, 3);
      expect(Directory(kept!).existsSync(), isFalse);
      await expectLater(
        Fs.temp((d) async {
          kept = d.path();
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(Directory(kept!).existsSync(), isFalse);
    });

    test('Fs.scriptDir is the script\'s folder, not the working directory', () async {
      final cwd = await Directory.systemTemp.createTemp('elsewhere');
      addTearDown(() => cwd.delete(recursive: true));
      final r = await runDart('''
import 'package:dart_toolkit/fs.dart';
Future<void> main() async {
  print(Fs.scriptDir().path());
  print(await Fs.scriptDir().file('main.dart').exists());
}
''', cwd: cwd.path);
      expect(r.stderr, isEmpty);
      final [dir, found, ...] = (r.stdout as String).split('\n');
      expect(found, 'true');
      expect(Directory(dir).resolveSymbolicLinksSync(), isNot(cwd.resolveSymbolicLinksSync()));
    });

    test('Fs.home is HOME', () {
      expect(Fs.home().path(), Platform.environment['HOME']);
    });

    test('modified() reads the mtime; a missing entry throws', () async {
      final f = await Fs.file(p('m.txt')).write('x');
      final when = DateTime(2020, 1, 2, 3, 4, 5);
      await io.File(f.path()).setLastModified(when);
      expect(await f.modified(), when);
      expect(await Fs.dir(tmp.path).modified(), isA<DateTime>());
      await expectLater(Fs.file(p('none')).modified(), throwsA(isA<PathNotFoundException>()));
    });

    test('lock: two holders in one process exclude each other too', () async {
      var inside = 0, most = 0;
      Future<int> hold(int n) async {
        most = max(most, ++inside);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        inside--;
        return n;
      }

      final lock = Fs.file(p('one.lock'));
      expect(await Future.wait([for (var i = 0; i < 3; i++) lock.lock(() => hold(i), wait: 5.seconds)]), [0, 1, 2]);
      expect(most, 1);
      final held = lock.lock(() => hold(9));
      await expectLater(
        lock.lock(() async => 0),
        throwsA(isA<FileSystemException>().having((e) => e.message, 'message', 'locked by this process')),
      );
      expect(await held, 9);
    });

    test('lock: one holder at a time across processes; wait retries; the body result returns', () async {
      final lock = p('run.lock');
      // A child script holds the lock until its stdin closes.
      final dir = await Directory.systemTemp.createTemp('lockchild');
      addTearDown(() => dir.delete(recursive: true));
      await io.File('${dir.path}/main.dart').writeAsString('''
import 'dart:io' as io;
import 'package:dart_toolkit/fs.dart';
Future<void> main(List<String> a) => Fs.file(a[0]).lock(() async {
  print('held');
  await io.stdin.drain<void>();
});
''');
      final holder = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${dir.path}/main.dart',
        lock,
      ]);
      await holder.stdout.transform(utf8.decoder).firstWhere((l) => l.contains('held'));
      await expectLater(
        Fs.file(lock).lock(() async => 1),
        throwsA(isA<FileSystemException>().having((e) => e.message, 'message', 'locked by another process')),
      );
      final waited = Fs.file(lock).lock(() async => 2, wait: 5.seconds);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await holder.stdin.close();
      expect(await waited, 2);
      expect(await holder.exitCode, 0);
    });
  });

  group('Dir', () {
    test('list keys entries by their path under the folder, however it was spelled', () async {
      for (final f in ['a/b', 'a-b', 'a.txt', 'z/y.txt']) {
        await Fs.file(p('l/$f')).write(f);
      }
      for (final spelled in [p('l'), '${p('l')}/', '${p('l')}/.']) {
        final d = Fs.dir(spelled);
        expect(
          [for (final e in await d.list(recursive: true)) e.path(from: d)],
          ['a', 'a/b', 'a-b', 'a.txt', 'z', 'z/y.txt'],
        );
        expect(
          [for (final e in await d.list(match: '**.txt')) e.path(from: d)],
          ['a.txt', 'z/y.txt'],
          reason: spelled,
        );
      }
    });

    test('watch reports files created or changed, not temp files or deletes', () async {
      final d = await Fs.dir(p('w')).create();
      final seen = <String>[];
      final sub = d.watch().listen((f) => seen.add(f.path(from: d)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await d.file('a.txt').write('one'); // atomic: a temp file, then a rename
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await d.file('a.txt').delete();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await sub.cancel();
      expect(seen.toSet(), {'a.txt'});
    });

    test('list(match:) filters by a glob; ** recurses, {a,b} picks', () async {
      for (final f in ['a.jpg', 'b.png', 'c.txt', 'x/d.jpg', 'x/y/e.png', 'x/f.gif']) {
        await Fs.file(p('shots/$f')).write(f);
      }
      final shots = Fs.dir(p('shots'));
      Future<List<String>> names(String glob) async => [
        for (final e in await shots.list(match: glob)) e.path(from: shots),
      ];
      expect(await names('*.{jpg,png}'), ['a.jpg', 'b.png']);
      expect(await names('**/*.{jpg,png}'), ['a.jpg', 'b.png', 'x/d.jpg', 'x/y/e.png']);
      expect(await names('x/?.gif'), isEmpty, reason: 'without ** the listing is one level');
      expect([for (final e in await shots.list(recursive: true, match: 'x/?.gif')) e.name()], ['f.gif']);
    });

    test('file/dir navigate without I/O', () {
      expect(Fs.dir(p('d')).file('a').path(), '${p('d')}/a');
      expect(Fs.dir(p('d')).dir('e').path(), '${p('d')}/e');
    });

    test('list returns typed children sorted by name', () async {
      await Fs.file(p('b.txt')).write('b');
      await Fs.file(p('a.txt')).write('a');
      await Fs.dir(p('sub')).create();
      final names = [for (final e in await Fs.dir(tmp.path).list()) e.name()];
      expect(names, ['a.txt', 'b.txt', 'sub']);
    });

    test('M8: recursive list is depth-first', () async {
      await Fs.file(p('o/a/b')).write('1');
      await Fs.file(p('o/a-b')).write('2');
      await Fs.file(p('o/a.c')).write('3');
      final names = [for (final e in await Fs.dir(p('o')).list(recursive: true)) e.path().substring(p('o').length + 1)];
      expect(names, ['a', 'a/b', 'a-b', 'a.c']);
    });

    test('recursive list never goes through links', () async {
      await Fs.file(p('r/a.txt')).write('a');
      await Fs.link(p('r/loop')).create(p('r'));
      final entries = await Fs.dir(p('r')).list(recursive: true);
      expect(entries.whereType<Link>().map((e) => e.name()), ['loop']);
      expect(entries.whereType<File>().map((e) => e.name()), ['a.txt']);
    });

    test('create is mkdir -p', () async {
      await Fs.dir(p('x/y/z')).create();
      await Fs.dir(p('x/y/z')).create();
      expect(await Fs.dir(p('x/y/z')).exists(), isTrue);
    });

    test('Future mirrors match', () async {
      final d = Future.value(Fs.dir(p('md')));
      await d.create();
      expect(await d.exists(), isTrue);
      expect((await d.file('a')).path(), '${p('md')}/a');
      expect(await d.list(), isEmpty);
    });
  });

  group('posix helpers', () {
    test('L14: a path starting with - is a path, not an option', () async {
      if (Platform.isWindows) markTestSkipped('needs POSIX modes');
      await Fs.file(p('w/-f')).write('x');
      await Fs.dir(p('w/-d')).create();
      await Fs.file(p('w/s/a')).write('a');
      await runInDir(
        p('w'),
        '''
import 'dart:io';
import 'dart:io' as io;
import 'package:dart_toolkit/src/posix.dart' as posix;
void check(bool ok, String what) { if (!ok) throw StateError(what); }''',
        '''
  await posix.chmod('-f', 493);
  await posix.chmodBatched({493: ['-d']});
  await posix.setDirMtime('-d', DateTime(2001, 2, 3, 4, 5, 6));
  check((await FileStat.stat('-f')).mode & 0x1ff == 493, 'chmod -f');
  check((await FileStat.stat('-d')).mode & 0x1ff == 493, 'chmod -d');
  check((await FileStat.stat('-d')).modified.year == 2001, 'mtime -d');
  check(await posix.copyTreeWithCp('s', '-t'), 'cp');
  check(FileSystemEntity.isFileSync('-t/a'), 'cp -t/a');''',
      );
    });

    test('chmod and touch failures throw (regression: exit codes ignored)', () async {
      if (Platform.isWindows) markTestSkipped('needs POSIX modes');
      await runInDir(
        tmp.path,
        '''
import 'dart:io';
import 'dart:io' as io;
import 'package:dart_toolkit/src/posix.dart' as posix;
Future<void> expectThrows(Future<void> f, String what) async {
  try { await f; } on FileSystemException { return; }
  throw StateError(what);
}''',
        '''
  await expectThrows(posix.chmod('nope', 420), 'chmod');
  await expectThrows(posix.chmodBatched({420: ['nope']}), 'chmodBatched');
  await expectThrows(posix.setDirMtime('no/such/dir/x', DateTime(2001)), 'touch');''',
      );
    });
  });

  group('Link', () {
    test('target/resolve/create', () async {
      await Fs.file(p('real.txt')).write('r');
      await Fs.link(p('lnk')).create(p('real.txt'));
      expect(await Fs.link(p('lnk')).target(), p('real.txt'));
      expect(await Fs.link(p('lnk')).resolve(), isA<File>());
      expect(await Fs.link(p('broken')).resolve(), isNull);
    });

    test('create replaces an existing link', () async {
      await Fs.file(p('a.txt')).write('a');
      await Fs.file(p('b.txt')).write('b');
      await Fs.link(p('lnk')).create(p('a.txt'));
      await Fs.link(p('lnk')).create(p('b.txt'));
      expect(await Fs.link(p('lnk')).target(), p('b.txt'));
    });

    test('F10: resolve returns a handle at the target; create over a file', () async {
      await Fs.file(p('real.txt')).write('r');
      await Fs.link(p('lnk')).create(p('real.txt'));
      final resolved = await Fs.link(p('lnk')).resolve();
      expect(resolved, isA<File>());
      // resolveSymbolicLinks may normalize the temp prefix (/var vs
      // /private/var on macOS): compare the tail.
      expect(resolved!.path(), endsWith('real.txt'));
      expect(await resolved.exists(), isTrue);
      // Atomic replace over a regular file (not "Cannot delete link").
      await Fs.file(p('plain.txt')).write('x');
      await Fs.link(p('plain.txt')).create(p('real.txt'));
      expect(await Fs.link(p('plain.txt')).target(), p('real.txt'));
      expect(await Fs.file(p('real.txt')).text(), 'r');
    });

    test('M10: a link to an ancestor can be moved and copied', () async {
      await Fs.dir(p('proj/sub')).create();
      await Fs.link(p('proj/up')).create(p('proj'));
      final moved = await Fs.link(p('proj/up')).move(p('proj/sub/up'));
      expect(moved.path(), p('proj/sub/up'));
      expect(await Fs.link(p('proj/up')).exists(), isFalse);
      await Fs.link(p('proj/sub/up')).copy(p('proj/sub/up2'));
      expect(await Fs.link(p('proj/sub/up2')).target(), p('proj'));
    });

    test('L11: copy replaces an existing file or link at the destination', () async {
      await Fs.file(p('real.txt')).write('r');
      await Fs.link(p('l1')).create(p('real.txt'));
      await Fs.file(p('plain.txt')).write('x');
      await Fs.link(p('l1')).copy(p('plain.txt'));
      expect(await Fs.link(p('plain.txt')).target(), p('real.txt'));
      await Fs.link(p('l1')).copy(p('plain.txt'));
      expect(await Fs.file(p('real.txt')).text(), 'r');
    });

    test('delete never takes the target', () async {
      await Fs.file(p('real.txt')).write('r');
      await Fs.link(p('lnk')).create(p('real.txt'));
      await Fs.link(p('lnk')).delete();
      expect(await Fs.file(p('real.txt')).exists(), isTrue);
    });

    test('Future mirrors match', () async {
      await Fs.file(p('t.txt')).write('t');
      final l = Future.value(Fs.link(p('ml')));
      await l.create(p('t.txt'));
      expect(await l.exists(), isTrue);
      expect(await l.target(), p('t.txt'));
      expect(await l.resolve(), isA<File>());
    });
  });
}

final class _Mem with Reader {
  _Mem(this._text);
  final String _text;
  @override
  Stream<List<int>> stream() => Stream.value(_text.codeUnits);
}

final class _Boom with Reader {
  @override
  Stream<List<int>> stream() async* {
    yield [1, 2, 3];
    throw StateError('reader blew up mid-write');
  }
}

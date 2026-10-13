import 'dart:io';

import 'package:dart_toolkit/fs.dart';
import 'package:test/test.dart';

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
    test('entry tells file, folder, link and nothing apart', () async {
      await Fs.file(p('a.txt')).write('x');
      await Fs.dir(p('sub')).create();
      await Fs.link(p('lnk')).create(p('a.txt'));
      expect(await Fs.entry(p('a.txt')), isA<File>());
      expect(await Fs.entry(p('sub')), isA<Dir>());
      expect(await Fs.entry(p('lnk')), isA<Link>());
      expect(await Fs.entry(p('missing')), isNull);
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

    test('F8: move into a non-empty folder throws and keeps the source',
        () async {
      await Fs.file(p('src/a.txt')).write('a');
      await Fs.file(p('dst/b.txt')).write('b');
      await expectLater(
        Fs.dir(p('src')).move(p('dst')),
        throwsA(isA<FileSystemException>()),
      );
      expect(await Fs.file(p('src/a.txt')).exists(), isTrue);
      expect(await Fs.file(p('dst/b.txt')).text(), 'b');
    });

    test('F9: copy into itself and missing sources fail before writing',
        () async {
      await Fs.file(p('src/a.txt')).write('a');
      await expectLater(
        Fs.dir(p('src')).copy(p('src/sub')),
        throwsArgumentError,
      );
      expect(await Fs.entry(p('src/sub')), isNull);
      await expectLater(
        Fs.file(p('missing.txt')).copy(p('dst.txt')),
        throwsA(isA<FileSystemException>()),
      );
      expect(await Fs.entry(p('dst.txt')), isNull);
    });

    test('F16: dir copy keeps folder modes and mtimes', () async {
      await Fs.file(p('src/a.txt')).write('a');
      await Fs.dir(p('src')).copy(p('dst'));
      final srcStat = await Directory(p('src')).stat();
      final dstStat = await Directory(p('dst')).stat();
      expect(
        dstStat.modified.millisecondsSinceEpoch ~/ 1000,
        srcStat.modified.millisecondsSinceEpoch ~/ 1000,
      );
      expect(dstStat.mode & 0xfff, srcStat.mode & 0xfff);
    });
  });

  group('File', () {
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

    test('write takes bytes; wrong type is ArgumentError', () async {
      await Fs.file(p('b.bin')).write([1, 2, 3]);
      expect(await Fs.file(p('b.bin')).bytes(), [1, 2, 3]);
      expect(Fs.file(p('b.bin')).write(42), throwsArgumentError);
    });

    test('streams in chunks and reads back', () async {
      final f = Fs.file(p('big.bin'));
      await f.write(List.filled(200000, 7));
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

    test('as a Writer it stores atomically', () async {
      await (_Mem('data') > Fs.file(p('out.txt')));
      expect(await Fs.file(p('out.txt')).text(), 'data');
    });

    test('a failed run keeps the old content and no temp file', () async {
      final f = Fs.file(p('keep.txt'));
      await f.write('OLD');
      await expectLater(_Boom() > f, throwsStateError);
      expect(await f.text(), 'OLD');
      final leftovers = await Directory(tmp.path)
          .list()
          .where((e) => e.path.contains('.tmp'))
          .toList();
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

  group('Dir', () {
    test('file/dir navigate without I/O', () {
      expect(Fs.dir(p('d')).file('a').path(), '${p('d')}/a');
      expect(Fs.dir(p('d')).dir('e').path(), '${p('d')}/e');
    });

    test('list returns typed children sorted by name', () async {
      await Fs.file(p('b.txt')).write('b');
      await Fs.file(p('a.txt')).write('a');
      await Fs.dir(p('sub')).create();
      final names = [
        for (final e in await Fs.dir(tmp.path).list()) e.name(),
      ];
      expect(names, ['a.txt', 'b.txt', 'sub']);
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

    test('F10: resolve returns a handle at the target; create over a file',
        () async {
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

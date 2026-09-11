import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

const _theme = Slot<String>('theme');
const _counter = Slot<int>('counter');
const _missing = Slot<String>('missing');
const _userId = Slot<String>('user_id');
const _visits = Slot<int>('visits');
const _since = Slot<DateTime>.coded(
  'since',
  read: _readTime,
  write: _writeTime,
);

DateTime? _readTime(Object? raw) =>
    raw is String ? DateTime.tryParse(raw) : null;
Object? _writeTime(DateTime value) => value.toIso8601String();

void main() {
  group('Console & Terminal Namespaces', () {
    test('the writer reports geometry', () {
      expect(system.console.writer.width, greaterThan(0));
      expect(system.console.writer.height, greaterThan(0));
    });

    test('writer renders tables, boxes and rules', () {
      final table = Table(headers: ['A', 'B'])..add(['1', '2']);
      expect(table.render(), contains('A'));
      expect(table.render(), contains('1'));

      expect(
        () => system.console.writer.write(table.render()),
        returnsNormally,
      );
      expect(
        () => system.console.writer.box('Hello World\nLine 2', title: 'Box'),
        returnsNormally,
      );
      expect(() => system.console.writer.rule('Test Rule'), returnsNormally);
    });

    test('table alignments pad by visible width', () {
      final table =
          Table(
              headers: ['Left', 'Right'],
              alignments: [ColumnAlign.left, ColumnAlign.right],
            )
            ..add.all(
              [
                ['a', '1'],
                ['bbb', '22'],
              ].seq,
            );
      final lines = table.render().split('\n');
      // Every rendered row is the same visible width.
      final widths = lines
          .where((l) => l.isNotEmpty)
          .map((line) => line.width)
          .toSet();
      expect(widths, hasLength(1));
    });

    test('logger.task runs its action behind a spinner', () async {
      final result = await system.console.logger.task(
        'Running quick task',
        () async => 42,
      );
      expect(result, equals(42));
    });

    test('logger respects its level filter', () {
      system.console.logger.level = LogLevel.warn;
      expect(() => system.console.logger.debug('silent'), returnsNormally);
      expect(() => system.console.logger.info('silent'), returnsNormally);
      expect(() => system.console.logger.warn('shown'), returnsNormally);
      system.console.logger.level = LogLevel.debug;
    });
  });

  group('Ansi Utilities', () {
    test('strip removes ANSI sequences', () {
      Ansi.enabled = true;
      final styled = 'Hello'.red().bold();
      expect(styled.plain, equals('Hello'));
      expect(styled.width, equals(5));
      expect(styled.plain, equals('Hello'));
      expect(styled.width, equals(5));
    });
  });

  group('io Domain', () {
    test('the path members complete the set', () {
      expect(io.path.cwd, isNotEmpty);
      expect(io.path.abs('x.txt'), equals(io.path.join(io.path.cwd, 'x.txt')));
      expect(
        io.path.rel(io.path.join(io.path.cwd, 'a', 'b.txt')),
        equals(io.path.join('a', 'b.txt')),
      );
      expect(
        io.path.rel('/tmp/one/two.txt', from: '/tmp'),
        equals(io.path.join('one', 'two.txt')),
      );
    });

    test('io.path.home and io.expand resolve what a shell would', () {
      expect(io.path.home, isNotEmpty);
      expect(io.path.expand('~'), equals(io.path.home));
      expect(
        io.path.expand(io.path.join('~', '.config', 'x')),
        equals(io.path.join(io.path.home, '.config', 'x')),
      );
      expect(
        io.path.expand('nested/~/x'),
        equals('nested/~/x'),
        reason: 'only a leading ~ expands, as in a shell',
      );

      final name = Platform.isWindows ? 'USERPROFILE' : 'HOME';
      expect(io.path.expand('\$$name/x'), equals('${io.path.home}/x'));
      expect(io.path.expand('\${$name}/x'), equals('${io.path.home}/x'));
      expect(
        io.path.expand('\$DT_DEFINITELY_NOT_SET/x'),
        equals('/x'),
        reason: 'an unset name expands to nothing, as in a shell',
      );
    });

    test('io.sanitize removes or replaces illegal characters', () {
      const raw = 'Key: "Box" / 20th * Edition? <Special> | Path\\';

      final ascii = io.path.sanitize(raw);
      for (final illegal in [':', '"', '/', r'\', '*', '?', '<', '>', '|']) {
        expect(ascii.contains(illegal), isFalse, reason: 'kept $illegal');
      }

      final wide = io.path.sanitize(raw, full: true);
      for (final replacement in ['：', '”', '／', '＼', '＊', '？', '＜', '＞', '｜']) {
        expect(wide, contains(replacement));
      }
    });

    test('io.write, io.has, io.read, io.copy, io.move are atomic', () async {
      final temp = io.dir.temp('toolkit_test_');
      try {
        final path = io.path.join(temp.path, 'sub', 'test.txt');
        io.write(path, 'Hello Dart Toolkit!');

        expect(io.has(path), isTrue);
        expect(io.read(path), equals('Hello Dart Toolkit!'));
        // The staging file is renamed into place, never left behind.
        expect(File('$path.part').existsSync(), isFalse);

        final copied = io.path.join(temp.path, 'sub', 'copy.txt');
        io.copy(path, copied);
        expect(io.read(copied), equals('Hello Dart Toolkit!'));

        final moved = io.path.join(temp.path, 'sub2', 'moved.txt');
        io.move(copied, moved);
        expect(io.has(copied), isFalse);
        expect(io.has(moved), isTrue);
      } finally {
        io.remove(temp.path);
      }
    });

    test('io.has treats a zero-length file as absent', () async {
      final temp = io.dir.temp('toolkit_empty_');
      try {
        final path = io.path.join(temp.path, 'empty.txt');
        File(path).writeAsStringSync('');
        expect(io.has(path), isFalse);
      } finally {
        io.remove(temp.path);
      }
    });

    test('io.similar is opt-in and matches loosely-named siblings', () async {
      final temp = io.dir.temp('toolkit_similar_');
      try {
        io.write(io.path.join(temp.path, 'thumb_cover.jpg'), 'x');
        final wanted = io.path.join(temp.path, 'cover.jpg');

        // `has` is the strict question; `similar` is the widened one, and
        // it is a separate member so a download is never silently skipped.
        expect(io.has(wanted), isFalse);
        expect(io.similar(wanted), isTrue);
      } finally {
        io.remove(temp.path);
      }
    });

    test('io path helpers join, base, name, ext, dir', () {
      final path = io.path.join('parent', 'sub', 'file.mp3');
      expect(path.replaceAll(r'\', '/'), equals('parent/sub/file.mp3'));
      expect(io.path.filename(path), equals('file.mp3'));
      expect(io.path.stem(path), equals('file'));
      expect(io.path.ext(path), equals('.mp3'));
      expect(io.path.dirname(path).replaceAll(r'\', '/'), equals('parent/sub'));
    });

    test('io.dump writes JSON and format.json reads it back', () async {
      final temp = io.dir.temp('toolkit_json_');
      try {
        final path = io.path.join(temp.path, 'data.json');
        // dump returns a Future<File> that must be awaited, so the bytes are
        // on disk before the next read.
        final file = io.dump(path, {'hello': 'world', 'count': 42});
        expect(io.exists(file.path), isTrue);

        final data = await format.json.read(path);
        expect(data.text('hello'), equals('world'));
        expect(data.number('count'), equals(42));

        final compact = io.path.join(temp.path, 'compact.json');
        io.dump(compact, {'a': 1}, pretty: false);
        expect(io.read(compact), equals('{"a":1}'));
      } finally {
        io.remove(temp.path);
      }
    });

    test('io.save writes bytes, io.bytes reads them', () async {
      final temp = io.dir.temp('toolkit_bytes_');
      try {
        final path = io.path.join(temp.path, 'blob.bin');
        io.bytes.write(path, [1, 2, 3, 4]);
        expect(io.bytes(path), equals([1, 2, 3, 4]));
      } finally {
        io.remove(temp.path);
      }
    });

    test('io.lines, io.hash, io.stat, io.find, io.sweep', () async {
      final temp = io.dir.temp('toolkit_meta_');
      try {
        final path = io.path.join(temp.path, 'lines.txt');
        io.write(path, 'one\ntwo\nthree');

        expect(
          io.lines(path).collect(.list()),
          equals(['one', 'two', 'three']),
        );
        expect(io.hash(path).length, equals(64));
        expect(io.hash(path, Algo.md5).length, equals(32));
        expect(io.stat(path)!.size, greaterThan(0));

        expect(
          io.dir.walk(temp.path, only: .file).collect(.count()),
          equals(1),
        );
        expect(
          io.dir.walk(temp.path, only: .file, match: '*.txt').collect(.count()),
          equals(1),
        );
        expect(io.dir.sweep(temp.path, match: '*.txt'), equals(1));
        expect(io.has(path), isFalse);
      } finally {
        io.remove(temp.path);
      }
    });

    test('io.async mirrors io: read, bytes, json, hash, stat', () async {
      final temp = io.dir.temp('toolkit_async_');
      try {
        final txtPath = io.path.join(temp.path, 'sample.txt');
        io.write(txtPath, 'async content');
        expect(await io.async.read(txtPath), equals('async content'));
        expect(
          await io.async.bytes(txtPath),
          equals(utf8.encode('async content')),
        );
        expect((await io.async.hash(txtPath)).length, equals(64));
        expect((await io.async.stat(txtPath))!.size, greaterThan(0));

        final jsonPath = io.path.join(temp.path, 'data.json');
        io.dump(jsonPath, {'key': 'val'});
        final decoded = await format.json.read(jsonPath);
        expect(decoded.text('key'), equals('val'));
      } finally {
        io.remove(temp.path);
      }
    });

    test('io directory copy, move, and single-file remove', () async {
      final temp = io.dir.temp('toolkit_dir_ops_');
      try {
        final srcDir = io.path.join(temp.path, 'src');
        final f1 = io.path.join(srcDir, 'a.txt');
        final f2 = io.path.join(srcDir, 'nested', 'b.txt');
        io.write(f1, 'file 1');
        io.write(f2, 'file 2');

        // Directory copy
        final destDir = io.path.join(temp.path, 'dest');
        io.copy(srcDir, destDir);
        expect(io.read(io.path.join(destDir, 'a.txt')), equals('file 1'));
        expect(
          io.read(io.path.join(destDir, 'nested', 'b.txt')),
          equals('file 2'),
        );

        // Directory move
        final movedDir = io.path.join(temp.path, 'moved');
        io.move(destDir, movedDir);
        expect(Directory(destDir).existsSync(), isFalse);
        expect(io.read(io.path.join(movedDir, 'a.txt')), equals('file 1'));

        // Single entity remove
        expect(io.remove(io.path.join(movedDir, 'a.txt')), isTrue);
        expect(io.has(io.path.join(movedDir, 'a.txt')), isFalse);
        expect(
          io.remove(io.path.join(movedDir, 'a.txt')),
          isFalse,
        ); // already gone
        expect(io.remove(movedDir), isTrue); // directory removal
        expect(Directory(movedDir).existsSync(), isFalse);
      } finally {
        io.remove(temp.path);
      }
    });
  });

  group('system Domain', () {
    test('system.os is one record of facts, not five members', () {
      final machine = system.os;
      expect(machine.name, equals(Platform.operatingSystem));
      expect(machine.cpus, greaterThan(0));
      expect(machine.host, isNotNull);
      expect(machine.user, isNotNull);
      expect(
        [system.windows, system.macos, system.linux].where((f) => f).length,
        lessThanOrEqualTo(1),
      );
    });

    test('system.which finds dart', () {
      final dart = system.which('dart');
      expect(dart, isNotNull);
      expect(File(dart!).existsSync(), isTrue);
    });

    test('system.run captures output', () async {
      final result = await system.run('dart', ['--version']);
      expect(result.code, equals(0));
      expect(result.ok, isTrue);
      expect(result.out.isNotEmpty || result.err.isNotEmpty, isTrue);
    });

    test('system.run kills a process that outruns its timeout', () async {
      final result = await system.run('dart', [
        'run',
        '--',
        '-e',
        'x',
      ], timeout: const Duration(milliseconds: 300));
      // Either the command failed outright or the timeout fired; both settle
      // without hanging, which is what this guards.
      expect(result.ok, isFalse);
    });

    test('system exposes platform predicates', () {
      expect(system.windows, equals(Platform.isWindows));
      expect(system.macos, equals(Platform.isMacOS));
      expect(system.linux, equals(Platform.isLinux));
    });

    test('a script that writes a file still exits on its own', () async {
      // Regression: tracking a `.part` file installs a SIGINT watcher, and a
      // live watcher keeps the isolate alive. Writing must release it.
      final dir = Directory('.dart_tool/toolkit_exit_test')
        ..createSync(recursive: true);
      try {
        final script = io.path.join(dir.path, 'writer.dart');
        final output = io.path.join(dir.path, 'out.txt');
        io.write(script, '''
import 'package:dart_toolkit/dart_toolkit.dart';
void main() async {
  io.write(r'$output', 'hi');
  print('wrote');
}
''');
        final result = await system.run('dart', [
          'run',
          script,
        ], timeout: const Duration(seconds: 40));

        expect(
          result.code,
          equals(0),
          reason: 'script hung or failed: ${result.err}',
        );
        expect(result.out, contains('wrote'));
        expect(io.read(output), equals('hi'));
      } finally {
        io.remove(dir.path);
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('concurrent Domain', () {
    test('concurrent.run executes tasks concurrently', () async {
      final processed = await concurrent.run([1, 2, 3, 4, 5].seq, (n) async {
        await util.time.wait(10.ms);
        return n * 10;
      }, size: 2);
      expect(processed.collect(.list()), containsAll([10, 20, 30, 40, 50]));
    });

    test(
      'concurrent.run preserves input order despite varying durations',
      () async {
        final results = await concurrent.run([30, 10, 20, 5].seq, (n) async {
          await util.time.wait(n.ms);
          return 'item-$n';
        }, size: 4);
        expect(
          results.collect(.list()),
          equals(['item-30', 'item-10', 'item-20', 'item-5']),
        );
      },
    );

    test('Pool.settle returns per-item results without throwing', () async {
      final pool = Pool<int>(size: 2);
      final outcomes = await pool.settle([1, 2, 3].seq, (n) async {
        if (n == 2) throw Exception('fail on 2');
        return n * 10;
      });

      expect(outcomes.collect(.count()), equals(3));
      // Matching is the point: `value` is non-nullable inside Done, and the
      // error only exists inside Broke.
      expect(outcomes.collect(.at(0))!, isA<Done<int>>());
      expect((outcomes.collect(.at(0))! as Done<int>).value, equals(10));
      expect(outcomes.collect(.at(1))!, isA<Broke<int>>());
      expect(
        (outcomes.collect(.at(1))! as Broke<int>).error.toString(),
        contains('fail on 2'),
      );
      expect((outcomes.collect(.at(1))! as Broke<int>).stack, isNotNull);
      expect(outcomes.collect(.at(2))!.ok, isTrue);
      expect(outcomes.collect(.at(2))!.value, equals(30));

      final saved = [
        for (final outcome in outcomes.collect(.list()))
          switch (outcome) {
            Done(:final value) => 'ok:$value',
            Broke(:final error) => 'bad:${error is Exception}',
          },
      ];
      expect(saved, ['ok:10', 'bad:true', 'ok:30']);
    });

    test(
      'PoolFailure preserves partial results when collecting errors',
      () async {
        final pool = Pool<int>(size: 2);
        pool.on.error((err, stack, item) {}); // enables collecting mode

        try {
          await pool.run([1, 2, 3].seq, (n) async {
            if (n == 2) throw Exception('fail on 2');
            return n * 10;
          });
          fail('Should have thrown PoolFailure');
        } on PoolFailure<int, int> catch (e) {
          // One outcome per item, aligned with `items`.
          final outcomes = e.outcomes.collect(.list());
          expect(outcomes.length, equals(3));
          expect(outcomes[0], isA<Done<int>>());
          expect(outcomes[1], isA<Broke<int>>());
          expect(outcomes[2], isA<Done<int>>());
          expect(outcomes.map((o) => o.value), [10, null, 30]);
          expect(e.items.collect(.list()), [1, 2, 3]);
          expect(e.broken, 1);
        }
      },
    );

    test('flow.run yields results in completion order', () async {
      // 50ms task vs 10ms task: 10ms task completes first
      final items = [50, 10];
      final streamed = await items.flow
          .transform(
            .map.async(
              (delay) async {
                await util.time.wait(delay.ms);
                return 'done-$delay';
              },
              size: 2,
              ordered: false,
            ),
          )
          .collect(.list());

      expect(streamed, equals(['done-10', 'done-50']));
    });

    test('map.async yields in input order by default', () async {
      final streamed = await [50, 10].flow
          .transform(
            .map.async((delay) async {
              await util.time.wait(delay.ms);
              return 'done-$delay';
            }, size: 2),
          )
          .collect(.list());

      expect(streamed, equals(['done-50', 'done-10']));
    });

    test('map.async bounds how many workers are in flight', () async {
      var live = 0;
      var peak = 0;
      await List.generate(12, (i) => i).flow
          .transform(
            .map.async((i) async {
              live++;
              if (live > peak) peak = live;
              await util.time.wait(5.ms);
              live--;
              return i;
            }, size: 3),
          )
          .collect(.count());

      expect(peak, equals(3));
    });

    test('map.async takes a source it never has to hold', () async {
      var produced = 0;
      Stream<int> endless() async* {
        var next = 0;
        while (true) {
          produced++;
          yield next++;
        }
      }

      final first = await endless().flow
          .transform(.map.async((n) async => n, size: 2))
          .collect(.first());

      expect(first, isZero);
      // Two in flight, and then the terminal cancelled the source.
      expect(produced, lessThan(5));
    });

    test('map.async propagates the first failure', () async {
      await expectLater(
        [1, 2, 3].flow
            .transform(
              .map.async((n) async {
                if (n == 2) throw StateError('boom');
                return n;
              }, size: 2),
            )
            .collect(.list()),
        throwsStateError,
      );
    });

    test('Semaphore bounds how many run at once', () async {
      final sem = concurrent.semaphore(2);
      var running = 0;
      var maxRunning = 0;

      await Future.wait([
        for (var i = 0; i < 5; i++)
          sem.guard(() async {
            running++;
            if (running > maxRunning) maxRunning = running;
            await util.time.wait(10.ms);
            running--;
          }),
      ]);

      expect(maxRunning, lessThanOrEqualTo(2));

      // `concurrent.mutex()` was a whole exported type for Semaphore(1).
      final lock = concurrent.semaphore(1);
      var count = 0;
      await Future.wait([
        for (var i = 0; i < 5; i++)
          lock.guard(() async {
            final cur = count;
            await util.time.wait(5.ms);
            count = cur + 1;
          }),
      ]);
      expect(count, equals(5));
    });

    test('concurrent.retry retries on failure with backoff', () async {
      var attempts = 0;
      final result = await concurrent.retry(
        () async {
          attempts++;
          if (attempts < 3) throw StateError('fail $attempts');
          return 'success';
        },
        retries: 2,
        backoff: 5.ms,
      );

      expect(result, equals('success'));
      expect(attempts, equals(3));

      var failAttempts = 0;
      await expectLater(
        () => concurrent.retry(
          () async {
            failAttempts++;
            throw Exception('always fail');
          },
          retries: 1,
          backoff: 2.ms,
        ),
        throwsException,
      );
      expect(failAttempts, equals(2));
    });
  });

  group('cli Sub-namespace', () {
    test('parse reads flags, options and positionals', () {
      final force = cli.flag('force');
      final port = cli.number('p');
      final name = cli.option('name');
      cli.parse(['--force', '-p', '8', '--name=test', 'file1', 'file2']);

      expect(force(), isTrue);
      expect(port(), equals(8));
      expect(name(), equals('test'));
      expect(cli.args, equals(['file1', 'file2']));
    });

    test('list collects repeats and a flag reads its negative form', () {
      final tags = cli.list('tag');
      final compress = cli.flag('compress', def: true);
      final cache = cli.flag('cache');
      cli.parse(['--tag', 'a', '--tag', 'b', '--no-compress', '--cache']);

      expect(tags(), equals(['a', 'b']));
      expect(compress.negated(), isTrue);
      // --no-compress must not report the positive flag as present.
      expect(compress.given(), isFalse);
      expect(compress(), isFalse);
      expect(cache(), isTrue);
    });

    test(
      'handles negative values, bare -- separator, and consecutive flags',
      () {
        final cli = Cli(['--offset', '-5', '--', 'file.txt']);
        expect(cli.number('offset')(), equals(-5));
        expect(cli.args, equals(['file.txt']));
        // The negative number was the option's value, not a switch of its own.
        expect(cli.switches.keys, ['offset']);

        final flags = Cli(['--flag', '--other']);
        expect(flags.flag('flag')(), isTrue);
        expect(flags.flag('other')(), isTrue);
        expect(flags.args, isEmpty);
      },
    );

    // `rest` was `args` without its first element and `subcommand` was the
    // only caller that wanted that; `command` plus `args` covers branching by
    // hand, and inside a handler `cli.run` dispatched to, `args` already has
    // the command names taken off.
    test('command reads the first positional, args holds them all', () {
      final cli = Cli(['build', '--prod', 'main.dart', 'output.bin']);
      final prod = cli.flag('prod');
      expect(cli.command, equals('build'));
      expect(cli.args, equals(['build', 'main.dart', 'output.bin']));
      expect(prod(), isTrue);

      // Branching by hand is an `if`, which is what `subcommand` wrapped.
      var executed = false;
      if (cli.command == 'build') executed = true;
      expect(executed, isTrue);
      expect(cli.command == 'test', isFalse);

      final noCmd = Cli(['--flag']);
      expect(noCmd.command, isNull);
      expect(noCmd.args, isEmpty);
    });

    test('declarations, require validation, and usage', () {
      final cli = Cli(['--output', 'dist'])
        ..flag('verbose', alias: 'v', desc: 'Enable verbose logging')
        ..option('output', alias: 'o', desc: 'Output directory', required: true)
        ..number(
          'port',
          alias: 'p',
          desc: 'Server port',
          def: 8080,
          required: true,
        );

      // 'port' is required but declares a default, which supplies it.
      expect(() => cli.require(), returnsNormally);
      expect(() => cli.require(['output']), returnsNormally);

      // Required with nothing to fall back on still throws, and names itself.
      final bare = Cli(const <String>[])
        ..option('output', alias: 'o', required: true);
      expect(
        () => bare.require(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('--output'),
          ),
        ),
      );

      final validCli = Cli(['--output', 'dist', '-p', '3000'])
        ..option('output', alias: 'o', desc: 'Output directory', required: true)
        ..number(
          'port',
          alias: 'p',
          desc: 'Server port',
          def: 8080,
          required: true,
        );
      expect(() => validCli.require(), returnsNormally);

      final help = validCli.usage(
        syntax: 'myapp [options]',
        desc: 'My application description',
      );
      expect(help, contains('Usage: myapp [options]'));
      expect(help, contains('My application description'));
      expect(help, contains('--output <value>'));
      expect(help, contains('(required)'));
      expect(help, contains('[default: 8080]'));
    });
  });

  group('system.env Sub-namespace', () {
    test('env reads and casts through a single typed getter', () {
      system.env.clear();
      system.env.set('APP_PORT', '9000');
      system.env.set('APP_DEBUG', 'true');
      system.env.set('APP_RATE', '3.14');
      system.env.set('APP_NAME', 'DartToolkit');

      expect(system.env.has('APP_PORT'), isTrue);
      expect(system.env.get('APP_NAME', ''), equals('DartToolkit'));
      expect(system.env.get('APP_PORT', 0), equals(9000));
      expect(system.env.get('APP_DEBUG', false), isTrue);
      expect(system.env.get('APP_RATE', 0.0), closeTo(3.14, 0.001));
      expect(system.env.get('NON_EXISTENT', 'default'), equals('default'));
      expect(system.env.get('NON_EXISTENT', 7), equals(7));

      system.env.delete('APP_NAME');
      expect(system.env.has('APP_NAME'), isFalse);
      expect(system.env.map()['APP_PORT'], equals('9000'));

      system.env.clear();
      expect(system.env.has('APP_PORT'), isFalse);
    });

    test('env.load reads a .env file with comments and quotes', () async {
      final temp = io.dir.temp('env_test_');
      try {
        final path = io.path.join(temp.path, '.env');
        io.write(path, '''
          # This is a comment
          export DB_HOST=localhost
          DB_PORT=5432
          DB_NAME="my_db"
          DB_SSL=false
          API_KEY='secret_123' # inline comment
        ''');

        system.env.clear();
        expect(system.env.load(path), isTrue);
        expect(
          system.env.load(io.path.join(temp.path, 'missing.env')),
          isFalse,
        );

        expect(system.env.get('DB_HOST', ''), equals('localhost'));
        expect(system.env.get('DB_PORT', 0), equals(5432));
        expect(system.env.get('DB_NAME', ''), equals('my_db'));
        expect(system.env.get('DB_SSL', true), isFalse);
        expect(system.env.get('API_KEY', ''), equals('secret_123'));
      } finally {
        io.remove(temp.path);
        system.env.clear();
      }
    });
  });

  group('net.http Namespace', () {
    test('Reply exposes ok, body, json, DOM querying and save', () async {
      final res = Reply(
        url: 'https://example.com/item/1'.url,
        status: 200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
        bytes: utf8.encode('''
          <html><body>
            <h1>Welcome</h1>
            <a href="/sub/page">Link</a>
            <img src="/images/pic.png" />
          </body></html>
        '''),
      );

      expect(res.ok, isTrue);
      expect(res.body, contains('Welcome'));
      expect(res.parse(format.html).$('h1').text, equals('Welcome'));
      expect(res.parse(format.html).$('a').attr('href'), equals('/sub/page'));
      expect(
        res.parse(format.html).$('img').attr('src'),
        equals('/images/pic.png'),
      );
      expect(
        res.parse(format.html).lines.collect(.list()),
        contains('Welcome'),
      );

      final temp = io.dir.temp('http_test_');
      try {
        final saved = await res.save(io.path.join(temp.path, 'page.html'));
        expect(io.read(saved.path), contains('Welcome'));
      } finally {
        io.remove(temp.path);
      }
    });

    test('net.http talks to a local server', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        switch (req.uri.path) {
          case '/hello':
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'message': 'hello world'}));
          case '/echo':
            final body = await utf8.decodeStream(req);
            req.response
              ..statusCode = 201
              ..write('Echo: $body');
          default:
            req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final root = 'http://${server.address.host}:${server.port}';
      try {
        final res = await net.http.send(.get, '$root/hello'.url);
        expect(res.ok, isTrue);
        expect(
          (res.parse(format.json).raw as Map<String, Object?>)['message'],
          'hello world',
        );
        // json is cached, so a second read is free and consistent.
        expect(res.parse(format.json).raw, same(res.parse(format.json).raw));

        final posted = await net.http.send(
          .post,
          '$root/echo'.url,
          body: const Body.text('toolkit'),
        );
        expect(posted.status, equals(201));
        expect(posted.body, equals('Echo: toolkit'));

        final form = await net.http.send(
          .post,
          '$root/echo'.url,
          body: const Body.form({'a': '1'}),
        );
        expect(form.body, equals('Echo: a=1'));

        final client = Fetcher(timeout: const Duration(seconds: 5));
        expect((await client.send(.get, '$root/hello'.url)).ok, isTrue);
        await client.close();
      } finally {
        await server.close(force: true);
      }
    });

    test('Reply detects charset and handles decode and redirects', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        switch (req.uri.path) {
          case '/latin1':
            req.response.headers.set(
              'content-type',
              'text/html; charset=iso-8859-1',
            );
            req.response.add(latin1.encode('<p>café</p>'));
            break;
          case '/meta-sniff':
            req.response.headers.set('content-type', 'text/html');
            req.response.add(
              latin1.encode(
                '<html><head><meta charset="iso-8859-1"></head><body><p>résumé</p></body></html>',
              ),
            );
            break;
          case '/not-json':
            req.response.headers.set('content-type', 'text/plain');
            req.response.write('plain text not json');
            break;
          case '/redirect-src':
            req.response.redirect(
              Uri.parse(
                'http://${server.address.host}:${server.port}/redirect-dst',
              ),
            );
            return;
          case '/redirect-dst':
            req.response.write('arrived at dest');
            break;
          default:
            req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final root = 'http://${server.address.host}:${server.port}';
      try {
        // Charset from header
        final latin1Res = await net.http.send(.get, '$root/latin1'.url);
        expect(latin1Res.type, equals('text/html'));
        expect(latin1Res.charset, equals('iso-8859-1'));
        expect(latin1Res.body, contains('café'));

        // Meta sniff
        final metaRes = await net.http.send(.get, '$root/meta-sniff'.url);
        expect(metaRes.charset, equals('iso-8859-1'));
        expect(metaRes.body, contains('résumé'));

        // decode fallback
        final notJsonRes = await net.http.send(.get, '$root/not-json'.url);
        expect(
          notJsonRes.parse(format.json).raw ?? ({'fallback': true}),
          equals({'fallback': true}),
        );

        // Redirect URL tracking
        final redirectRes = await net.http.send(
          .get,
          '$root/redirect-src'.url,
          redirects: 3,
        );
        expect(redirectRes.fetch.url.toString(), equals('$root/redirect-src'));
        expect(redirectRes.url.toString(), equals('$root/redirect-dst'));
        expect(redirectRes.body, equals('arrived at dest'));
      } finally {
        await server.close(force: true);
      }
    });

    test('Reply.extract extracts structured data declaratively', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response
          ..headers.contentType = ContentType.html
          ..write('''
            <html>
              <body>
                <h1>Product Catalog</h1>
                <a class="canonical" href="https://example.com/products">Canonical</a>
                <ul class="categories">
                  <li>Electronics</li>
                  <li>Books</li>
                </ul>
                <div class="product">
                  <span class="name">Laptop</span>
                  <span class="price">\$999</span>
                  <a href="/items/1">Buy</a>
                </div>
                <div class="product">
                  <span class="name">Phone</span>
                  <span class="price">\$499</span>
                  <a href="/items/2">Buy</a>
                </div>
              </body>
            </html>
          ''');
        await req.response.close();
      });

      try {
        final res = await net.http.send(
          .get,
          'http://${server.address.host}:${server.port}'.url,
        );
        final extracted = res.parse(format.html).extract({
          'title': 'h1',
          'canonical': 'a.canonical@href',
          'categories': ['ul.categories > li'],
          'items': [
            '.product',
            {'name': '.name', 'price': '.price', 'url': 'a@href'},
          ],
        });

        expect(extracted['title'], equals('Product Catalog'));
        expect(extracted['canonical'], equals('https://example.com/products'));
        expect(extracted['categories'], equals(['Electronics', 'Books']));
        expect(
          extracted['items'],
          equals([
            {'name': 'Laptop', 'price': '\$999', 'url': '/items/1'},
            {'name': 'Phone', 'price': '\$499', 'url': '/items/2'},
          ]),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test(
      'Fetcher session persistence manages cookies across fetches',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          if (req.uri.path == '/login') {
            req.response.headers.set(
              'set-cookie',
              'session_id=secret123; Path=/',
            );
            req.response.write('logged in');
          } else if (req.uri.path == '/profile') {
            final cookie = req.headers.value('cookie');
            req.response.write('cookie received: $cookie');
          }
          await req.response.close();
        });

        final root = 'http://${server.address.host}:${server.port}';
        final client = Fetcher(session: true);
        try {
          final loginRes = await client.send(.get, '$root/login'.url);
          expect(loginRes.body, equals('logged in'));
          expect(client.jar?.cookies.collect(.count()), equals(1));
          expect(
            client.jar?.cookies.collect(.first())!.name,
            equals('session_id'),
          );

          // Next request sends cookie
          final profileRes = await client.send(.get, '$root/profile'.url);
          expect(profileRes.body, contains('session_id=secret123'));
        } finally {
          await client.close();
          await server.close(force: true);
        }
      },
    );

    test('Fetcher supports proxy configuration', () {
      final client = Fetcher(proxy: '127.0.0.1:8888');
      expect(client.proxy, equals('127.0.0.1:8888'));
      client.close();
    });

    test('net.http.download and sync write files', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response
          ..statusCode = 200
          ..write('body of ${req.uri.path}');
        await req.response.close();
      });

      final root = 'http://${server.address.host}:${server.port}';
      final temp = io.dir.temp('download_test_');
      try {
        final one = io.path.join(temp.path, 'one.txt');
        await net.http.download('$root/one'.url, one);
        expect(io.read(one), equals('body of /one'));

        await net.http.sync({
          io.path.join(temp.path, 'a.txt'): '$root/a'.url,
          io.path.join(temp.path, 'b.txt'): '$root/b'.url,
        });
        expect(io.read(io.path.join(temp.path, 'a.txt')), equals('body of /a'));
        expect(io.read(io.path.join(temp.path, 'b.txt')), equals('body of /b'));
      } finally {
        io.remove(temp.path);
        await server.close(force: true);
      }
    });

    test(
      'a failing download reports the failure instead of swallowing it',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          req.response.statusCode = 404;
          await req.response.close();
        });

        final root = 'http://${server.address.host}:${server.port}';
        final temp = io.dir.temp('download_fail_');
        final client = Fetcher(retries: 0);
        try {
          await expectLater(
            client.download(
              '$root/missing'.url,
              io.path.join(temp.path, 'x.txt'),
            ),
            throwsA(isA<HttpException>()),
          );
          expect(io.has(io.path.join(temp.path, 'x.txt')), isFalse);
        } finally {
          await client.close();
          io.remove(temp.path);
          await server.close(force: true);
        }
      },
    );
  });

  group('format.csv and io.csv', () {
    test('parse and format handle quotes and delimiters', () {
      const input =
          'id,name,role\n1,"Alice, Chief",admin\n2,"Bob ""The Builder""",user';
      final sheet = format.csv.parse(input);

      expect(sheet.headers.collect(.list()), equals(['id', 'name', 'role']));
      expect(sheet.count, equals(2));
      expect(sheet.rows.collect(.at(0))![1], equals('Alice, Chief'));
      expect(sheet.rows.collect(.at(1))![1], equals('Bob "The Builder"'));

      final formatted = format.csv.format(
        [
          {'id': 1, 'name': 'Alice'},
          {'id': 2, 'name': 'Bob'},
        ].seq,
      );
      expect(formatted, contains('id,name'));
      expect(formatted, contains('1,Alice'));
    });

    test('one cursor carries both shapes, and read comes free', () async {
      final temp = io.dir.temp('csv_test_');
      try {
        final path = io.path.join(temp.path, 'test.csv');
        io.csv.write(
          path,
          [
            {'fruit': 'Apple', 'price': '1.50'},
            {'fruit': 'Banana', 'price': '0.75'},
          ].seq,
        );

        final sheet = await format.csv.read(path);
        expect(sheet.maps.collect(.count()), equals(2));
        expect(sheet.maps.collect(.first())?['fruit'], equals('Apple'));
        expect(sheet.maps.collect(.first())?['price'], equals('1.50'));

        expect(sheet.headers.collect(.list()), equals(['fruit', 'price']));
        expect(sheet.rows.collect(.count()), equals(2));
        expect(
          sheet.column('fruit').collect(.list()),
          equals(['Apple', 'Banana']),
        );
        expect(sheet.column('nope').collect(.empty()), isTrue);

        // A file that is not there reads as the empty cursor, like every
        // other codec's read.
        final missing = await format.csv.read(
          io.path.join(temp.path, 'missing.csv'),
        );
        expect(missing.empty, isTrue);
      } finally {
        io.remove(temp.path);
      }
    });

    test('cells renders a grid, and io.write puts it on disk', () async {
      final temp = io.dir.temp('csv_dump_');
      try {
        final path = io.path.join(temp.path, 'grid.csv');
        io.write(
          path,
          format.csv.cells(
            [
              [1, 'a'],
              [2, 'b'],
            ].seq,
            headers: ['n', 'letter'],
          ),
        );
        final sheet = await format.csv.read(path);
        expect(sheet.headers.collect(.list()), equals(['n', 'letter']));
        expect(
          sheet.rows.collect(.list()),
          equals([
            ['1', 'a'],
            ['2', 'b'],
          ]),
        );
      } finally {
        io.remove(temp.path);
      }
    });

    test(
      'io.csv.rows and records read rows without loading all into memory',
      () async {
        final temp = io.dir.temp('csv_stream_');
        try {
          final path = io.path.join(temp.path, 'stream.csv');
          io.write(
            path,
            'id,name\n1,"Alpha, 1"\n2,"Beta ""The Second"""\n3,Gamma\n',
          );

          final streamRows = await io.async.csv.rows(path).collect(.list());
          expect(streamRows.length, equals(4));
          expect(streamRows[0], equals(['id', 'name']));
          expect(streamRows[1], equals(['1', 'Alpha, 1']));
          expect(streamRows[2], equals(['2', 'Beta "The Second"']));
          expect(streamRows[3], equals(['3', 'Gamma']));

          final mapRows = await io.async.csv.records(path).collect(.list());
          expect(mapRows.length, equals(3));
          expect(mapRows[0]['id'], equals('1'));
          expect(mapRows[0]['name'], equals('Alpha, 1'));
          expect(mapRows[1]['name'], equals('Beta "The Second"'));
          expect(mapRows[2]['id'], equals('3'));

          // The typed pair: rows() yields cells, records() yields maps.
          expect(
            await io.async.csv.records(path).collect(.list()),
            equals(mapRows),
          );
        } finally {
          io.remove(temp.path);
        }
      },
    );
  });

  group('io.dictionary', () {
    test('an absent file reads as an empty dictionary', () {
      final temp = io.dir.temp('dict_absent_');
      try {
        final db = io.dictionary(io.path.join(temp.path, 'nothing.json'));
        expect(db.empty, isTrue);
        expect(db.count, equals(0));
      } finally {
        io.remove(temp.path);
      }
    });

    test('reads and writes through typed slots', () {
      final db = Dictionary<String, Object?>();
      db.write(_theme, 'dark');
      db.write(_counter, 42);

      expect(db.holds(_theme), isTrue);
      expect(db.read(_theme), equals('dark'));
      expect(db.read(_counter), equals(42));
      expect(db.read(_missing), isNull);
      // A slot whose value is not the shape it names reads as null, so a
      // document that moved on does not throw from a getter.
      expect(db.read(const Slot<int>('theme')), isNull);

      db.drop(_theme);
      expect(db.holds(_theme), isFalse);
    });

    test('a slot can carry a type JSON does not', () async {
      final temp = io.dir.temp('dict_coded_');
      try {
        final path = io.path.join(temp.path, 'coded.json');
        io.dictionary(path)
          ..write(_since, DateTime.utc(2026, 3, 1))
          ..dump(path);

        expect(
          (await format.json.read(path)).text('since'),
          equals('2026-03-01T00:00:00.000Z'),
        );
        expect(
          io.dictionary(path).read(_since),
          equals(DateTime.utc(2026, 3, 1)),
        );
      } finally {
        io.remove(temp.path);
      }
    });

    test('dump persists and io.dictionary reloads', () {
      final temp = io.dir.temp('dict_test_');
      try {
        final path = io.path.join(temp.path, 'cache.json');
        Dictionary<String, Object?>()
          ..write(_userId, 'user_101')
          ..write(_visits, 5)
          ..dump(path);
        expect(io.has(path), isTrue);

        final reopened = io.dictionary(path);
        expect(reopened.read(_userId), equals('user_101'));
        expect(reopened.read(_visits), equals(5));
        expect(reopened.count, equals(2));

        reopened.clear();
        expect(reopened.empty, isTrue);
      } finally {
        io.remove(temp.path);
      }
    });

    test('dump writes a sequence as a JSON array', () async {
      final temp = io.dir.temp('dict_dump_');
      try {
        final path = io.path.join(temp.path, 'rows.json');
        [1, 2, 3].seq.dump(path);
        expect((await format.json.read(path)).raw, equals([1, 2, 3]));

        final objects = io.path.join(temp.path, 'by-host.json');
        Dictionary<String, int>(const {'a.com': 2}).dump(objects);
        expect((await format.json.read(objects)).raw, equals({'a.com': 2}));
      } finally {
        io.remove(temp.path);
      }
    });

    test(
      'a file that is not a JSON object is a broken file, not an empty one',
      () {
        final temp = io.dir.temp('dict_broken_');
        try {
          final path = io.path.join(temp.path, 'broken.json');
          io.write(path, '[1, 2, 3]');
          expect(() => io.dictionary(path), throwsFormatException);
        } finally {
          io.remove(temp.path);
        }
      },
    );
  });

  group('util Domain', () {
    test('util.time waits, stamps and formats', () async {
      final clock = (Stopwatch()..start());
      await util.time.wait(20.ms);
      clock.stop();
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(10));

      expect(RegExp(r'^\d{8}_\d{6}$').hasMatch(util.time.stamp()), isTrue);
      expect(DateTime.now().toUtc().toIso8601String(), contains('T'));
      expect(DateTime.now().toUtc().toIso8601String(), endsWith('Z'));
      expect(DateTime.now().millisecondsSinceEpoch, greaterThan(0));

      expect(util.time.format(45.s), equals('00:45'));
      expect(
        util.time.format(const Duration(minutes: 3, seconds: 12)),
        '03:12',
      );
      expect(
        util.time.format(const Duration(hours: 2, minutes: 15, seconds: 30)),
        equals('02:15:30'),
      );
    });

    test('util.time.ago describes elapsed time coarsely', () {
      final now = DateTime(2026, 6, 1, 12);
      expect(util.time.ago(now, now), equals('just now'));
      expect(
        util.time.ago(now.subtract(const Duration(minutes: 5)), now),
        equals('5m ago'),
      );
      expect(
        util.time.ago(now.subtract(const Duration(hours: 3)), now),
        equals('3h ago'),
      );
      expect(
        util.time.ago(now.add(const Duration(hours: 1)), now),
        equals('in the future'),
      );
    });

    test('util.size formats and parses byte counts', () {
      expect(util.size.format(0), equals('0 B'));
      // Bytes have no fraction to show, and a kibibyte is where one starts.
      expect(util.size.format(1023), equals('1023 B'));
      expect(util.size.format(1024), equals('1.0 KiB'));
      expect(util.size.format(1024 * 1024 * 5), equals('5.0 MiB'));
      expect(util.size.format(1024 * 1024 * 1024 * 2), equals('2.0 GiB'));
      // A negative count keeps its sign rather than clamping to '0 B'.
      expect(util.size.format(-2048), equals('-2.0 KiB'));

      expect(util.size.parse('500 B'), equals(500));
      expect(util.size.parse('10 KiB'), equals(10 * 1024));
      expect(util.size.parse('10 K'), equals(10 * 1024));
      expect(util.size.parse('2.5 MiB'), equals((2.5 * 1024 * 1024).round()));
      expect(util.size.parse('1 GiB'), equals(1024 * 1024 * 1024));
      expect(util.size.parse('512'), equals(512));
      expect(util.size.parse('-2 KiB'), equals(-2048));

      // Both families are accepted and each means what its name says: the
      // arithmetic was always 1024-based while the labels said KB and MB.
      expect(util.size.parse('10 KB'), equals(10000));
      expect(util.size.parse('5 MB'), equals(5000000));

      // Not a size, a unit nobody knows, and a unit with no number: all three
      // used to answer 0, which a caller cannot tell from an empty file.
      expect(util.size.parse('nonsense'), isNull);
      expect(util.size.parse('10 XB'), isNull);
      expect(util.size.parse('MB'), isNull);

      // Every unit format writes reads back, to the digits it printed.
      for (final n in [512, 4096, 5242880, 1234567890, 1 << 50]) {
        expect(
          util.size.parse(util.size.format(n, decimals: 6)),
          closeTo(n, n * 1e-6 + 2),
        );
      }
    });

    test('an executable is system.run, not a wrapper', () async {
      // `tool.git` was tried and removed: a wrapper only ever has the five
      // subcommands somebody thought to add, where `system.run` has all of
      // git. This is what the migration looks like.
      final branch = await system.run('git', [
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ]);
      expect(branch.ok, isTrue);
      expect(branch.out.trim(), isNotEmpty);

      final hash = await system.run('git', ['rev-parse', '--short', 'HEAD']);
      expect(hash.out.trim().length, greaterThanOrEqualTo(7));
    });

    test('extensions build Durations and Uris', () {
      expect(250.ms, equals(const Duration(milliseconds: 250)));
      expect(2.s, equals(const Duration(seconds: 2)));
      expect(5.m, equals(const Duration(minutes: 5)));
      expect(
        'https://example.com/a'.url,
        equals(Uri.parse('https://example.com/a')),
      );
    });

    test(
      'ConsoleWriter and ConsoleLogger support injectable sinks for testability',
      () {
        final outBuf = StringBuffer();
        final errBuf = StringBuffer();
        final writer = ConsoleWriter(out: outBuf, err: errBuf);
        final logger = ConsoleLogger(writer);

        logger.info('Info message');
        logger.ok('All good');
        logger.warn('Careful');
        logger.error('Critical failure');

        expect(outBuf.toString(), contains('Info message'));
        expect(outBuf.toString(), contains('All good'));
        expect(outBuf.toString(), contains('Careful'));
        expect(outBuf.toString(), isNot(contains('Critical failure')));

        expect(errBuf.toString(), contains('Critical failure'));
      },
    );

    test(
      'Ansi supports dynamic enabled, 256 colors, and 24-bit truecolor RGB/hex',
      () {
        final original = Ansi.enabled;
        try {
          Ansi.enabled = true;
          expect('test'.color256(196), contains('\x1B[38;5;196m'));
          expect('test'.bgcolor256(21), contains('\x1B[48;5;21m'));
          expect('test'.rgb(255, 100, 50), contains('\x1B[38;2;255;100;50m'));
          expect('test'.bgrgb(10, 20, 30), contains('\x1B[48;2;10;20;30m'));
          expect('test'.hex('#FF0000'), contains('\x1B[38;2;255;0;0m'));
          expect('test'.bghex('00FF00'), contains('\x1B[48;2;0;255;0m'));

          Ansi.enabled = false;
          expect('test'.color256(196), equals('test'));
          expect('test'.rgb(255, 0, 0), equals('test'));
        } finally {
          Ansi.enabled = original;
        }
      },
    );

    test('a failing subprocess reports rather than throwing', () async {
      // In a throwaway repo, never this one.
      final repo = Directory.systemTemp.createTempSync('dt_git_');
      final cwd = repo.path;
      try {
        await system.run('git', ['init', '-q'], cwd: cwd);

        // Nothing staged, so the commit fails and says why.
        final result = await system.run('git', [
          'commit',
          '-m',
          'test empty commit',
        ], cwd: cwd);
        expect(result, isA<SysResult>());
        expect(result.ok, isFalse);
        expect(result.out.isNotEmpty || result.err.isNotEmpty, isTrue);
      } finally {
        io.remove(repo.path);
      }
    });
  });

  group('Domain namespaces', () {
    test('io exposes path, dir and csv; format exposes the codec', () {
      expect(io.path, isA<PathAccessor>());
      expect(io.dir, isA<DirAccessor>());
      expect(io.async.dir, isA<DirAsyncAccessor>());
      expect(io.csv, isA<CsvFileAccessor>());
      expect(format.csv, isA<CsvAccessor>());
      expect(format.csv, isA<Codec<Csv>>());
    });

    test('net exposes http and crawl', () {
      expect(net.http, isA<Fetcher>());
      expect(net.crawl(const Sequence<Fetch>([])), isA<Crawl>());
      // Selectors live on the top-level $, not on net. Like jQuery, find()
      // searches descendants, so a root-level match is read directly.
      expect(
        format.html.parse('<h1 class="title">Domain Test</h1>').text,
        equals('Domain Test'),
      );
      expect(
        format.html
            .parse('<div><h1 class="title">Domain Test</h1></div>')
            .$('.title')
            .text,
        equals('Domain Test'),
      );
      expect(
        format.html.$('<h1 class="title">Domain Test</h1>', '.title').text,
        equals('Domain Test'),
      );
    });

    test('system exposes env, console and on', () {
      expect(system.env, isA<EnvAccessor>());
      expect(system.console, isA<ConsoleAccessor>());
      expect(system.on, isA<SysEvents>());
    });

    test('cli is a domain of its own, not a corner of system', () {
      expect(cli, isA<CliAccessor>());
    });

    test('tool holds the formats, and only the formats', () {
      expect(format.zip, isA<ZipAccessor>());
      expect(format.json, isA<JsonAccessor>());
      expect(format.yaml, isA<YamlAccessor>());
      expect(format.toml, isA<TomlAccessor>());
    });

    test('util exposes time, size, text, json, hash and rand', () {
      expect(util.time, isA<TimeAccessor>());
      expect(util.size, isA<SizeAccessor>());
      expect(util.text, isA<TextAccessor>());
      expect(format.json, isA<JsonAccessor>());
      expect(util.hash, isA<HashAccessor>());
      expect(util.rand, isA<RandAccessor>());
    });
  });
}

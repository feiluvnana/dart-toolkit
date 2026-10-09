// The shared model every module builds on: Task, Work, Batch, parallelize, Retry, Clock, Store,
// Key, Secret, Env.scope and Io.scope.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/src/core.dart';
import 'package:test/test.dart' hide Retry;

import 'support.dart';

void main() {
  group('Task', () {
    test('awaiting gives the value; statuses start with the current one and end with Done', () async {
      final task = Task.run('count', (work) async {
        work.amount(1, total: 2, unit: Unit.items);
        await Future<void>.delayed(Duration.zero);
        work.amount(2, total: 2, unit: Unit.items);
        return 42;
      });
      final seen = task.statuses.toList();
      expect(await task, 42);
      final statuses = await seen;
      expect(statuses.first, isA<Running<Object?, int>>());
      expect(statuses.last, isA<Done<Object?, int>>().having((d) => d.value, 'value', 42));
      expect(task.status, isA<Done<Object?, int>>());
    });

    test('a failure throws to the awaiter and settles as Failed', () async {
      final task = Task.run<int>('boom', (work) => throw const FormatException('bad'));
      expect(await task.settled, isA<Failed<Object?, int>>().having((f) => f.error, 'error', isA<FormatException>()));
      await expectLater(task, throwsFormatException);
    });

    test('a cancel ends it Stopped, throws CancelledException once, and is never an unhandled error', () async {
      final started = Completer<void>();
      final task = Task.run('slow', (work) async {
        started.complete();
        await const Duration(seconds: 10).delay();
        return 1;
      });
      await started.future;
      task.cancel('enough');
      expect(await task.settled, isA<Stopped<Object?, int>>().having((s) => s.reason, 'reason', 'enough'));
      await expectLater(task, throwsA(isA<CancelledException>().having((e) => e.reason, 'reason', 'enough')));
      // Cancelled and never awaited: no unhandled error reaches the zone.
      Task.run('quiet', (work) => const Duration(seconds: 10).delay()).cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    test('work that ignores a cancel is left behind after the grace period', () async {
      final never = Completer<int>();
      final task = Task.run('stuck', (work) => never.future);
      final clock = Stopwatch()..start();
      task.cancel();
      expect(await task.settled, isA<Stopped<Object?, int>>());
      expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('deferred cleanups run once, last first, see how it ended, and a throwing one is a warning', () async {
      final order = <String>[];
      final task = Task.run('clean', (work) {
        work.defer(() => order.add('first:${work.ended.runtimeType}'));
        work.defer(() => throw StateError('cleanup broke'));
        work.defer(() => order.add('last'));
        throw const FormatException('no');
      });
      final warnings = task.statuses.where((s) => s is Warned).toList();
      await task.settled;
      expect(order, ['last', startsWith('first:Failed')]);
      expect(await warnings, hasLength(1));
    });

    test('a task made inside another is part of it: its progress and warnings show as the outer\'s', () async {
      final outer = Task.run('outer', (work) async {
        final inner = Task.run('inner', (w) async {
          w.amount(5, total: 10);
          w.warn('careful');
          await Future<void>.delayed(Duration.zero);
          return 'v';
        });
        return inner;
      });
      final statuses = await outer.statuses.toList();
      expect(statuses.whereType<Running<Object?, String>>().map((r) => r.received), contains(5));
      expect(statuses.whereType<Warned<Object?, String>>().single.warning, isA<NoteWarning>());
      expect(statuses.last, isA<Done<Object?, String>>().having((d) => d.value, 'value', 'v'));
    });

    test('a value a part had already is not fresh, and neither is the work that returns it', () async {
      final task = Task.run('outer', (work) async {
        return await TaskInternals.start('x', 'x', (w) {
          TaskInternals.stale(w);
          return 'kept';
        });
      });
      expect(await task.settled, isA<Done<Object?, String>>().having((d) => d.fresh, 'fresh', false));
    });

    test('timeout names the task and cancels it, so its work stops and its cleanups run', () async {
      var cleaned = false;
      final task = Task.run('slow', (work) async {
        work.defer(() => cleaned = true);
        await const Duration(seconds: 10).delay();
        return 1;
      });
      await expectLater(
        task.timeout(const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>().having((e) => '$e', 'text', contains('slow timed out after'))),
      );
      expect(await task.settled, isA<Stopped<Object?, int>>());
      expect(cleaned, isTrue);
      expect(
        await Task.run(
          'slow',
          (work) => const Duration(seconds: 10).delay().then((_) => 1),
        ).timeout(const Duration(milliseconds: 20), onTimeout: () => 2),
        2,
      );
    });

    test('a cancelled scope around it stops it', () async {
      final token = CancelToken();
      late Task<void> task;
      final scope = Cancel.scope(() async {
        task = Task.run('inside', (work) => const Duration(seconds: 10).delay());
        token.cancel('outer');
        await task.settled;
      }, token: token);
      await scope;
      expect(task.status, isA<Stopped<Object?, void>>());
    });
  });

  group('Batch', () {
    test('awaiting gives the values in input order, whatever order they finish in', () async {
      final batch = [30, 10, 20].parallelize((ms) async {
        await Future<void>.delayed(Duration(milliseconds: ms));
        return ms;
      }, concurrency: 3);
      expect(batch.count, 3);
      expect(await batch, [30, 10, 20]);
      expect(await batch.values.toList(), [10, 20, 30], reason: 'a late listener hears every value, as they finished');
    });

    test('values stream as they finish, in completion order', () async {
      final batch = [30, 10, 20].parallelize((ms) async {
        await Future<void>.delayed(Duration(milliseconds: ms));
        return ms;
      }, concurrency: 3);
      expect(await batch.values.toList(), [10, 20, 30]);
    });

    test('at most concurrency run at once', () async {
      var running = 0, peak = 0;
      await List.generate(10, (i) => i).parallelize((i) async {
        peak = running + 1 > peak ? running + 1 : peak;
        running++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        running--;
        return i;
      }, concurrency: 3);
      expect(peak, 3);
    });

    test('failures do not stop the rest; awaiting throws one BatchException with all of them', () async {
      final batch = [1, 2, 3, 4].parallelize((i) => i.isEven ? throw FormatException('no $i') : i);
      final e = await batch.then<Object?>((v) => v, onError: (Object e) => e);
      expect(e, isA<BatchException<int, int>>());
      final failure = e as BatchException<int, int>;
      expect(failure.failures.map((f) => f.item), [2, 4]);
      expect(failure.values, [1, 3]);
      expect('$e', startsWith('2 of 4 failed: 2: FormatException: no 2'));
      expect(await batch.toMap(), {1: 1, 3: 3});
    });

    test('a bug ends the batch at once and is rethrown as it is', () async {
      var started = 0;
      final batch = List.generate(20, (i) => i).parallelize((i) async {
        started++;
        if (i == 1) throw StateError('bug');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return i;
      }, concurrency: 2);
      await expectLater(batch, throwsStateError);
      await batch.settled;
      expect(started, lessThan(20));
    });

    test('a timed-out item is cancelled and frees its slot, even when it never stops (X-9)', () async {
      final hung = Completer<int>();
      final batch = [0, 1, 2, 3, 4, 5].parallelize(
        (i) => i < 2 ? hung.future : Future.value(i),
        concurrency: 2,
        timeout: const Duration(milliseconds: 50),
      );
      final statuses = await batch.settled;
      expect(
        statuses.take(2),
        everyElement(isA<Failed<int, int>>().having((f) => f.error, 'error', isA<TimeoutException>())),
      );
      expect([for (final s in statuses.skip(2)) (s as Done<int, int>).value], [2, 3, 4, 5]);
    });

    test('retry tries a failed item again, each retry a Warned with a RetryWarning', () async {
      var tries = 0;
      final batch = ['x'].parallelize((s) {
        if (++tries < 3) throw const SocketException('flaky');
        return s;
      }, retry: const Retry(3, backoff: Duration(milliseconds: 1)));
      final warnings = batch.statuses.where((s) => s is Warned).cast<Warned<String, String>>().toList();
      expect(await batch, ['x']);
      expect([for (final w in await warnings) (w.warning as RetryWarning).attempt], [1, 2]);
    });

    test('an error an inner retry gave up on is not tried again by an outer one', () async {
      var sends = 0;
      final batch = ['x'].parallelize(
        (s) => const Retry(2, backoff: Duration.zero).run(() {
          sends++;
          throw const SocketException('down');
        }),
        retry: const Retry(3, backoff: Duration.zero),
      );
      await batch.settled;
      expect(sends, 3, reason: 'the innermost policy wins');
    });

    test('a cancel stops what runs, starts nothing new, and the rest of a list is Stopped', () async {
      final batch = List.generate(
        10,
        (i) => i,
      ).parallelize((i) => const Duration(seconds: 10).delay().then((_) => i), concurrency: 2);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      batch.cancel('bye');
      await expectLater(batch, throwsA(isA<CancelledException>()));
      final statuses = await batch.settled;
      expect(statuses, hasLength(10));
      expect(statuses, everyElement(isA<Stopped<int, int>>()));
    });

    test('a stream source is pulled only when there is room, and its error ends intake', () async {
      var pulled = 0;
      final source = Stream.fromIterable(List.generate(100, (i) => i)).map((i) {
        pulled++;
        return i;
      });
      final batch = source.parallelize((i) async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return i;
      }, concurrency: 2);
      expect(batch.count, isNull);
      expect(await batch, hasLength(100));
      expect(batch.count, 100);
      expect(pulled, 100);
      final failing = Stream<int>.error(const FileSystemException('gone')).parallelize((i) => i);
      await expectLater(failing, throwsA(isA<FileSystemException>()));
    });

    test('a Task an item returns gives the item its progress', () async {
      final batch = ['a'].parallelize(
        (s) => Task.run(s, (work) async {
          work.amount(3, total: 4);
          await Future<void>.delayed(Duration.zero);
          return s;
        }),
      );
      final statuses = await batch.statuses.toList();
      expect(statuses.whereType<Running<String, String>>().map((r) => r.received), contains(3));
    });

    test('a batch inside a task reports items as that task\'s progress', () async {
      final task = Task.run('outer', (work) => [1, 2, 3].parallelize((i) => i));
      final statuses = await task.statuses.toList();
      final items = statuses.whereType<Running<Object?, List<int>>>().where((r) => r.unit == Unit.items);
      expect(items.last.received, 3);
      expect(await task, [1, 2, 3]);
    });

    test('merge shares one concurrency over every batch, and adds their counts', () async {
      var running = 0, peak = 0;
      Future<int> work(int i) async {
        peak = running + 1 > peak ? running + 1 : peak;
        running++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        running--;
        return i;
      }

      final merged = Batch.merge([
        [1, 2, 3].parallelize(work),
        [4, 5, 6].parallelize(work),
      ], concurrency: 2);
      expect(merged.count, 6);
      expect(await merged, [1, 2, 3, 4, 5, 6]);
      expect(peak, 2);
    });

    test('isolate runs the work on other isolates; progress and failures cross', () async {
      final batch = [1, 2, 3].parallelize(_square, isolate: true, concurrency: 2);
      expect(await batch, [1, 4, 9]);
      final failing = [1].parallelize(_fails, isolate: true);
      await expectLater(failing, throwsA(isA<BatchException<int, int>>()));
    });

    test('bad settings are ArgumentErrors at the call', () {
      expect(() => [1].parallelize((i) => i, concurrency: 0), throwsArgumentError);
      expect(() => [1].parallelize((i) => i, timeout: Duration.zero), throwsArgumentError);
    });
  });

  group('Retry', () {
    test('run is a Task whose retries are warnings, and it gives up with the last error', () async {
      var tries = 0;
      final task = const Retry(2, backoff: Duration.zero).run(() {
        tries++;
        throw const SocketException('down');
      });
      final warnings = task.statuses.where((s) => s is Warned).toList();
      await expectLater(task, throwsA(isA<SocketException>()));
      expect(tries, 3);
      expect(await warnings, hasLength(2));
    });

    test('what would fail the same way again is not retried', () async {
      var tries = 0;
      await expectLater(
        Retry.network.run(() {
          tries++;
          throw const FormatException('bad');
        }),
        throwsFormatException,
      );
      expect(tries, 1);
    });

    test('the backoff is waited on the clock, so a fake clock tests minutes in no time', () async {
      final clock = Clock.fake();
      var tries = 0;
      final done = Clock.scope(
        () => const Retry(3, backoff: Duration(minutes: 1)).run(() {
          if (++tries < 4) throw const SocketException('down');
          return 'up';
        }),
        clock: clock,
      );
      await clock.advance(const Duration(minutes: 10));
      expect(await done, 'up');
      expect(tries, 4);
    });
  });

  group('Clock', () {
    test('a fake clock holds every timer until it is advanced past it, in order', () async {
      final clock = Clock.fake();
      final fired = <int>[];
      final done = Clock.scope(() async {
        Timer(const Duration(seconds: 2), () => fired.add(2));
        Timer(const Duration(seconds: 1), () => fired.add(1));
        await const Duration(seconds: 3).delay();
        fired.add(3);
      }, clock: clock);
      await clock.advance(const Duration(milliseconds: 1500));
      expect(fired, [1]);
      await clock.advance(const Duration(seconds: 2));
      await done;
      expect(fired, [1, 2, 3]);
      expect(clock.elapsed, const Duration(milliseconds: 3500));
    });
  });

  group('Store', () {
    test('a key reads its default until written, and a write is read back', () async {
      for (final store in [Store.memory(), Store('${tempDir()}/state')]) {
        const seen = Key<List<String>>('seen', or: []);
        expect(await store.read(seen), isEmpty);
        await store.write(seen, ['a', 'b']);
        expect(await store.read(seen), ['a', 'b']);
        expect(await store.update(seen, (ids) => [...ids, 'c']), ['a', 'b', 'c']);
        await store.clear();
        expect(await store.read(seen), isEmpty);
      }
    });

    test('sub-stores are separate, and clear forgets a sub-store with its parent', () async {
      final app = Store.memory();
      const n = Key<int>('n', or: 0);
      await app.write(n, 1);
      await (app / 'crawl').write(n, 2);
      expect((await app.read(n), await (app / 'crawl').read(n)), (1, 2));
      await (app / 'crawl').clear();
      expect((await app.read(n), await (app / 'crawl').read(n)), (1, 0));
    });

    test('update holds the lock, so concurrent updates lose nothing', () async {
      final store = Store('${tempDir()}/state');
      const count = Key<int>('count', or: 0);
      await Future.wait([for (var i = 0; i < 20; i++) store.update(count, (n) => n + 1)]);
      expect(await store.read(count), 20);
    });

    test('a type JSON cannot carry needs a serializer; a key with one round-trips', () async {
      final store = Store.memory();
      const bad = Key<DateTime?>('when', or: null);
      await expectLater(store.write(bad, DateTime(2026)), throwsArgumentError);
      final when = Key<DateTime?>(
        'when2',
        or: null,
        as: Serializer(
          encode: (d) => d?.toIso8601String(),
          decode: (j) => j == null ? null : DateTime.parse(j as String),
        ),
      );
      await store.write(when, DateTime.utc(2026, 1, 2));
      expect(await store.read(when), DateTime.utc(2026, 1, 2));
    });

    test('a file another version wrote is a FormatException naming the folder', () async {
      final dir = tempDir();
      File('$dir/k.json').writeAsStringSync(jsonEncode({'version': 99, 'value': 1}));
      await expectLater(
        Store(dir).read(const Key<int>('k', or: 0)),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(dir))),
      );
    });

    test('Store.app follows DART_TOOLKIT_STORE', () async {
      final root = tempDir();
      await Env.scope(() async {
        Env.set('DART_TOOLKIT_STORE', root);
        expect(Store.app('books').folder, '$root${Platform.pathSeparator}books');
      });
      expect(() => Store.app('a/b'), throwsArgumentError);
    });
  });

  group('Secret', () {
    test('never prints, and reveal gives the text', () {
      const pw = Secret('hunter2');
      expect('$pw', '•••');
      expect('pw=$pw', isNot(contains('hunter2')));
      expect(pw.reveal, 'hunter2');
      expect(pw == const Secret('hunter2'), isTrue);
    });
  });

  group('Env', () {
    test('a scope undoes what was set and unset inside it', () async {
      Env.set('TK_SPINE', 'outer');
      addTearDown(() => Env.unset('TK_SPINE'));
      await Env.scope(() async {
        Env.set('TK_SPINE', 'inner');
        Env.unset('HOME');
        expect(Env.get<String>('TK_SPINE'), 'inner');
        expect(Env.has('HOME'), isFalse);
        expect(Env.all.containsKey('HOME'), isFalse);
      });
      expect(Env.get<String>('TK_SPINE'), 'outer');
      expect(Env.has('HOME'), Platform.environment['HOME']?.isNotEmpty ?? false);
    });

    test('get reads Path, Uri and Secret; blank is absence; a mistyped value is a FormatException', () async {
      await Env.scope(() async {
        Env.set('TK_DIR', '/tmp/x');
        Env.set('TK_URL', 'https://a.b/c');
        Env.set('TK_TOKEN', 's3cret');
        Env.set('TK_PORT', 'eighty');
        Env.set('TK_BLANK', '  ');
        expect(Env.get<Path>('TK_DIR'), '/tmp/x');
        expect(Env.get<Uri>('TK_URL').host, 'a.b');
        expect(Env.get<Secret>('TK_TOKEN').reveal, 's3cret');
        expect(() => Env.get<int>('TK_PORT', or: 80), throwsFormatException);
        expect(Env.get<int>('TK_NONE', or: 80), 80);
        expect(Env.get<String?>('TK_NONE'), isNull);
        expect(() => Env.get<String>('TK_NONE'), throwsA(isA<MissingException>()));
      });
    });

    test('parse is pure; load applies what is not already set', () async {
      final parsed = Env.parse('A=1\nB="two words" # note\nexport C=\${A}x', expand: true);
      expect(parsed, {'A': '1', 'B': 'two words', 'C': '1x'});
      expect(Env.has('A'), isFalse);
      final file = '${tempDir()}/.env';
      File(file).writeAsStringSync('TK_LOADED=yes\nHOME=/nowhere\n');
      await Env.scope(() async {
        await Env.load(file);
        expect(Env.get<String>('TK_LOADED'), 'yes');
        expect(Env.get<String>('HOME'), isNot('/nowhere'));
      });
    });
  });

  group('Io', () {
    test('a scope replaces stdout, stderr and stdin for its body', () async {
      final (out, err) = (StringBuffer(), StringBuffer());
      final lines = await Io.scope(
        () async {
          Io.stdout.writeln('to out');
          Io.stderr.writeln('to err');
          final first = await Io.readLine();
          final rest = <String>[];
          await for (final line in Io.lines()) {
            rest.add(line);
            break;
          }
          await for (final line in Io.lines()) {
            rest.add(line);
          }
          return [first, ...rest];
        },
        stdout: out,
        stderr: err,
        stdin: Stream.value(utf8.encode('a\nb\nc\n')),
        color: false,
      );
      expect(lines, ['a', 'b', 'c'], reason: 'breaking out of lines() loses nothing');
      expect(('$out', '$err'), ('to out\n', 'to err\n'));
    });
  });

  group('errors', () {
    test('MissingException says what and where', () {
      expect('${const MissingException('column "x"', where: 'sales.csv')}', 'Missing column "x" in sales.csv');
      expect('${const CancelledException('bye')}', 'Cancelled: bye');
    });
  });
}

int _square(int i) => i * i;

int _fails(int i) => throw FormatException('no $i');

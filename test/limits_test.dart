import 'dart:io' as dart_io;

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('RateLimiter', () {
    test('starts full, so the first burst does not wait', () async {
      final limit = RateLimiter(3, per: 10.s);
      final clock = (Stopwatch()..start());
      await limit.take();
      await limit.take();
      await limit.take();
      expect(clock.elapsedMilliseconds, lessThan(200));
      expect(limit.available, lessThan(1));
      limit.close();
    });

    test('paces past the burst rather than delaying every call', () async {
      // 20 per second is a token every 50ms; five of them from empty is ~200ms.
      final limit = RateLimiter(1, per: 50.ms);
      await limit.take(); // spends the one token it started with
      final clock = (Stopwatch()..start());
      for (var i = 0; i < 4; i++) {
        await limit.take();
      }
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(150));
      expect(clock.elapsedMilliseconds, lessThan(1500));
      limit.close();
    });

    test('guard wraps an action, and waiters are served in order', () async {
      final limit = RateLimiter(1, per: 30.ms);
      final done = <int>[];
      await Future.wait<void>([
        for (var i = 0; i < 5; i++) limit.guard(() async => done.add(i)),
      ]);
      expect(done, equals([0, 1, 2, 3, 4]));
      limit.close();
    });

    test('composes with parallelMap', () async {
      final limit = RateLimiter(4, per: 40.ms);
      final results = await parallelMap<int, int>(
        List<int>.generate(8, (i) => i),
        (int n) => limit.guard(() async => n * 2),
        concurrency: 3,
      );
      expect(results, equals([0, 2, 4, 6, 8, 10, 12, 14]));
      limit.close();
    });

    test('refuses a nonsense bound rather than ignoring it', () {
      expect(() => RateLimiter(0), throwsArgumentError);
      expect(() => RateLimiter(1, per: Duration.zero), throwsArgumentError);
    });

    test('close releases everyone still waiting', () async {
      final limit = RateLimiter(1, per: 10.s);
      await limit.take();
      final queued = limit.take();
      expect(limit.waiting, equals(1));
      limit.close();
      await queued; // completes rather than hanging until the window rolls
      expect(limit.toString(), contains('1 per'));
    });

    test('a Fetcher can carry one', () async {
      final limit = RateLimiter(2, per: 30.ms);
      final client = Fetcher(limiter: limit);
      addTearDown(client.close);
      expect(client.limiter, same(limit));
      limit.close();
    });
  });

  group('withLock', () {
    test('runs the action and releases on the way out', () async {
      final dir = tempDirSync('dt_lock_');
      try {
        final path = joinPath(dir.path, '.run.lock');
        expect(isLocked(path), isFalse);
        final answer = await withLock(path, () async {
          expect(isLocked(path), isTrue);
          return 42;
        });
        expect(answer, equals(42));
        expect(pathExists(path), isFalse, reason: 'released on normal return');
        expect(isLocked(path), isFalse);
      } finally {
        removePathSync(dir.path);
      }
    });

    test('releases when the action throws', () async {
      final dir = tempDirSync('dt_lock_throw_');
      try {
        final path = joinPath(dir.path, '.run.lock');
        await expectLater(
          withLock(path, () => throw StateError('boom')),
          throwsStateError,
        );
        expect(isLocked(path), isFalse);
      } finally {
        removePathSync(dir.path);
      }
    });

    test('a lock a live process holds is refused, or waited for', () async {
      final dir = tempDirSync('dt_lock_busy_');
      try {
        final path = joinPath(dir.path, '.run.lock');
        final held = withLock(path, () => delay(400.ms));

        // Long enough for the outer lock to be taken.
        await delay(80.ms);
        await expectLater(
          withLock(path, () async {}),
          throwsA(isA<LockedError>()),
        );

        final queued = withLock(path, () async => 'second', wait: 5.s);
        await held;
        expect(await queued, equals('second'));
      } finally {
        removePathSync(dir.path);
      }
    });

    test('a stale lock is taken, not obeyed', () async {
      final dir = tempDirSync('dt_lock_stale_');
      try {
        final path = joinPath(dir.path, '.run.lock');
        // A pid no live process can have, written the way a real lock is.
        writeTextSync(
          path,
          '{"pid": 999999998, "since": "2020-01-01T00:00:00Z"}',
        );
        expect(isLocked(path), isFalse);
        expect(await withLock(path, () async => 'taken'), equals('taken'));
      } finally {
        removePathSync(dir.path);
      }
    });

    test('LockedError names the process holding it', () {
      const error = LockedError('.x.lock', pid: 4321);
      expect(error.toString(), contains('.x.lock'));
      expect(error.toString(), contains('4321'));
    });
  });

  group('watchPath', () {
    test('reports a change, coalescing the burst of a save', () async {
      final dir = tempDirSync('dt_watch_');
      final seen = <String>[];
      Future<void> Function()? stop;
      try {
        stop = watchPath(
          dir.path,
          seen.add,
          pattern: RegExp(r'\.txt$'),
          settle: 120.ms,
        );
        await delay(150.ms);

        // Three writes, as an editor does per save.
        final path = joinPath(dir.path, 'note.txt');
        for (var i = 0; i < 3; i++) {
          writeTextSync(path, 'v$i');
          await delay(20.ms);
        }
        writeTextSync(joinPath(dir.path, 'skipped.md'), 'ignored');

        await delay(900.ms);
        expect(
          seen.where((p) => p.endsWith('note.txt')).length,
          equals(1),
          reason: 'three writes coalesce into one call',
        );
        expect(seen.any((p) => p.endsWith('.md')), isFalse);
      } finally {
        await stop?.call();
        removePathSync(dir.path);
      }
    }, onPlatform: const {'windows': Skip('filesystem events differ')});

    test('stopping is idempotent and silences later changes', () async {
      final dir = tempDirSync('dt_watch_stop_');
      final seen = <String>[];
      try {
        final stop = watchPath(dir.path, seen.add, settle: Duration.zero);
        await stop();
        await stop();
        writeTextSync(joinPath(dir.path, 'after.txt'), 'x');
        await delay(300.ms);
        expect(seen, isEmpty);
      } finally {
        removePathSync(dir.path);
      }
    });

    test('watching a path that does not exist is not an error', () async {
      final stop = watchPath(
        joinPath(dart_io.Directory.systemTemp.path, 'dt_absent_dir'),
        (_) {},
      );
      await stop();
    });
  });
}

import 'dart:io' as dart_io;

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
      final results = await List<int>.generate(
        8,
        (i) => i,
      ).parallelMap((int n) => limit.guard(() async => n * 2), concurrency: 3);
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

  group('Semaphore', () {
    test('bounds concurrency and releases correctly', () async {
      final sem = Semaphore(2);
      expect(sem.available, equals(2));
      await sem.take();
      expect(sem.available, equals(1));
      await sem.take();
      expect(sem.available, equals(0));

      var completed = false;
      final waitTask = sem.take().then((_) => completed = true);
      await delay(20.ms);
      expect(completed, isFalse);

      sem.release();
      await waitTask;
      expect(completed, isTrue);
      expect(sem.available, equals(0));

      sem.release();
      expect(sem.available, equals(1));
    });

    test('guard releases permit on normal return and on error', () async {
      final sem = Semaphore(1);
      final res = await sem.guard(() async => 100);
      expect(res, equals(100));
      expect(sem.available, equals(1));

      await expectLater(
        sem.guard(() async => throw StateError('fail')),
        throwsStateError,
      );
      expect(sem.available, equals(1));
    });

    test(
      'Fetcher with Semaphore(1) can send multiple requests without deadlocking',
      () async {
        final sem = Semaphore(1);
        final client = Fetcher(
          limiter: sem,
          client: MockClient((request) async => http.Response('ok', 200)),
        );
        addTearDown(client.close);

        // Make 3 sequential requests; with permits: 1, previously this deadlocked on request 2
        final res1 = await client.get(Uri.parse('https://example.com/1'));
        expect(res1.text, equals('ok'));
        expect(sem.available, equals(1));

        final res2 = await client.get(Uri.parse('https://example.com/2'));
        expect(res2.text, equals('ok'));
        expect(sem.available, equals(1));

        final res3 = await client.get(Uri.parse('https://example.com/3'));
        expect(res3.text, equals('ok'));
        expect(sem.available, equals(1));
      },
    );
  });

  group('withLock', () {
    test('runs the action and releases on the way out', () async {
      final dir = SyncPath.tempDir('dt_lock_');
      try {
        final path = Path(dir.path) / '.run.lock';
        expect(Path(path).isLocked, isFalse);
        final answer = await Path(path).lock(() async {
          expect(Path(path).isLocked, isTrue);
          return 42;
        });
        expect(answer, equals(42));
        expect(Path(path).exists, isFalse, reason: 'released on normal return');
        expect(Path(path).isLocked, isFalse);
      } finally {
        Path(dir.path).sync.delete();
      }
    });

    test('releases when the action throws', () async {
      final dir = SyncPath.tempDir('dt_lock_throw_');
      try {
        final path = Path(dir.path) / '.run.lock';
        await expectLater(
          Path(path).lock(() => throw StateError('boom')),
          throwsStateError,
        );
        expect(Path(path).isLocked, isFalse);
      } finally {
        Path(dir.path).sync.delete();
      }
    });

    test('a lock a live process holds is refused, or waited for', () async {
      final dir = SyncPath.tempDir('dt_lock_busy_');
      try {
        final path = Path(dir.path) / '.run.lock';
        final held = Path(path).lock(() => delay(400.ms));

        // Long enough for the outer lock to be taken.
        await delay(80.ms);
        await expectLater(
          Path(path).lock(() async {}),
          throwsA(isA<LockedError>()),
        );

        final queued = Path(path).lock(() async => 'second', wait: 5.s);
        await held;
        expect(await queued, equals('second'));
      } finally {
        Path(dir.path).sync.delete();
      }
    });

    test('a stale lock is taken, not obeyed', () async {
      final dir = SyncPath.tempDir('dt_lock_stale_');
      try {
        final path = Path(dir.path) / '.run.lock';
        // A pid no live process can have, written the way a real lock is.
        Path(
          path,
        ).sync.writeText('{"pid": 999999998, "since": "2020-01-01T00:00:00Z"}');
        expect(Path(path).isLocked, isFalse);
        expect(await Path(path).lock(() async => 'taken'), equals('taken'));
      } finally {
        Path(dir.path).sync.delete();
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
      final dir = SyncPath.tempDir('dt_watch_');
      final seen = <String>[];
      Future<void> Function()? stop;
      try {
        stop = Path(
          dir.path,
        ).watch(seen.add, pattern: RegExp(r'\.txt$'), settle: 120.ms);
        await delay(150.ms);

        // Three writes, as an editor does per save.
        final path = Path(dir.path) / 'note.txt';
        for (var i = 0; i < 3; i++) {
          Path(path).sync.writeText('v$i');
          await delay(20.ms);
        }
        Path(Path(dir.path) / 'skipped.md').sync.writeText('ignored');

        await delay(900.ms);
        expect(
          seen.where((p) => p.endsWith('note.txt')).length,
          equals(1),
          reason: 'three writes coalesce into one call',
        );
        expect(seen.any((p) => p.endsWith('.md')), isFalse);
      } finally {
        await stop?.call();
        Path(dir.path).sync.delete();
      }
    }, onPlatform: const {'windows': Skip('filesystem events differ')});

    test('stopping is idempotent and silences later changes', () async {
      final dir = SyncPath.tempDir('dt_watch_stop_');
      final seen = <String>[];
      try {
        final stop = Path(dir.path).watch(seen.add, settle: Duration.zero);
        await stop();
        await stop();
        Path(Path(dir.path) / 'after.txt').sync.writeText('x');
        await delay(300.ms);
        expect(seen, isEmpty);
      } finally {
        Path(dir.path).sync.delete();
      }
    });

    test('watching a path that does not exist is not an error', () async {
      final stop = Path(
        Path(dart_io.Directory.systemTemp.path) / 'dt_absent_dir',
      ).watch((_) {});
      await stop();
    });
  });
}

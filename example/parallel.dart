// Do many things at once, without doing all of them at once.
//
//   dart run example/parallel.dart
//
// Every helper here is bounded: `size` is the most that can be in flight, and
// results come back in input order however they finished.

import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final log = system.console.logger;
  util.rand.seed(7); // Deterministic output for an example.

  final ids = [for (var i = 1; i <= 12; i++) 'job-$i'];

  // ------------------------------------------------------------ the common case
  // `concurrent.run` is the one-liner: at most four at a time, in order.
  final bar = Progress(total: ids.length, message: 'Fetching');
  final sizes = await concurrent.run(ids, (id) async {
    await util.time.wait(util.rand.jitter(40.ms));
    bar.tick(1, id);
    return id.length * 100;
  }, size: 4);
  bar.done();
  log.ok(
    'Fetched ${sizes.count()}, ${util.size.format(sizes.list.reduce(_sum))} total',
  );

  // `concurrent.stream` yields each result as it lands, for work whose output
  // should not wait on the slowest item.
  var seen = 0;
  await for (final _ in concurrent.stream(ids, _measure, size: 4)) {
    seen++;
  }
  log.info('Streamed $seen results.');

  // ------------------------------------------------------------- when one fails
  // `run` propagates the first failure with its own stack. A `Pool` reports
  // failures as they happen and carries on.
  final pool = Pool<String>(size: 4);
  pool.on.error((error, _, id) => log.warn('$id: $error'));

  // `settle` never throws: every item comes back as a sealed Done or Broke.
  final results = await pool.settle(ids, _flaky);
  final ok = results.only<Done<String>>().count();
  log.ok('$ok of ${results.count()} succeeded.');

  for (final (i, result) in results.pairs.head(4).list) {
    log.info(switch (result) {
      Done(:final value) => '${ids[i].padRight(7)} $value',
      Broke(:final error) => '${ids[i].padRight(7)} failed — $error',
    });
  }

  // ------------------------------------------------------------------- retries
  // Backoff doubles per attempt, capped, and `when` decides what is worth
  // retrying at all.
  var attempts = 0;
  final value = await concurrent.retry(
    () {
      attempts++;
      if (attempts < 3) throw StateError('not ready');
      return 'ready on attempt $attempts';
    },
    retries: 4,
    backoff: 10.ms,
    when: (e) => e is StateError,
    onretry: (e, n) => log.debug('attempt $n: $e'),
  );
  log.ok(value);

  // ------------------------------------------------------------------ the locks
  // For sharing something that is not a task list: a semaphore bounds access,
  // a mutex serialises it.
  final gate = concurrent.semaphore(2);
  await Future.wait([for (var i = 0; i < 4; i++) gate.guard(_measure)]);
  log.ok('Semaphore let 4 tasks through 2 permits.');

  // ------------------------------------------------------------- the rate
  // Those bound *how many at once*. A published API limit bounds *how often*,
  // which a concurrency cap does not satisfy: four instant requests then four
  // more is eight in a second. A limiter composes with the cap.
  final limit = concurrent.rate(4, per: 100.ms);
  final clock = util.time.clock();
  await concurrent.run(
    List<int>.generate(12, (i) => i),
    (n) => limit.guard(() async => n),
    size: 8,
  );
  log.ok(
    '12 tasks at 4 per 100ms took ${clock.elapsedMilliseconds}ms '
    '(8 in flight, never more than 40 per second).',
  );
  limit.close();
}

int _sum(int a, int b) => a + b;

Future<int> _measure([Object? _]) async {
  await util.time.wait(10.ms);
  return 1;
}

Future<String> _flaky(String id) async {
  await util.time.wait(util.rand.jitter(20.ms));
  if (util.rand.chance(0.25)) throw StateError('upstream refused $id');
  return 'ok';
}

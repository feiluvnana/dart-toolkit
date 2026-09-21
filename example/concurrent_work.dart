import 'package:dart_toolkit/dart_toolkit.dart';

/// Doing many things at once without losing track of the ones that failed. There is no
/// network here — the "work" is a delay — so the shapes are the whole point.
Future<void> main() async {
  final ids = [for (var i = 1; i <= 12; i++) i];

  Console.rule('Bounded parallelism that settles everything');

  // Four in flight. Every outcome comes back in input order, and one failure never throws:
  // the result is a list of Either, so the caller decides what a failure means.
  final settled = await ids.parallelize(score, concurrency: 4);
  Logger.info('${settled.rights.length} ok, ${settled.lefts.length} failed');
  Logger.warn('first failure: ${settled.lefts.first}');

  // Same call, three policies.
  Logger.info('discard failures: ${settled.rights.take(4).join(', ')}…');
  Logger.info('inspect them:     ${settled.lefts.map((e) => '$e').join(' / ')}');
  try {
    settled.unwrap();
  } on Flaky catch (e) {
    // unwrap rethrows the original error, with the stack trace it was caught with — not a
    // wrapper type. Catch what the worker throws.
    Logger.info('or throw the first: $e');
  }

  Console.rule('As they settle, rather than all at once');

  // The stream form emits each outcome when it lands, so a slow item does not hold up the
  // ones behind it. A paused consumer pauses the source; nothing is buffered on its behalf.
  var seen = 0;
  await for (final outcome in Stream.fromIterable(ids).parallelize(score, concurrency: 3).rights) {
    seen++;
    if (seen <= 3) Logger.info('arrived: $outcome');
  }
  Logger.ok('$seen results streamed');

  Console.rule('Retrying what is worth retrying');

  var attempts = 0;
  final connected = await retry(
    () async {
      attempts++;
      if (attempts < 3) throw const Flaky('connection reset');
      return 'connected on attempt $attempts';
    },
    attempts: 5,
    delay: 20.ms,
    // Only retry what a second attempt could fix. Everything else rethrows at once.
    when: (e) => e is Flaky,
    onRetry: (n, error, next) => Logger.warn('attempt $n: $error — retrying in ${next.humanized}'),
  );
  Logger.ok(connected);

  Console.rule('Stopping early');

  // One token, cancelled from outside. Work not yet started comes back as a Left holding a
  // CancelledException, so the report still accounts for every item.
  final token = CancelToken();
  60.ms.delay().then((_) => token.cancel('ran out of patience'));
  final partial = await ids.parallelize(score, concurrency: 2, cancelToken: token);
  Logger.info('${partial.rights.length} finished, ${partial.lefts.length} cancelled or failed');
  Logger.info('reason: ${token.reason}');

  Console.rule('One at a time, where something cannot overlap');

  final lock = Mutex();
  final order = <String>[];
  await [1, 2, 3].parallelize(
    (n) => lock.run(() async {
      order.add('enter $n');
      await 10.ms.delay();
      order.add('leave $n');
    }),
    concurrency: 3,
  );
  // Three workers, but enter and leave never interleave.
  Logger.info(order.join(' → '));

  Console.rule('Off the main isolate');

  // A closure becomes background work by asking it to.
  final count = await (() => primesBelow(200000)).isolate();
  Logger.ok('$count primes below 200000, counted without blocking this isolate');

  Console.rule('Stream operators');

  final batches = await Stream.fromIterable(ids).chunk(5).map((b) => b.length).toList();
  Logger.info('chunk(5) over ${ids.length}: $batches');

  final merged = await [
    Stream.fromIterable(['a', 'b']),
    Stream.fromIterable(['c', 'd', 'e']),
  ].merge().toList();
  Logger.info('merge: ${merged.join(', ')} (both sources run at the same time)');

  final kept = await Stream.fromIterable([1, null, 2, null, 3]).nonNulls.toList();
  Logger.info('nonNulls: $kept');
}

/// Work that takes a while and sometimes fails, the way real work does.
Future<int> score(int id) async {
  await (id * 15).ms.delay();
  if (id % 5 == 0) throw Flaky('id $id is unlucky');
  return id * 10;
}

int primesBelow(int limit) {
  final sieve = List<bool>.filled(limit, true);
  var count = 0;
  for (var n = 2; n < limit; n++) {
    if (!sieve[n]) continue;
    count++;
    for (var m = n * n; m < limit; m += n) {
      sieve[m] = false;
    }
  }
  return count;
}

/// Worth a second attempt, unlike a programming error.
final class Flaky implements Exception {
  final String message;
  const Flaky(this.message);
  @override
  String toString() => 'Flaky: $message';
}

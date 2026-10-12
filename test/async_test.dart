import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:dart_toolkit/async.dart';
import 'package:test/test.dart';

/// One counted job: posts its id on start and on end, answers its id.
Future<int> _job(({SendPort port, int id}) job) async {
  await Chan.post(job.port, job.id);
  final end = DateTime.now().add(const Duration(milliseconds: 50));
  while (DateTime.now().isBefore(end)) {}
  await Chan.post(job.port, -job.id);
  return job.id;
}

void main() {
  test('Task.run of a busy loop does not block a timer', () async {
    var timerFired = false;
    unawaited(Future<void>.delayed(const Duration(milliseconds: 10)).then((_) => timerFired = true));
    await Task.run(() {
      final end = DateTime.now().add(const Duration(milliseconds: 300));
      while (DateTime.now().isBefore(end)) {}
    });
    expect(timerFired, isTrue);
  });

  test('Task.run(timeout:) throws TimeoutException', () async {
    await expectLater(
      Task.run(() {
        final end = DateTime.now().add(const Duration(milliseconds: 300));
        while (DateTime.now().isBefore(end)) {}
      }, timeout: const Duration(milliseconds: 50)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('Pool.map keeps order with bounded concurrency', () async {
    final chan = Chan<int>(10);
    final running = <int>{};
    var maxRunning = 0;
    Future<void> drain() async {
      await for (final id in chan.recv()) {
        if (id >= 0) {
          running.add(id);
          maxRunning = max(maxRunning, running.length);
        } else {
          running.remove(-id);
        }
      }
    }

    final pool = Pool(2);
    final draining = drain();
    final ids = await pool.map([for (var i = 1; i <= 6; i++) (port: chan.port, id: i)], _job);
    await pool.close();
    await chan.close();
    await draining;
    expect(ids, [1, 2, 3, 4, 5, 6]);
    expect(maxRunning, lessThanOrEqualTo(2));
    expect(maxRunning, greaterThan(1));
    expect(running, isEmpty);
  });

  test('a bounded Chan never holds more than cap', () async {
    final chan = Chan<int>(3);
    await chan.send(1);
    await chan.send(2);
    await chan.send(3);
    var fourthDone = false;
    unawaited(chan.send(4).then((_) => fourthDone = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fourthDone, isFalse);
    expect(chan.len, 3);
    final seen = <int>[];
    await for (final v in chan.recv()) {
      seen.add(v);
      if (seen.length == 4) break;
    }
    expect(seen, [1, 2, 3, 4]);
    expect(fourthDone, isTrue);
    await chan.close();
  });

  test('recv() ends when close() is called', () async {
    final chan = Chan<int>(10);
    await chan.send(1);
    final seen = <int>[];
    await for (final v in chan.recv()) {
      seen.add(v);
      await chan.close();
    }
    expect(seen, [1]);
  });
}

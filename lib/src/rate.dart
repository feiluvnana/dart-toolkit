/// [Rate] (exported by `core`) and the cancellable waits behind it, shared by
/// `http` (paced sends, backoff) and `pool` (paced job starts).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math';

/// Paces the work that shares it, for APIs that ban bursts: at most [count]
/// starts per [per] (a sliding window), each after a random pause of up to
/// [pause]. A 429 on a paced request waits until the window frees (or the
/// server's `Retry-After`, if longer) before its retry, instead of a backoff
/// that only extends a ban. [onWait] hears every wait of a second or more,
/// so a script can say why it went quiet. Keep one per API for the whole
/// run: the window is its memory.
///
/// ```dart
/// final api = Rate(75, 11.minutes, pause: 3.seconds);
/// final ig = Http.client(rate: api);
/// await Pool.map(paths, convert, rate: Rate(2, 1.seconds));
/// ```
final class Rate {
  Rate(this.count, this.per, {this.pause = Duration.zero, this.onWait}) {
    if (count < 1) throw ArgumentError.value(count, 'count', 'must be at least 1');
  }

  /// Starts allowed per window.
  final int count;

  /// The window.
  final Duration per;

  /// Upper bound of the random pause before each start.
  final Duration pause;

  /// Called before a wait of a second or more.
  final void Function(Duration wait)? onWait;

  final _sent = ListQueue<DateTime>();
  final _random = Random();
  Future<void> _tail = Future.value();

  /// Wait for a free slot and take it: the same pacing for any work.
  Future<void> wait() => take(this, null);

  void _trim(DateTime now) {
    while (_sent.isNotEmpty && now.difference(_sent.first) >= per) {
      _sent.removeFirst();
    }
  }
}

/// Fires once; the waits that carry it end early. A closed client fires its
/// own, so only its own requests and waits stop.
final class Halt {
  final _done = Completer<void>();

  /// The waits in flight: each removes itself when its timer fires, so a
  /// long-lived halt holds nothing per finished wait.
  final _waits = <void Function()>{};

  bool get fired => _done.isCompleted;

  /// How many waits are in flight.
  int get pending => _waits.length;

  Future<void> get future => _done.future;

  void fire() {
    if (_done.isCompleted) return;
    _done.complete();
    for (final end in [..._waits]) {
      end();
    }
    _waits.clear();
  }
}

/// Wait [d], or less when [halt] fires first; the timer never outlives it.
Future<void> sleep(Duration d, Halt? halt) {
  if (d <= Duration.zero) return Future.value();
  if (halt == null) return Future<void>.delayed(d);
  if (halt.fired) return Future.value();
  final done = Completer<void>();
  late final Timer timer;
  void end() {
    timer.cancel();
    halt._waits.remove(end);
    if (!done.isCompleted) done.complete();
  }

  timer = Timer(d, end);
  halt._waits.add(end);
  return done.future;
}

/// Take a slot of [rate], in call order (concurrent starts queue).
Future<void> take(Rate rate, Halt? halt) {
  final next = rate._tail.then((_) => _slot(rate, halt));
  rate._tail = next.then((_) {}, onError: (_) {});
  return next;
}

Future<void> _slot(Rate rate, Halt? halt) async {
  if (rate.pause > Duration.zero) await sleep(rate.pause * rate._random.nextDouble(), halt);
  final now = DateTime.now();
  rate._trim(now);
  if (rate._sent.length >= rate.count) {
    final wait = rate._sent.first.add(rate.per).difference(now);
    if (wait >= const Duration(seconds: 1)) rate.onWait?.call(wait);
    await sleep(wait, halt);
    if (rate._sent.isNotEmpty) rate._sent.removeFirst();
  }
  rate._sent.addLast(DateTime.now());
}

/// Whether [rate] would start now without waiting for the window.
bool free(Rate rate) {
  rate._trim(DateTime.now());
  return rate._sent.length < rate.count;
}

/// The wait after a 429: until the oldest start leaves the window, or the
/// server's `Retry-After` when longer. The window is our own memory and is
/// never capped; the server's value is capped at 5 minutes, as in
/// `retry.backoff`, so a hostile header cannot park a script for years.
Duration ban(Rate rate, Duration? server) {
  var wait = rate._sent.isEmpty ? rate.per : rate._sent.first.add(rate.per).difference(DateTime.now());
  const cap = Duration(minutes: 5);
  if (server != null && server > cap) server = cap;
  if (server != null && server > wait) wait = server;
  if (wait < Duration.zero) wait = Duration.zero;
  if (wait >= const Duration(seconds: 1)) rate.onWait?.call(wait);
  return wait;
}

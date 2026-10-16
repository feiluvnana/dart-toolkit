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
/// run: the window is its memory. With [perHost], http keeps one window
/// per host (a crawler that is polite to each site); `wait()` and `pool`
/// use one shared window.
///
/// ```dart
/// final api = Rate(75, 11.minutes, pause: 3.seconds);
/// final ig = Http.client(rate: api);
/// final crawl = Http.client(rate: Rate(1, 1.seconds, perHost: true));
/// await Pool.map(paths, convert, rate: Rate(2, 1.seconds));
/// ```
final class Rate {
  Rate(
    int count,
    Duration per, {
    Duration pause = Duration.zero,
    void Function(Duration wait)? onWait,
    bool perHost = false,
  }) : _count = count,
       _per = per,
       // ignore: prefer_initializing_formals – the public argument names stay.
       _pause = pause,
       // ignore: prefer_initializing_formals
       _onWait = onWait,
       // ignore: prefer_initializing_formals
       _perHost = perHost {
    if (count < 1) throw ArgumentError.value(count, 'count', 'must be at least 1');
  }

  final int _count; // starts allowed per window
  final Duration _per; // the window
  final Duration _pause; // upper bound of the random pause before each start
  final void Function(Duration wait)? _onWait; // hears every wait of a second or more
  final bool _perHost;

  final _shared = _Window();
  final _hosts = <String, _Window>{};
  final _random = Random();

  /// Wait for a free slot and take it: the same pacing for any work.
  Future<void> wait() => take(this, null);

  _Window _window(String? host) =>
      _perHost && host != null ? _hosts.putIfAbsent(host.toLowerCase(), _Window.new) : _shared;
}

/// One sliding window: the recent starts, and the queue of waiting ones.
final class _Window {
  final sent = ListQueue<DateTime>();
  Future<void> tail = Future.value();

  void trim(DateTime now, Duration per) {
    while (sent.isNotEmpty && now.difference(sent.first) >= per) {
      sent.removeFirst();
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

/// Take a slot of [rate] (the window of [host] for a `perHost` rate), in
/// call order (concurrent starts queue).
Future<void> take(Rate rate, Halt? halt, {String? host}) {
  final w = rate._window(host);
  final next = w.tail.then((_) => _slot(rate, w, halt));
  w.tail = next.then((_) {}, onError: (_) {});
  return next;
}

Future<void> _slot(Rate rate, _Window w, Halt? halt) async {
  if (rate._pause > Duration.zero) await sleep(rate._pause * rate._random.nextDouble(), halt);
  final now = DateTime.now();
  w.trim(now, rate._per);
  if (w.sent.length >= rate._count) {
    final wait = w.sent.first.add(rate._per).difference(now);
    if (wait >= const Duration(seconds: 1)) rate._onWait?.call(wait);
    await sleep(wait, halt);
    if (w.sent.isNotEmpty) w.sent.removeFirst();
  }
  w.sent.addLast(DateTime.now());
}

/// Whether [rate] would start now (for [host]) without waiting.
bool free(Rate rate, {String? host}) {
  final w = rate._window(host);
  w.trim(DateTime.now(), rate._per);
  return w.sent.length < rate._count;
}

/// The wait after a 429: until the oldest start leaves the window, or the
/// server's `Retry-After` when longer. The window is our own memory and is
/// never capped; the server's value is capped at 5 minutes, as in
/// `retry.backoff`, so a hostile header cannot park a script for years.
Duration ban(Rate rate, Duration? server, {String? host}) {
  final sent = rate._window(host).sent;
  var wait = sent.isEmpty ? rate._per : sent.first.add(rate._per).difference(DateTime.now());
  const cap = Duration(minutes: 5);
  if (server != null && server > cap) server = cap;
  if (server != null && server > wait) wait = server;
  if (wait < Duration.zero) wait = Duration.zero;
  if (wait >= const Duration(seconds: 1)) rate._onWait?.call(wait);
  return wait;
}

/// Progress: what `&` attaches ([Probe]), what long work returns ([Task]),
/// what a Tui draws from ([Meter]), and the private run that feeds them.
///
/// A run is one watched piece of work: a pipeline (`reader & bar > file`),
/// a [Task] (`Pool.map(…) & bar`) or a plain future (`work & bar`). It
/// reports `(done, total)` in one [Unit] and ends once, with or without an
/// error. Probes hear the sum of every run they watch.
library;

import 'dart:async';
import 'dart:isolate' show SendPort;

import 'format.dart';

export 'format.dart' show Unit;

/// Something that watches work: attach it with `&` to a reader, a [Task]
/// or any future. Implement [update]; it hears the count so far and the
/// total (null while unknown), summed over every run it watches.
///
/// `Console.bar` draws one; a [Meter] keeps one for a Tui to draw.
abstract mixin class Probe {
  /// [done] of [total] so far.
  void update(int done, int? total);
}

/// Built-in probes hear more than `(done, total)`: which run, the unit,
/// how much of a step counts towards the rate, and the run's end. They
/// register one in [watchers], so none of this is public on them.
abstract interface class Watcher {
  void begin(Object run);
  void report(Object run, int done, int? total, Unit unit, int fresh);
  void finish(Object run, Object? error);
}

/// The [Watcher] behind a built-in probe (`Bar`, [Meter]).
final watchers = Expando<Watcher>();

/// The sum of the runs one probe watches, kept incrementally so a probe
/// shared by thousands of runs costs the same per report as one. Runs add
/// up within a unit; the probe shows the unit it heard last, so one bar can
/// follow a download (bytes) and then its encode (time).
final class Tally {
  final _runs = <Object, (int, int?, Unit)?>{}; // null: begun, nothing reported yet
  final _sums = <Unit, _Sum>{};
  var _pending = 0;
  var _failed = 0;

  /// The unit of the last report.
  Unit? unit;

  /// The sum of the counts in [unit].
  int get done => _sums[unit]?.done ?? 0;

  /// The sum of the totals in [unit]; null while one is unknown.
  int? get total {
    final s = _sums[unit];
    return s == null || _pending > 0 || s.unknown > 0 ? null : s.total;
  }

  /// Runs still open.
  int get open => _runs.length;

  /// Whether a run ended with an error.
  bool get failed => _failed > 0;

  void begin(Object run) {
    if (_runs.containsKey(run)) return;
    _runs[run] = null;
    _pending++;
  }

  void report(Object run, int d, int? t, Unit u) {
    if (!_runs.containsKey(run)) return;
    _take(run);
    unit = u;
    (_sums[u] ??= _Sum()).add(d, t);
    _runs[run] = (d, t, u);
  }

  /// The run is over: a finished one counts as complete (its count, or
  /// its total when it reported one); its sum stays.
  void finish(Object run, {required bool ok}) {
    if (!_runs.containsKey(run)) return;
    final last = _runs[run];
    // A failed run without a total counts what it reached as its total. The
    // shown unit stays the one reported last.
    final shown = unit;
    if (last != null) report(run, ok ? last.$2 ?? last.$1 : last.$1, last.$2 ?? last.$1, last.$3);
    unit = shown;
    if (_runs.remove(run) == null) _pending--;
    if (!ok) _failed++;
  }

  /// Take [run]'s last report out of its unit's sum.
  void _take(Object run) {
    final last = _runs[run];
    if (last == null) {
      _pending--;
    } else {
      _sums[last.$3]!.add(-last.$1, last.$2 == null ? null : -last.$2!, undo: true);
    }
  }
}

final class _Sum {
  var done = 0, total = 0, unknown = 0;

  void add(int d, int? t, {bool undo = false}) {
    done += d;
    if (t == null) {
      unknown += undo ? -1 : 1;
    } else {
      total += t;
    }
  }
}

/// Plain [Probe]s (the user's own) get their sums from here.
final _tallies = Expando<Tally>();

/// One watched piece of work. Created with the probes known at the start;
/// a [Task] adds the ones attached later.
final class Run {
  Run([Iterable<Probe> probes = const []]) {
    probes.forEach(add);
  }

  final _probes = <Probe>[];
  var _done = 0;
  int? _total;
  Unit _unit = Unit.items;
  var _reported = false;
  var _ended = false;
  Object? _error;

  /// Whether anything watches this run (a [Task] picks its cheaper path
  /// when nothing does).
  bool get watched => _probes.isNotEmpty;

  /// Watch this run with [probe] too; it hears what was reported so far.
  void add(Probe probe) {
    if (_probes.contains(probe)) return;
    _probes.add(probe);
    final w = watchers[probe];
    if (w != null) {
      w.begin(this);
      if (_reported) w.report(this, _done, _total, _unit, 0);
      if (_ended) w.finish(this, _error);
    } else {
      final t = _tallies[probe] ??= Tally();
      t.begin(this);
      if (_reported) t.report(this, _done, _total, _unit);
      if (_ended) t.finish(this, ok: _error == null);
      probe.update(t.done, t.total);
    }
  }

  /// [done] of [total] in [unit]; [fresh] is what counts towards the rate
  /// (default: the step since the last report).
  void report(int done, int? total, Unit unit, {int? fresh}) {
    if (_ended) return;
    final step = fresh ?? (done > _done ? done - _done : 0);
    _done = done;
    _total = total;
    _unit = unit;
    _reported = true;
    for (final p in _probes) {
      final w = watchers[p];
      if (w != null) {
        w.report(this, done, total, unit, step);
      } else {
        final t = _tallies[p]!..report(this, done, total, unit);
        p.update(t.done, t.total);
      }
    }
  }

  /// The run is over: [error] null when it succeeded. Idempotent.
  void end([Object? error]) {
    if (_ended) return;
    _ended = true;
    _error = error;
    for (final p in _probes) {
      final w = watchers[p];
      if (w != null) {
        w.finish(this, error);
      } else {
        final t = _tallies[p]!..finish(this, ok: error == null);
        p.update(t.done, t.total);
      }
    }
  }

  /// [input] counted in bytes against [total]; [replay] leading bytes came
  /// from disk (a resumed download) and fill the count but not the rate.
  Stream<List<int>> count(Stream<List<int>> input, {int? total, int replay = 0}) {
    var done = 0, skip = replay;
    report(0, total, Unit.bytes);
    return input.map((chunk) {
      final replayed = skip < chunk.length ? skip : chunk.length;
      skip -= replayed;
      done += chunk.length;
      report(done, total ?? _total, Unit.bytes, fresh: chunk.length - replayed);
      return chunk;
    });
  }

  /// [input], ending this run when it ends: done, failed, or cancelled.
  Stream<List<int>> wrap(Stream<List<int>> input) async* {
    var ok = false;
    try {
      yield* input;
      ok = true;
    } catch (e) {
      end(e);
      rethrow;
    } finally {
      end(ok ? null : const _Cancelled());
    }
  }
}

final class _Cancelled {
  const _Cancelled();
}

/// A probe that passes what it hears on to [run]: how a Future mirror
/// (`Future<Dir>.copy`) hands its inner task's progress to its own.
Probe relay(Run run) => _Relay(run);

final class _Relay with Probe {
  _Relay(Run run) {
    watchers[this] = _RelayWatch(run);
  }

  @override
  void update(int done, int? total) {}
}

final class _RelayWatch implements Watcher {
  _RelayWatch(this._run);

  final Run _run;

  @override
  void begin(Object run) {}

  @override
  void report(Object run, int done, int? total, Unit unit, int fresh) => _run.report(done, total, unit, fresh: fresh);

  @override
  void finish(Object run, Object? error) {}
}

/// A probe in a download isolate that posts `[done, total]` to [port], at
/// most every 100 ms (and the last count), for the spawner to draw.
Probe portProbe(SendPort port) => _PortProbe(port);

final class _PortProbe with Probe {
  _PortProbe(this._port);

  final SendPort _port;
  var _last = 0;
  final _clock = Stopwatch()..start();

  @override
  void update(int done, int? total) {
    final now = _clock.elapsedMilliseconds;
    if (now - _last < 100 && done != total) return;
    _last = now;
    _port.send([done, total]);
  }
}

/// A source whose work happens before its bytes exist (an encode, a 7z
/// built by 7-Zip) registers here how to stream while reporting it.
final working = Expando<Stream<List<int>> Function(Run run)>();

/// A writer that works after its input ends (a solid 7z, a RAR) registers
/// here how to consume while reporting it.
final writing = Expando<Future<void> Function(Stream<List<int>> input, Run run)>();

/// Set by `src/exit.dart` once it watches signals: how a `>` run fails on
/// Ctrl-C. Null until then (no watcher: Ctrl-C ends the process anyway), so
/// a script that never waits on the toolkit pays nothing for it.
Stream<List<int>> Function(Stream<List<int>> bytes)? runGuard;

/// A [Future] that counts its progress: what long work returns
/// (`Pool.map`, `Dir.copy`, `Video.compress`). Watch it with `&`:
///
/// ```dart
/// final pages = await (Pool.map(urls, fetch) & Console.bar('pages'));
/// ```
///
/// It is a plain future otherwise: `await` it, chain it, `Future.wait` it.
final class Task<T> implements Future<T> {
  Task._(this._future, this._run);

  final Future<T> _future;
  final Run _run;

  /// Watch this work with [probe]; null skips. Returns this task.
  Task<T> operator &(Probe? probe) {
    if (probe != null) _run.add(probe);
    return this;
  }

  @override
  Stream<T> asStream() => _future.asStream();

  @override
  Future<T> catchError(Function onError, {bool Function(Object error)? test}) =>
      _future.catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(T value) onValue, {Function? onError}) =>
      _future.then(onValue, onError: onError);

  @override
  Future<T> timeout(Duration timeLimit, {FutureOr<T> Function()? onTimeout}) =>
      _future.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<T> whenComplete(FutureOr<void> Function() action) => _future.whenComplete(action);
}

/// Start [body] on a microtask, so the probes attached in the same
/// expression (`task(…) & bar`) are known before it runs; it reports
/// through its run, which ends when the body does.
Task<T> task<T>(Future<T> Function(Run run) body) {
  final run = Run();
  final done = Completer<T>.sync();
  scheduleMicrotask(() async {
    try {
      final value = await body(run);
      run.end();
      done.complete(value);
    } catch (e, st) {
      run.end(e);
      done.completeError(e, st);
    }
  });
  return Task._(done.future, run);
}

/// Any future, watched: a probe shows a spinner until it completes.
///
/// ```dart
/// final doc = await (page(url) & Console.bar('reading the list'));
/// ```
extension Watch<T> on Future<T> {
  /// Watch this future with [probe] (a spinner, since it counts nothing);
  /// null skips. Completes with this future's value or error.
  Future<T> operator &(Probe? probe) {
    if (probe == null) return this;
    final run = Run([probe]);
    return then(
      (v) {
        run.end();
        return v;
      },
      onError: (Object e, StackTrace st) {
        run.end(e);
        Error.throwWithStackTrace(e, st);
      },
    );
  }
}

/// Progress to draw by hand, as in a Tui: the count, the total and the
/// current rate of everything it watches.
///
/// ```dart
/// final meter = Meter();                           // one per thing you draw
/// await (http.get(url) & meter > Fs.file(name));   // add it to every run it should count
/// r.bar(meter);                                    // 12.1/40 MB  1.2 MB/s
/// ```
///
/// One meter may watch many runs at once; it sums them. Bytes a resumed
/// download replays from its `.part` fill the count but not the rate.
/// [update] sets a count by hand (`Meter()..update(done, queued)`); a meter
/// is one or the other, and mixing them is a [StateError].
final class Meter with Probe {
  /// A meter at zero, counted by the runs it is attached to or by [update].
  Meter() {
    watchers[this] = _MeterWatch(this);
  }

  final _tally = Tally();
  final _window = Window();
  (int, int?)? _hand;
  var _watching = false;

  /// The count so far.
  int done() => _hand?.$1 ?? _tally.done;

  /// The total, null while unknown.
  int? total() => _hand == null ? _tally.total : _hand!.$2;

  /// Per second now (100 ms steps smoothed over about a second), in the
  /// meter's unit.
  double rate() => _window.rate();

  /// Set [done] of [total] by hand, in items. The rate follows the steps
  /// after the first, so a meter made to draw a count (`Meter()..update(done,
  /// total)`) shows no rate.
  @override
  void update(int done, int? total) {
    if (_watching) throw StateError('this Meter counts the runs it watches; a count by hand is a Meter of its own');
    final before = _hand?.$1;
    _hand = (done, total);
    if (before != null) _window.add(done - before);
  }
}

final class _MeterWatch implements Watcher {
  _MeterWatch(this._m);

  final Meter _m;

  @override
  void begin(Object run) {
    if (_m._hand != null) {
      throw StateError('this Meter is counted by hand (update); a watched run needs a Meter of its own');
    }
    _m._watching = true;
    _m._tally.begin(run);
  }

  @override
  void report(Object run, int done, int? total, Unit unit, int fresh) {
    _m._tally.report(run, done, total, unit);
    _m._window.add(fresh);
  }

  @override
  void finish(Object run, Object? error) => _m._tally.finish(run, ok: error == null);
}

/// [meter]'s rate, or null when it has counted no step (nothing to show).
double? paceOf(Meter meter) => meter._window.counted == 0 ? null : meter._window.rate();

/// What [meter] counts: bytes, items or time.
Unit unitOf(Meter meter) => meter._hand != null ? Unit.items : meter._tally.unit ?? Unit.items;

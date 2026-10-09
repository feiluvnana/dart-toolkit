part of '../base.dart';

const _clockKey = #dartToolkitClock;

/// Time, as retries, delays, timeouts, debounce and rate meters read it: the time seam.
///
/// Inside `Clock.scope(clock: Clock.fake())`, every timer the body starts (`Future.delayed`,
/// `Timer`, `30.s.delay()`, a stream's `timeout`) waits for the fake to [FakeClock.advance], so
/// a backoff of minutes is tested in no time.
///
/// ```dart
/// final clock = Clock.fake();
/// final done = Clock.scope(() => Retry(3).run(flaky), clock: clock);
/// await clock.advance(1.m);
/// await done;
/// ```
///
/// {@category Utilities}
abstract class Clock {
  const Clock();

  /// The clock of the enclosing [scope], else the system's.
  static Clock get current => Zone.current[_clockKey] as Clock? ?? const _SystemClock();

  /// A clock that moves only when it is told to.
  static FakeClock fake({DateTime? start}) => FakeClock._(start ?? DateTime.utc(2026));

  /// Runs [body] with [clock] as [current]; a [FakeClock] also holds back every timer [body]
  /// starts until it is advanced past it.
  static Future<T> scope<T>(FutureOr<T> Function() body, {required Clock clock}) async {
    final spec = clock is FakeClock ? clock._spec : null;
    return await runZoned(() async => body(), zoneValues: {_clockKey: clock}, zoneSpecification: spec);
  }

  /// The wall-clock time.
  DateTime now();

  /// Time since an arbitrary start that never goes back: for measuring spans.
  Duration get elapsed;
}

final class _SystemClock extends Clock {
  const _SystemClock();

  static final _watch = Stopwatch()..start();

  @override
  DateTime now() => DateTime.now();

  @override
  Duration get elapsed => _watch.elapsed;
}

/// A [Clock] that stands still until [advance] moves it, firing the timers it passes in order.
///
/// {@category Utilities}
final class FakeClock extends Clock {
  final DateTime _start;
  Duration _elapsed = Duration.zero;
  final _timers = <_FakeTimer>[];
  int _made = 0;

  FakeClock._(this._start);

  @override
  DateTime now() => _start.add(_elapsed);

  @override
  Duration get elapsed => _elapsed;

  /// Timers waiting to fire.
  int get pending => _timers.length;

  /// Moves time on by [by], firing each timer it passes at its time, the work each one starts
  /// run before the next fires.
  Future<void> advance(Duration by) async {
    final until = _elapsed + by;
    await _settle();
    while (_timers.isNotEmpty) {
      // The earliest, by one pass: a sort per fired timer made a long backoff test quadratic.
      var at = 0;
      for (var i = 1; i < _timers.length; i++) {
        if (_timers[i].compareTo(_timers[at]) < 0) at = i;
      }
      final next = _timers[at];
      if (next._at > until) break;
      _timers.removeAt(at);
      if (next._at > _elapsed) _elapsed = next._at;
      next._fire();
      await _settle();
    }
    _elapsed = until;
    await _settle();
  }

  /// Lets the microtasks and real zero-length waits that are pending run.
  static Future<void> _settle() async {
    for (var i = 0; i < 4; i++) {
      await Zone.root.run(() => Future<void>.delayed(Duration.zero));
    }
  }

  late final ZoneSpecification _spec = ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) =>
        _add(duration, zone.bindCallbackGuarded(callback), periodic: false),
    createPeriodicTimer: (self, parent, zone, period, callback) {
      late final _FakeTimer timer;
      timer = _add(period, () => zone.runUnaryGuarded(callback, timer), periodic: true);
      return timer;
    },
  );

  _FakeTimer _add(Duration duration, void Function() callback, {required bool periodic}) {
    final timer = _FakeTimer(this, duration < Duration.zero ? Duration.zero : duration, callback, periodic, _made++);
    _timers.add(timer);
    return timer;
  }
}

final class _FakeTimer implements Timer, Comparable<_FakeTimer> {
  final FakeClock _clock;
  final Duration _period;
  final void Function() _callback;
  final bool _periodic;
  final int _order;
  late Duration _at = _clock._elapsed + _period;
  bool _active = true;
  int _tick = 0;

  _FakeTimer(this._clock, this._period, this._callback, this._periodic, this._order);

  void _fire() {
    _tick++;
    if (_periodic) {
      _at += _period == Duration.zero ? const Duration(microseconds: 1) : _period;
      _clock._timers.add(this);
    } else {
      _active = false;
    }
    _callback();
  }

  @override
  int compareTo(_FakeTimer other) {
    final c = _at.compareTo(other._at);
    return c != 0 ? c : _order.compareTo(other._order);
  }

  @override
  void cancel() {
    _active = false;
    _clock._timers.remove(this);
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}

/// A deadline from [ClockInternals.after]: [cancel] is a flag, so a timeout that is almost always
/// cancelled long before it is due costs next to nothing.
final class Deadline {
  final Duration _at;
  void Function()? _fire;
  final _Deadlines _queue;

  Deadline._(this._at, this._fire, this._queue);

  /// It will not fire.
  void cancel() {
    if (_fire == null) return;
    _fire = null;
    _queue._cancelled();
  }

  bool get isActive => _fire != null;
}

/// The deadlines of one clock, earliest first, with one real timer armed for the earliest live
/// one. Cancelled deadlines are dropped when they reach the front, or in a sweep once they
/// outnumber the live ones; with none live there is no timer, so nothing holds the program open.
final class _Deadlines {
  final Clock _clock;
  final Zone _zone;
  final _heap = <Deadline>[];
  Timer? _timer;
  Duration? _armed;
  int _dead = 0, _live = 0;

  _Deadlines(this._clock, this._zone);

  Deadline add(Duration after, void Function() fire) {
    final d = Deadline._(_clock.elapsed + after, fire, this);
    _live++;
    _push(d);
    if (_armed == null || d._at < _armed!) _arm(d._at);
    return d;
  }

  void _push(Deadline d) {
    _heap.add(d);
    var i = _heap.length - 1;
    while (i > 0) {
      final up = (i - 1) >> 1;
      if (_heap[up]._at <= d._at) break;
      _heap[i] = _heap[up];
      i = up;
    }
    _heap[i] = d;
  }

  Deadline _pop() {
    final top = _heap.first;
    final last = _heap.removeLast();
    if (_heap.isNotEmpty) {
      var i = 0;
      final n = _heap.length;
      while (true) {
        final l = 2 * i + 1;
        if (l >= n) break;
        final r = l + 1;
        final c = r < n && _heap[r]._at < _heap[l]._at ? r : l;
        if (_heap[c]._at >= last._at) break;
        _heap[i] = _heap[c];
        i = c;
      }
      _heap[i] = last;
    }
    return top;
  }

  void _arm(Duration at) {
    _timer?.cancel();
    _armed = at;
    final wait = at - _clock.elapsed;
    _timer = _zone.run(() => Timer(wait.isNegative ? Duration.zero : wait, _run));
  }

  void _run() {
    _timer = null;
    _armed = null;
    final now = _clock.elapsed;
    final due = <void Function()>[];
    while (_heap.isNotEmpty && (_heap.first._fire == null || _heap.first._at <= now)) {
      final d = _pop();
      if (d._fire case final fire?) {
        d._fire = null;
        _live--;
        due.add(fire);
      }
    }
    _dead = 0;
    if (_heap.isNotEmpty) _arm(_heap.first._at);
    for (final fire in due) {
      fire();
    }
  }

  /// Counts a cancel; a heap mostly of cancelled deadlines is rebuilt without them.
  void _cancelled() {
    // The next deadline often comes before the event loop turns (one item after another): the
    // timer is let go only if none has by then, and then nothing holds the program open.
    if (--_live == 0 && !_idleCheck) {
      _idleCheck = true;
      _zone.run(() => Timer.run(_disarmIfIdle));
    }
    if (++_dead < 1024 || _dead * 2 < _heap.length) return;
    final live = [
      for (final d in _heap)
        if (d._fire != null) d,
    ];
    _heap.clear();
    _dead = 0;
    live.forEach(_push);
  }

  bool _idleCheck = false;

  void _disarmIfIdle() {
    _idleCheck = false;
    if (_live > 0) return;
    _timer?.cancel();
    _timer = _armed = null;
    _heap.clear();
    _dead = 0;
  }
}

/// Not API: cheap deadlines on the current [Clock], for timeouts that are nearly always
/// cancelled (a request's, a batch item's).
abstract final class ClockInternals {
  static final _system = _Deadlines(const _SystemClock(), Zone.root);
  static final _fakes = Expando<_Deadlines>('deadlines');

  /// Runs [fire] in the caller's zone after [after] on the current clock, unless the answer is
  /// cancelled first.
  static Deadline after(Duration after, void Function() fire) {
    final clock = Clock.current;
    final queue = clock is FakeClock ? (_fakes[clock] ??= _Deadlines(clock, Zone.current)) : _system;
    return queue.add(after, Zone.current.bindCallback(fire));
  }
}

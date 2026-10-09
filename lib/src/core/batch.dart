part of '../core.dart';

/// Many items, each its own piece of work, at most `concurrency` at a time. It *is* a
/// `Future<List<T>>`: awaiting it gives every value in input order once all have finished, or
/// throws one [BatchException] holding every failure and every success.
///
/// It is made in one way: [IterableParallelize.parallelize] (or a `Pool`'s `map`).
///
/// ```dart
/// final files = await urls.parallelize((u) => u.download(into: 'out')).show('Images');
/// await for (final page in urls.parallelize(fetch).values) { … }   // as each finishes
/// ```
///
/// {@category Concurrency}
abstract interface class Batch<I, T> implements Future<List<T>> {
  /// Items in all: known up front for a list or a set, once the source ends for a stream.
  int? get count;

  /// Every item's statuses as they happen; a listener that comes late first hears each item's
  /// latest status. It ends when the batch does.
  Stream<Status<I, T>> get statuses;

  /// Each success as it finishes, in completion order; a failure does not end it, a cancel ends
  /// it with a [CancelledException]. A listener that comes late first hears those so far.
  Stream<T> get values;

  /// The last status of every item, in input order, once all have finished. Never throws.
  Future<List<Status<I, T>>> get settled;

  /// Item → value, for the successes.
  Future<Map<I, T>> toMap();

  /// Stops it: what runs is [Stopped], nothing new starts, and awaiting it throws a
  /// [CancelledException] with [reason].
  void cancel([String reason = 'cancelled']);

  /// [batches] as one, whose count is the sum of theirs and whose items run at most
  /// [concurrency] at a time in all. Merge batches as they are made: one that has started is a
  /// [StateError].
  static Batch<I, T> merge<I, T>(Iterable<Batch<I, T>> batches, {int concurrency = 4}) {
    _checkConcurrency(concurrency);
    final all = [...batches];
    final gate = _Gate(concurrency);
    for (final batch in all) {
      if (batch is! _Batch<I, T>) {
        throw ArgumentError.value(batch, 'batches', 'Invalid batch: not one parallelize made');
      }
      if (batch._started) throw StateError('Cannot merge a batch that has started: merge batches as they are made');
      batch._gates.add(gate);
      // Its outcome is the merged batch's: it is never news on its own.
      batch._done.future.ignore();
    }
    return _Merged(all.cast<_Batch<I, T>>());
  }
}

/// Bounded parallel work over a list or a set.
///
/// {@category Concurrency}
extension IterableParallelize<I> on Iterable<I> {
  /// [work] for each item, at most [concurrency] at a time: a [Batch].
  ///
  /// [work] may return a [Task] or a [Batch] (or await one): its progress becomes the item's.
  /// [retry] tries a failed item again, each retry a [Warned]; [timeout] fails an attempt that
  /// takes longer with a [TimeoutException] naming the item, cancelling it and freeing its slot.
  /// [isolate] runs [work] on up to [concurrency] long-lived isolates: the item, the result,
  /// the cancel and the progress cross; `Http.scope` and `Shell.scope` settings do not.
  ///
  /// ```dart
  /// final sizes = await files.parallelize((f) => f.size(), concurrency: 8);
  /// final pages = await urls.parallelize((u) => u.get().html, retry: Retry(3), timeout: 1.m).show('Fetching');
  /// ```
  Batch<I, T> parallelize<T>(
    FutureOr<T> Function(I item) work, {
    int concurrency = 4,
    Retry retry = Retry.none,
    Duration? timeout,
    bool isolate = false,
  }) {
    _checkConcurrency(concurrency);
    _checkTimeout(timeout);
    retry._check();
    final items = this;
    final count = items is List<I> || items is Set<I> ? items.length : null;
    return _Batch<I, T>(_IterableSource(items), count, work, concurrency, retry, timeout, isolate);
  }
}

/// Bounded parallel work over items still arriving.
///
/// {@category Concurrency}
extension StreamParallelize<I> on Stream<I> {
  /// [work] for each event, as [IterableParallelize.parallelize] does a list. An event is taken
  /// only when there is room, so the source runs no faster than the work; the count is known
  /// when it ends. An error from the source ends intake, and awaiting the batch throws it.
  ///
  /// ```dart
  /// await dir.files(only: '*.jpg').parallelize((f) => f.compress()).show('Compressing');
  /// ```
  Batch<I, T> parallelize<T>(
    FutureOr<T> Function(I item) work, {
    int concurrency = 4,
    Retry retry = Retry.none,
    Duration? timeout,
    bool isolate = false,
  }) {
    _checkConcurrency(concurrency);
    _checkTimeout(timeout);
    retry._check();
    return _Batch<I, T>(_StreamSource(this), null, work, concurrency, retry, timeout, isolate);
  }
}

void _checkConcurrency(int concurrency) {
  if (concurrency < 1) {
    throw ArgumentError.value(concurrency, 'concurrency', 'Invalid concurrency, expected at least 1');
  }
}

void _checkTimeout(Duration? timeout) {
  if (timeout != null && timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout', 'Invalid timeout, expected more than zero');
  }
}

// ---- running one attempt -------------------------------------------------------------------

/// How one attempt at a body ended.
sealed class _Outcome<T> {}

final class _Value<T> extends _Outcome<T> {
  final T value;
  _Value(this.value);
}

final class _Error<T> extends _Outcome<T> {
  final Object error;
  final StackTrace stackTrace;
  _Error(this.error, this.stackTrace);
}

final class _Stop<T> extends _Outcome<T> {
  final String reason;
  _Stop(this.reason);
}

/// [body] run once in a zone where [token] is the ambient cancel and [sink] hears what work
/// inside it reports. A cancel gives the body [_grace] to stop on its own; [timeout] cancels it
/// and makes the outcome a [TimeoutException] naming [subject].
///
/// A body that answers synchronously is answered synchronously: no microtask is spent on it.
FutureOr<_Outcome<T>> _attempt<T>(
  FutureOr<T> Function() body, {
  required CancelToken token,
  required _Sink sink,
  Duration? timeout,
  String subject = 'work',
  _RetryFrame? frame,
  _Abandon? abandon,
}) {
  final ended = Completer<_Outcome<T>>();
  _Outcome<T>? now;
  var timedOut = false;
  late final void Function() end;
  void settle(_Outcome<T> outcome) {
    if (ended.isCompleted) return;
    end();
    ended.complete(outcome);
  }

  _Outcome<T> classify(Object error, StackTrace stackTrace) => switch (error) {
    _ when timedOut => _Error(TimeoutBridge(subject, timeout!), stackTrace),
    CancelledException(:final reason) when error is! TimeoutException => _Stop(reason),
    _ => _Error(error, stackTrace),
  };

  Timer? grace;
  Deadline? limit;
  // A batch hears its own cancel once for all its items, and abandons the ones still running.
  final void Function() unlisten;
  if (abandon != null && timeout == null) {
    abandon.stop = () => settle(classify(CancelledException.of(token), StackTrace.current));
    unlisten = _noUnlink;
  } else {
    unlisten = token.onCancel(() {
      // Unheard, it ends as it would have had it thrown the cancel: a scope's deadline is a timeout.
      grace = Timer(_grace, () => settle(classify(CancelledException.of(token), StackTrace.current)));
    });
  }
  if (timeout != null) {
    limit = ClockInternals.after(timeout, () {
      timedOut = true;
      token.cancel(_TimedOut(timeout));
    });
  }
  runZoned(() {
    try {
      final result = body();
      if (result is Future<T>) {
        result.then((value) => settle(_Value(value)), onError: (Object e, StackTrace st) => settle(classify(e, st)));
      } else {
        now = _Value(result);
      }
    } catch (e, st) {
      now = classify(e, st);
    }
  }, zoneValues: {_cancelKey: token, _sinkKey: sink, _retryKey: ?frame});
  end = () {
    grace?.cancel();
    limit?.cancel();
    unlisten();
  };

  if (now case final outcome?) {
    end();
    return outcome;
  }
  return ended.future;
}

/// [value] handed to [then]: at once when it is there, else when it arrives.
void _whenReady<T>(FutureOr<T> value, void Function(T value) then) {
  if (value is Future<T>) {
    value.then(then);
  } else {
    then(value);
  }
}

String _reasonOf(CancelToken token) => switch (token.reason) {
  null => 'cancelled',
  final _TimedOut t => '$t',
  final reason => '$reason',
};

void _noUnlink() {}

/// Where an attempt leaves the way to end it unheard, for a batch that hears its cancel once.
final class _Abandon {
  void Function()? stop;
}

/// A fresh token cancelled with [outer], and a function that ends the link.
(CancelToken, void Function()) _linked(CancelToken? outer) {
  final token = CancelToken();
  final unlink = outer?.onCancel(() => token.cancel(outer.reason)) ?? () {};
  return (token, unlink);
}

// ---- where items come from -----------------------------------------------------------------

abstract class _Source<I> {
  /// The next item, or `null` (as a record) when there are none.
  FutureOr<(I,)?> next();

  /// The items never taken, when they can be known without waiting.
  List<I> rest();

  Future<void> close();
}

final class _IterableSource<I> extends _Source<I> {
  final Iterable<I> _items;
  Iterator<I>? _at;

  _IterableSource(this._items);

  @override
  (I,)? next() {
    final at = _at ??= _items.iterator;
    return at.moveNext() ? (at.current,) : null;
  }

  @override
  List<I> rest() {
    final at = _at ??= _items.iterator;
    return [for (; at.moveNext();) at.current];
  }

  @override
  Future<void> close() async {}
}

final class _StreamSource<I> extends _Source<I> {
  final StreamIterator<I> _at;

  _StreamSource(Stream<I> stream) : _at = StreamIterator(stream);

  @override
  Future<(I,)?> next() async => await _at.moveNext() ? (_at.current,) : null;

  @override
  List<I> rest() => const [];

  /// Ends a pending [next] with no item; the cancel closes it so the intake stops at once.
  @override
  Future<void> close() => _closed ??= _at.cancel();
  Future<void>? _closed;
}

/// At most [_free] holders at once, served in turn.
final class _Gate {
  int _free;
  final _waiting = Queue<Completer<void>>();

  _Gate(this._free);

  /// Takes a place when one is free at once.
  bool take() {
    if (_free <= 0) return false;
    _free--;
    return true;
  }

  Future<void> acquire() {
    if (_free > 0) {
      _free--;
      return Future.value();
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    return turn.future;
  }

  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _free++;
    }
  }
}

// ---- the batch -----------------------------------------------------------------------------

final class _Batch<I, T> with _Awaitable<List<T>> implements Batch<I, T> {
  final _Source<I> _source;
  int? _count;
  final FutureOr<T> Function(I item) _work;
  final Retry _retry;
  final Duration? _timeout;
  final _Sink? _parent = Zone.current[_sinkKey] as _Sink?;
  final List<_Gate> _gates;
  final _Isolates<I, T>? _isolates;

  late final CancelToken _token;
  late final void Function() _unlink;
  final _slots = <_Slot<I, T>>[];
  final _completed = <T>[];
  final _warnings = <Warned<I, T>>[];
  final _statusListeners = <StreamController<Status<I, T>>>[];
  final _valueListeners = <StreamController<T>>[];
  final _done = Completer<List<T>>();
  final _end = Completer<List<Status<I, T>>>();
  bool _started = false, _exhausted = false, _finished = false;
  int _running = 0, _ended = 0;
  (Object, StackTrace)? _bug, _sourceError;

  _Batch(this._source, this._count, this._work, int concurrency, this._retry, this._timeout, bool isolate)
    : _gates = [_Gate(concurrency)],
      _isolates = isolate ? _Isolates<I, T>(_work, concurrency) : null {
    final (token, unlink) = _linked(Cancel.token);
    _token = token;
    _unlink = unlink;
    _token.onCancel(() {
      // A source waiting for its next item gives none.
      _source.close().ignore();
      // What has not stopped on its own within the grace is left behind.
      Timer(_grace, () {
        for (final slot in [..._slots]) {
          if (!slot._status.isFinal) slot._abandon.stop?.call();
        }
      });
    });
    // Started on the next microtask, so `Batch.merge` can still share a gate with it.
    scheduleMicrotask(_run);
  }

  @override
  int? get count => _count;

  @override
  Stream<Status<I, T>> get statuses {
    late final StreamController<Status<I, T>> controller;
    controller = StreamController(
      onListen: () {
        _warnings.forEach(controller.add);
        for (final slot in _slots) {
          controller.add(slot.status);
        }
        if (_finished) {
          controller.close();
        } else {
          _statusListeners.add(controller);
        }
      },
      onCancel: () => _statusListeners.remove(controller),
    );
    return controller.stream;
  }

  @override
  Stream<T> get values {
    late final StreamController<T> controller;
    controller = StreamController(
      onListen: () {
        _completed.forEach(controller.add);
        if (_finished) {
          _endValues(controller);
        } else {
          _valueListeners.add(controller);
        }
      },
      onCancel: () => _valueListeners.remove(controller),
    );
    return controller.stream;
  }

  void _endValues(StreamController<T> controller) {
    if (_bug case (final e, final st)) {
      controller.addError(e, st);
    } else if (_token.isCancelled) {
      controller.addError(CancelledException.of(_token));
    }
    controller.close();
  }

  @override
  Future<List<Status<I, T>>> get settled {
    // Whoever reads the outcome this way has handled it.
    _done.future.ignore();
    return _end.future;
  }

  @override
  Future<Map<I, T>> toMap() async {
    final statuses = await settled;
    if (_bug case (final e, final st)) Error.throwWithStackTrace(e, st);
    if (_token.isCancelled) throw CancelledException.of(_token);
    return {
      for (final status in statuses)
        if (status case Done(:final item, :final value)) item: value,
    };
  }

  @override
  void cancel([String reason = 'cancelled']) => _token.cancel(reason);

  Future<void> _run() async {
    _started = true;
    try {
      while (!_token.isCancelled && _bug == null) {
        for (final gate in _gates) {
          if (!gate.take()) await gate.acquire();
        }
        if (_token.isCancelled || _bug != null) {
          _release();
          break;
        }
        final (I,)? next;
        try {
          final pending = _source.next();
          next = pending is Future<(I,)?> ? await pending : pending;
        } catch (e, st) {
          _release();
          _sourceError = (e, st);
          break;
        }
        if (next == null) {
          _release();
          break;
        }
        final slot = _Slot<I, T>(this, _slots.length, next.$1);
        _slots.add(slot);
        _running++;
        slot.run();
      }
    } finally {
      _exhausted = true;
      await _source.close();
      if (_token.isCancelled) _stopRest();
      _count ??= _slots.length;
      _maybeFinish();
    }
  }

  void _release() {
    for (var i = _gates.length - 1; i >= 0; i--) {
      _gates[i].release();
    }
  }

  /// [slot] has its final status: its place is free for the next item.
  void _slotEnded(_Slot<I, T> slot) {
    _running--;
    _ended++;
    _release();
    _progress(slot);
    _maybeFinish();
  }

  /// The items of a list that were never started, each [Stopped].
  void _stopRest() {
    for (final item in _source.rest()) {
      final slot = _Slot<I, T>(this, _slots.length, item).._status = Stopped(item, _reasonOf(_token));
      _slots.add(slot);
      _ended++;
      _emit(slot._status);
    }
  }

  void _emit(Status<I, T> status) {
    for (final listener in _statusListeners) {
      listener.add(status);
    }
    switch (status) {
      case Warned():
        if (_warnings.length < _keptWarnings) _warnings.add(status);
        _parent?._child(status);
      case Done(:final value):
        _completed.add(value);
        for (final listener in _valueListeners) {
          listener.add(value);
        }
      case _:
    }
  }

  /// Tells the work around this batch how far it is: items, the last one heard of as the step;
  /// at most every 50 ms (a display draws no faster), and always the last.
  void _progress(_Slot<I, T> slot) {
    final parent = _parent;
    if (parent == null) return;
    final now = Clock.current.elapsed;
    if (now - _reported < _reportEvery) return;
    _reported = now;
    parent._child(Running(null, received: _ended, total: _count, unit: Unit.items, step: slot.status.label));
  }

  Duration _reported = const Duration(days: -1);
  static const _reportEvery = Duration(milliseconds: 50);

  void _bugged(Object error, StackTrace stackTrace) {
    if (_bug != null) return;
    _bug = (error, stackTrace);
    _token.cancel('a bug: $error');
    _done.completeError(error, stackTrace);
  }

  void _maybeFinish() {
    if (!_exhausted || _running > 0 || _finished) return;
    _finished = true;
    _parent?._child(
      Running(null, received: _ended, total: _slots.length, unit: Unit.items, step: _slots.lastOrNull?.status.label),
    );
    _unlink();
    _isolates?.close();
    _count = _slots.length;
    final statuses = [for (final slot in _slots) slot.status];
    for (final listener in _statusListeners) {
      listener.close();
    }
    _statusListeners.clear();
    for (final listener in _valueListeners) {
      _endValues(listener);
    }
    _valueListeners.clear();
    _end.complete(statuses);
    if (_bug != null) return;
    if (_token.isCancelled) {
      // A stop is no news: it is never an unhandled error.
      _done.future.ignore();
      _done.completeError(CancelledException.of(_token));
      return;
    }
    final failures = [
      for (final s in statuses)
        if (s is Failed<I, T>) s,
    ];
    final values = [
      for (final s in statuses)
        if (s case Done(:final value)) value,
    ];
    if (_sourceError case (final e, final st)) {
      _done.completeError(e, st);
    } else if (failures.isNotEmpty) {
      _done.completeError(BatchException<I, T>(failures, values, statuses.length), failures.first.stackTrace);
    } else {
      _done.complete(values);
    }
  }

  @override
  Future<List<T>> get _future => _done.future;

  @override
  String get _subject => '${_count ?? '?'} items';

  @override
  String toString() => 'Batch(${_slots.length}/${_count ?? '?'})';
}

/// One item of a batch: its status, and the sink what it runs reports to.
final class _Slot<I, T> extends _Sink with _Freshness {
  final _Batch<I, T> _batch;
  final int index;
  final I item;
  late Status<I, T> _status = Running(item, unit: Unit.none);
  final _abandon = _Abandon();

  _Slot(this._batch, this.index, this.item);

  Status<I, T> get status => _status;

  void _set(Status<I, T> status) {
    _status = status;
    _batch._emit(status);
  }

  @override
  void _child(Status<Object?, Object?> status) {
    if (_status.isFinal) return;
    switch (status) {
      case Warned(:final warning):
        _batch._emit(Warned(item, warning, label: status._label ?? _status._label));
      case Running(:final received, :final total, :final unit, :final step):
        // A part's label names the item better than `'$item'` does (a file's `folder/name`).
        _set(
          Running(
            item,
            label: status._label ?? _status._label,
            received: received,
            total: total,
            unit: unit,
            step: step,
          ),
        );
      case _:
    }
  }

  /// Runs the item to its final status, then frees its place in the batch.
  Future<void> run() async {
    try {
      _set(_status);
      final retry = _batch._retry;
      final frame = retry.times > 0 ? _RetryFrame.inside() : null;
      for (var tries = 1; ; tries++) {
        // An attempt needs a token of its own only to be timed out alone.
        final (token, unlink) = _batch._timeout == null ? (_batch._token, _noUnlink) : _linked(_batch._token);
        final isolates = _batch._isolates;
        final attempt = _attempt<T>(
          isolates == null ? () => _batch._work(item) : () => isolates.run(item, this, token),
          token: token,
          sink: this,
          timeout: _batch._timeout,
          subject: _status.label,
          frame: frame,
          abandon: _abandon,
        );
        final outcome = attempt is Future<_Outcome<T>> ? await attempt : attempt;
        unlink();
        switch (outcome) {
          case _Value(:final value):
            return _set(Done(item, value, label: _status._label, fresh: _freshFor(value, true)));
          case _Stop(:final reason):
            return _set(Stopped(item, reason, label: _status._label));
          case _Error(:final error, :final stackTrace) when error is Error:
            _set(Failed(item, error, stackTrace, label: _status._label));
            return _batch._bugged(error, stackTrace);
          case _Error(:final error, :final stackTrace):
            if (frame == null || tries > retry.times || _batch._token.isCancelled || !retry._worth(error, frame)) {
              if (tries > 1) frame?.gaveUp(error);
              return _set(Failed(item, error, stackTrace, label: _status._label));
            }
            final pause = retry._pause(tries);
            _batch._emit(Warned(item, RetryWarning(tries, retry.times, pause, error), label: _status._label));
            try {
              await runZoned(pause.delay, zoneValues: {_cancelKey: _batch._token});
            } on CancelledException {
              return _set(Stopped(item, _reasonOf(_batch._token), label: _status._label));
            }
        }
      }
    } finally {
      _batch._slotEnded(this);
    }
  }
}

/// Batches merged by [Batch.merge].
final class _Merged<I, T> with _Awaitable<List<T>> implements Batch<I, T> {
  final List<_Batch<I, T>> _parts;
  @override
  late final Future<List<T>> _future = _all();

  _Merged(this._parts) {
    // Its outcome is news, as a batch's is, from the start.
    _future;
  }

  @override
  String get _subject => '${count ?? '?'} items';

  Future<List<T>> _all() async {
    final settled = await this.settled;
    final firstBug = _parts.map((p) => p._bug).nonNulls.firstOrNull;
    if (firstBug case (final e, final st)) Error.throwWithStackTrace(e, st);
    if (_parts.where((p) => p._token.isCancelled).firstOrNull case final p?) throw CancelledException.of(p._token);
    final failures = [
      for (final s in settled)
        if (s is Failed<I, T>) s,
    ];
    final values = [
      for (final s in settled)
        if (s case Done(:final value)) value,
    ];
    if (failures.isNotEmpty) {
      Error.throwWithStackTrace(BatchException<I, T>(failures, values, settled.length), failures.first.stackTrace);
    }
    for (final part in _parts) {
      if (part._sourceError case (final e, final st)) Error.throwWithStackTrace(e, st);
    }
    return values;
  }

  @override
  int? get count {
    var sum = 0;
    for (final part in _parts) {
      final n = part.count;
      if (n == null) return null;
      sum += n;
    }
    return sum;
  }

  @override
  Stream<Status<I, T>> get statuses => _mergeStreams([for (final p in _parts) p.statuses]);

  @override
  Stream<T> get values => _mergeStreams([for (final p in _parts) p.values]);

  @override
  Future<List<Status<I, T>>> get settled async => [for (final part in _parts) ...await part.settled];

  @override
  Future<Map<I, T>> toMap() async => {for (final part in _parts) ...await part.toMap()};

  @override
  void cancel([String reason = 'cancelled']) {
    for (final part in _parts) {
      part.cancel(reason);
    }
  }
}

/// [streams] as one, every event of each as it comes; it ends when all have.
Stream<E> _mergeStreams<E>(List<Stream<E>> streams) {
  late final StreamController<E> out;
  final subscriptions = <StreamSubscription<E>>[];
  var open = streams.length;
  out = StreamController<E>(
    onListen: () {
      if (open == 0) out.close();
      for (final stream in streams) {
        subscriptions.add(
          stream.listen(
            out.add,
            onError: out.addError,
            onDone: () {
              if (--open == 0) out.close();
            },
          ),
        );
      }
    },
    onPause: () {
      for (final s in subscriptions) {
        s.pause();
      }
    },
    onResume: () {
      for (final s in subscriptions) {
        s.resume();
      }
    },
    onCancel: () => Future.wait([for (final s in subscriptions) s.cancel()]),
  );
  return out.stream;
}

// ---- isolates ------------------------------------------------------------------------------

/// Up to [_size] long-lived isolates running [_work], started as items need them.
final class _Isolates<I, T> {
  final FutureOr<T> Function(I item) _work;
  final int _size;
  final _idle = <_Worker>[];
  final _all = <_Worker>[];
  final _waiting = Queue<Completer<_Worker>>();
  bool _closed = false;

  _Isolates(this._work, this._size);

  Future<T> run(I item, _Sink sink, CancelToken token) async {
    final worker = await _take();
    try {
      return await worker.run<I, T>(item, sink, token);
    } finally {
      _give(worker);
    }
  }

  Future<_Worker> _take() async {
    if (_idle.isNotEmpty) return _idle.removeLast();
    if (_all.length < _size) {
      final worker = await _Worker.spawn(_work);
      _all.add(worker);
      return worker;
    }
    final turn = Completer<_Worker>();
    _waiting.add(turn);
    return turn.future;
  }

  void _give(_Worker worker) {
    if (_closed) return worker.close();
    if (_waiting.isNotEmpty) return _waiting.removeFirst().complete(worker);
    _idle.add(worker);
  }

  void close() {
    _closed = true;
    for (final worker in _idle) {
      worker.close();
    }
    _idle.clear();
  }
}

/// One isolate of [_Isolates], running one item at a time.
final class _Worker {
  late final Isolate _isolate;
  late final SendPort _inbox;
  final _replies = ReceivePort();
  final _ready = Completer<void>();
  final _pending = <int, (Completer<Object?>, _Sink)>{};
  int _next = 0;

  _Worker._() {
    _replies.listen((message) {
      if (message is SendPort) {
        _inbox = message;
        _ready.complete();
      } else {
        _reply(message);
      }
    });
  }

  static Future<_Worker> spawn(Function work) async {
    final worker = _Worker._();
    worker._isolate = await Isolate.spawn(_serve, (work, worker._replies.sendPort), debugName: 'parallelize');
    await worker._ready.future;
    return worker;
  }

  Future<T> run<I, T>(I item, _Sink sink, CancelToken token) async {
    final id = _next++;
    final done = Completer<Object?>();
    _pending[id] = (done, sink);
    // The item goes first: a cancel the isolate hears before it would be dropped.
    _inbox.send((id, #run, item));
    final unlisten = token.onCancel(() => _inbox.send((id, #cancel, _reasonOf(token))));
    try {
      return await done.future as T;
    } finally {
      unlisten();
    }
  }

  void _reply(Object? message) {
    if (message is! (int, Symbol, Object?)) return;
    final (id, kind, payload) = message;
    final (done, sink) = _pending[id] ?? (null, null);
    if (done == null || sink == null) return;
    switch (kind) {
      case #status:
        sink._child(payload as Status<Object?, Object?>);
      case #value:
        _pending.remove(id);
        done.complete(payload);
      case #error:
        _pending.remove(id);
        final (error, trace) = payload as (Object, String);
        done.completeError(error, StackTrace.fromString(trace));
      case #stopped:
        _pending.remove(id);
        done.completeError(CancelledException(payload as String));
    }
  }

  void close() {
    _inbox.send(null);
    _replies.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

/// The isolate's side of [_Worker]: runs each item it is sent and replies with its statuses and
/// its outcome.
void _serve((Function, SendPort) setup) {
  final (work, replies) = setup;
  final inbox = ReceivePort();
  final tokens = <int, CancelToken>{};
  replies.send(inbox.sendPort);
  inbox.listen((message) async {
    if (message == null) return inbox.close();
    final (id, kind, payload) = message as (int, Symbol, Object?);
    if (kind == #cancel) return tokens[id]?.cancel(payload);
    final token = tokens[id] = CancelToken();
    final outcome = await _attempt<Object?>(
      () => Function.apply(work, [payload]) as FutureOr<Object?>,
      token: token,
      sink: _Relay(id, replies),
    );
    tokens.remove(id);
    switch (outcome) {
      case _Value(:final value):
        replies.send((id, #value, value));
      case _Error(:final error, :final stackTrace):
        try {
          replies.send((id, #error, (error, '$stackTrace')));
        } catch (_) {
          // An error that cannot cross (it holds a port or a native resource) crosses as text.
          replies.send((id, #error, (StateError('$error'), '$stackTrace')));
        }
      case _Stop(:final reason):
        replies.send((id, #stopped, reason));
    }
  });
}

/// The sink inside an isolate: what the work reports crosses to the batch's item.
final class _Relay extends _Sink {
  final int _id;
  final SendPort _replies;

  _Relay(this._id, this._replies);

  @override
  void _child(Status<Object?, Object?> status) {
    try {
      _replies.send((_id, #status, status));
    } catch (_) {
      // A status about an item that cannot cross is left out: the item's own outcome still does.
    }
  }

  @override
  void _childDone(Done<Object?, Object?> done) {}
}

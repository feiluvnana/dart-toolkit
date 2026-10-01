part of '../../async.dart';

/// The work a [Pool] does, one item at a time, in a class you can hold, subclass and test.
///
/// [init] runs once per worker (per isolate) before its first item, [run] per item, [close] when
/// the pool closes. The pool takes a *factory*, so what [init] builds never crosses a port:
///
/// ```dart
/// final class Resize extends Worker<Path, Path> {
///   late final Codec codec;
///   @override
///   Future<void> init() async => codec = await Codec.load();   // once per isolate
///   @override
///   Future<Path> run(Path image) => codec.resize(image, 256);
/// }
///
/// final pool = await Pool.spawn(Resize.new, size: 4);
/// await for (final done in pool.map(images)) { … }
/// await pool.close();
/// ```
///
/// {@category Concurrency}
abstract class Worker<T, R> {
  const Worker();

  /// Runs once, before this worker's first item.
  FutureOr<void> init() {}

  /// The work for one [item].
  FutureOr<R> run(T item);

  /// Runs once, when the pool closes.
  FutureOr<void> close() {}
}

/// A function as a [Worker], for `parallelize`.
final class _Fn<T, R> extends Worker<T, R> {
  final FutureOr<R> Function(T item) _fn;

  const _Fn(this._fn);

  @override
  FutureOr<R> run(T item) => _fn(item);
}

/// [size] long-lived [Worker]s, each on an isolate of its own, fed one item at a time.
///
/// A failing item fails only itself ([run] throws, [map] yields a [Left]); a dead isolate is
/// replaced before the next item. The enclosing [Cancel.scope] fails the items in flight and
/// kills their isolates. `isolate: false` keeps the workers here, for cheap or IO-bound work.
///
/// {@category Concurrency}
final class Pool<T, R> {
  /// How many workers run at once.
  final int size;

  final Worker<T, R> Function() _create;
  final bool _isolate;
  final List<_Slot<T, R>> _idle = [];
  final Set<_Slot<T, R>> _busy = {};
  // FIFO; completing with `null` wakes a waiter to start a worker in place of a dead one.
  final Queue<Completer<_Slot<T, R>?>> _waiting = Queue();
  int _active = 0;
  Completer<void>? _drained;
  int _starting = 0;
  Future<void>? _closed;

  Pool._(this._create, int size, this._isolate) : size = size > 0 ? size : 1;

  /// Starts [size] workers from [create] and waits for every [Worker.init], rethrowing what one
  /// throws. [create] is sent to each isolate, so it must be sendable (e.g. `Resize.new`).
  static Future<Pool<T, R>> spawn<T, R>(Worker<T, R> Function() create, {int size = 4, bool isolate = true}) async {
    final pool = Pool<T, R>._(create, size, isolate);
    final started = await Future.wait([for (var i = 0; i < pool.size; i++) _settled(pool._start)]);
    pool._idle.addAll(started.rights);
    if (started.lefts.firstOrNull case final error?) {
      pool._kill(null);
      throw error;
    }
    return pool;
  }

  static Future<Either<Object, S>> _settled<S>(Future<S> Function() start) async {
    try {
      return Right(await start());
    } catch (error, trace) {
      return Left(error, trace);
    }
  }

  Future<_Slot<T, R>> _start() => _isolate ? _Remote.spawn(_create) : _Local.start(_create());

  /// Runs [item] on the next free worker.
  Future<R> run(T item) async => (await _outcome(item, Cancel.token)).unwrap();

  Future<Either<Object, R>> _outcome(T item, CancelToken? token) async {
    _Slot<T, R>? slot;
    void Function()? unregister;
    try {
      if (_closed != null) throw _poolClosed();
      // The common case takes no await: a free worker is there and nobody queued first.
      slot = _idle.isNotEmpty && _waiting.isEmpty && !(token?.isCancelled ?? false)
          ? _take(_idle.removeLast())
          : await _acquire(token);
      _active++;
      token?.throwIfCancelled();
      // Only an isolate can be stopped mid-item; a worker here finishes what it started.
      if (slot is _Remote<T, R>) unregister = token?.onCancel(() => slot!.kill(_cancelledBy(token)));
      return Right(await slot.run(item));
    } catch (error, trace) {
      return Left(error, trace);
    } finally {
      if (slot != null) {
        unregister?.call();
        _release(slot);
        if (--_active == 0 && _waiting.isEmpty && !(_drained?.isCompleted ?? true)) {
          _drained!.complete();
        }
      }
    }
  }

  /// Hands [slot] to the first waiter, or back to the idle list (also while closing, so [close]
  /// reaches every worker).
  void _release(_Slot<T, R> slot) {
    if (slot.isDead) {
      _busy.remove(slot);
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete(null);
    } else if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(slot); // still busy: it changes hands
    } else {
      _busy.remove(slot);
      _idle.add(slot);
    }
  }

  bool get _hasRoom => _idle.length + _busy.length + _starting < size;

  /// A new busy worker; killed again if the pool closed while it started.
  Future<_Slot<T, R>> _startBusy() async {
    _starting++;
    try {
      final slot = await _start();
      if (_closed != null) {
        slot.kill(_poolClosed());
        throw _poolClosed();
      }
      return _take(slot);
    } finally {
      _starting--;
    }
  }

  /// The next free worker: an idle one, a new one while under [size] (which also replaces a
  /// dead one), or the first to come free.
  Future<_Slot<T, R>> _acquire(CancelToken? token) async {
    while (true) {
      token?.throwIfCancelled();
      if (_closed != null) throw _poolClosed();
      if (_idle.isNotEmpty && _waiting.isEmpty) return _take(_idle.removeLast());
      if (_waiting.isEmpty && _hasRoom) return _startBusy();
      final free = Completer<_Slot<T, R>?>();
      _waiting.add(free);
      // A cancelled scope wakes its own waiters; nothing coming free would.
      final unregister = token?.onCancel(() {
        if (_waiting.remove(free)) free.complete(null);
      });
      final handed = await free.future;
      unregister?.call();
      if (handed != null) return handed;
      if (_hasRoom) return _startBusy();
    }
  }

  _Slot<T, R> _take(_Slot<T, R> slot) {
    _busy.add(slot);
    return slot;
  }

  /// One worker of its own taking indices from [next] until they run out (`parallelize` runs
  /// [size] lanes); a dead worker is replaced before the next item.
  Future<void> _lane(List<T> items, List<Either<Object, R>?> into, int Function() next, CancelToken? token) async {
    _Slot<T, R>? slot;
    final unregister = _isolate ? token?.onCancel(() => slot?.kill(_cancelledBy(token))) : null;
    try {
      for (var i = next(); i < items.length && !(token?.isCancelled ?? false); i = next()) {
        try {
          if (slot == null || slot.isDead) slot = _take(await _start());
          final value = slot.run(items[i]);
          into[i] = Right(value is Future<R> ? await value : value);
        } catch (error, trace) {
          into[i] = Left(error, trace);
        }
      }
    } finally {
      unregister?.call();
      if (slot != null) {
        _busy.remove(slot);
        slot.kill(_poolClosed());
      }
    }
  }

  /// Runs every item of [items], yielding outcomes in completion order.
  ///
  /// At most [size] items are in flight; a busy pool or a paused listener pauses [items]. The
  /// enclosing [Cancel.scope] ends the stream. The pool stays open.
  Stream<Either<Object, R>> map(Stream<T> items) => _map(items);

  Stream<Either<Object, R>> _map(Stream<T> items, {void Function()? onEnd}) {
    CancelToken? token;
    late final StreamController<Either<Object, R>> controller;
    StreamSubscription<T>? subscription;
    void Function()? unregister;
    var active = 0;
    // Two independent reasons to hold the source: every worker busy, and a paused listener.
    var full = false;
    var ended = false;

    void end() {
      if (ended) return;
      ended = true;
      unregister?.call();
      subscription?.cancel();
      subscription = null;
      if (!controller.isClosed) controller.close();
      onEnd?.call();
    }

    controller = StreamController<Either<Object, R>>(
      // Read on listen, not here: a stream is often built in one zone and listened in another.
      onListen: () {
        token = Cancel.token;
        if (token?.isCancelled ?? false) return end();
        unregister = token?.onCancel(end);
        subscription = items.listen(
          (item) {
            if (token?.isCancelled ?? false) return;
            if (++active == size && !full) {
              full = true;
              subscription?.pause();
            }
            _outcome(item, token).then((outcome) {
              if (!controller.isClosed) controller.add(outcome);
              active--;
              if (full) {
                full = false;
                subscription?.resume();
              }
              if (subscription == null && active == 0) end();
            });
          },
          onError: (Object error, StackTrace trace) {
            if (!controller.isClosed) controller.add(Left(error, trace));
          },
          onDone: () {
            subscription = null;
            if (active == 0) end();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        final pending = subscription;
        subscription = null;
        await pending?.cancel();
        end();
      },
    );
    return controller.stream;
  }

  /// Waits for the items in flight, runs every [Worker.close] and ends the isolates. Idempotent;
  /// [run] after it throws.
  Future<void> close() => _closed ??= () async {
    while (_idle.isNotEmpty && _waiting.isNotEmpty) {
      _waiting.removeFirst().complete(_take(_idle.removeLast()));
    }
    if (_active > 0 || _waiting.isNotEmpty) await (_drained = Completer<void>()).future;
    await Future.wait([for (final slot in _idle) slot.close()]);
    _idle.clear();
  }();

  /// Ends everything now, in-flight items included (a function worker has no `close`).
  void _kill(Object? why) {
    _closed ??= Future.value();
    for (final slot in [..._idle, ..._busy]) {
      slot.kill(why ?? _poolClosed());
    }
    _idle.clear();
    for (final waiter in _waiting) {
      waiter.complete(null);
    }
    _waiting.clear();
  }
}

/// One worker the pool can hand an item to.
sealed class _Slot<T, R> {
  bool get isDead;

  FutureOr<R> run(T item);

  /// Runs the worker's `close` and ends it.
  Future<void> close();

  /// Ends it now; an item in flight fails with [why].
  void kill(Object why);
}

/// A worker on this isolate; [kill] cannot interrupt an item in flight, only stop the next.
final class _Local<T, R> extends _Slot<T, R> {
  final Worker<T, R> _worker;
  @override
  bool isDead = false;

  _Local._(this._worker);

  static Future<_Slot<T, R>> start<T, R>(Worker<T, R> worker) async {
    await worker.init();
    return _Local._(worker);
  }

  @override
  FutureOr<R> run(T item) => _worker.run(item);

  @override
  Future<void> close() async {
    isDead = true;
    await _worker.close();
  }

  @override
  void kill(Object why) => isDead = true;
}

/// A worker on an isolate of its own, running [_serve].
final class _Remote<T, R> extends _Slot<T, R> {
  final Isolate _isolate;
  final SendPort _inbox;
  final RawReceivePort _replies;
  final RawReceivePort _exits;
  Completer<Object?>? _pending;
  @override
  bool isDead = false;

  _Remote._(this._isolate, this._inbox, this._replies, this._exits);

  /// Starts an isolate that builds its worker from [create] (the only thing copied) and inits it.
  static Future<_Slot<T, R>> spawn<T, R>(Worker<T, R> Function() create) async {
    final ready = Completer<SendPort>();
    _Remote<T, R>? remote;
    final replies = RawReceivePort();
    final exits = RawReceivePort();
    replies.handler = (Object? message) {
      switch ((remote, message)) {
        case (null, final SendPort inbox):
          ready.complete(inbox);
        case (null, _Failure(:final error, :final trace)):
          ready.completeError(error, trace); // what `init` threw
        case (final remote?, _):
          remote._settle(message);
      }
    };
    exits.handler = (Object? _) {
      if (!ready.isCompleted) ready.completeError(RemoteError('The worker isolate exited while starting.', ''));
      remote?._die(RemoteError('The worker isolate exited before it answered.', ''));
    };
    try {
      final isolate = await Isolate.spawn(
        _serve<T, R>,
        (create, replies.sendPort),
        onExit: exits.sendPort,
        errorsAreFatal: false,
      );
      return remote = _Remote._(isolate, await ready.future, replies, exits);
    } catch (_) {
      replies.close();
      exits.close();
      rethrow;
    }
  }

  @override
  Future<R> run(T item) async {
    if (isDead) throw StateError('The worker isolate has ended.');
    _inbox.send(item); // an item that cannot cross throws here, and fails only itself
    return await (_pending = Completer<Object?>()).future as R;
  }

  void _settle(Object? message) {
    final pending = _pending;
    _pending = null;
    switch (message) {
      case _Failure(:final error, :final trace):
        pending?.completeError(error, trace ?? StackTrace.empty);
      case _Closed(): // the isolate ends on its own
        isDead = true;
        pending?.complete();
        _closePorts();
      case final value:
        pending?.complete(value);
    }
  }

  void _die(Object why) {
    isDead = true;
    final pending = _pending;
    _pending = null;
    pending?.completeError(why);
    _closePorts();
  }

  void _closePorts() {
    _replies.close();
    _exits.close();
  }

  @override
  Future<void> close() {
    if (isDead) return Future.value();
    final closed = _pending = Completer<Object?>();
    _inbox.send(const _Closed());
    return closed.future.then((_) {}, onError: (Object _) {});
  }

  @override
  void kill(Object why) {
    if (isDead) return;
    _die(why);
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// The isolate side: build and `init` the worker, then answer each item with its value or a
/// [_Failure] until [_Closed]. Top level so the spawn copies nothing else; items and values
/// cross bare because a record around each cost a third of a small item's round trip.
Future<void> _serve<T, R>((Worker<T, R> Function(), SendPort) setup) async {
  final (create, reply) = setup;
  final Worker<T, R> worker;
  try {
    worker = create();
    await worker.init();
  } catch (error, trace) {
    _fail(reply, error, trace);
    return;
  }
  final inbox = RawReceivePort();
  inbox.handler = (Object? message) async {
    if (message is! _Closed) {
      try {
        final value = worker.run(message as T);
        final result = value is Future<R> ? await value : value;
        try {
          reply.send(result);
        } catch (e) {
          reply.send(_Failure(ArgumentError('The result cannot be sent back from the isolate: $e'), null));
        }
      } catch (error, trace) {
        _fail(reply, error, trace);
      }
      return;
    }
    inbox.close();
    try {
      await worker.close();
    } finally {
      reply.send(const _Closed());
    }
  };
  reply.send(inbox.sendPort);
}

/// Sends what a worker threw, or — when it cannot cross — its text.
void _fail(SendPort reply, Object error, StackTrace trace) {
  try {
    reply.send(_Failure(error, trace));
  } catch (_) {
    reply.send(_Failure(RemoteError('$error', '$trace'), null));
  }
}

/// A worker's failure on its way back; no caller can produce one, so anything else is a result.
final class _Failure {
  final Object error;
  final StackTrace? trace;

  const _Failure(this.error, this.trace);
}

/// Close, on the way in; closed, on the way back.
final class _Closed {
  const _Closed();
}

StateError _poolClosed() => StateError('The pool is closed.');

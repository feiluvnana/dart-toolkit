part of '../async.dart';

/// The work for one kind of item, with setup: [init] once per worker (per isolate), [run] once
/// per item. Cleanup is `defer`, on either's [Work].
///
/// ```dart
/// final class Thumbnail extends Worker<Path, Path> {
///   late final Chrome chrome;
///
///   @override
///   Future<void> init(Work setup) async {
///     chrome = await Chrome.launch();
///     setup.defer(chrome.close);                 // runs when the pool closes
///   }
///
///   @override
///   Future<Path> run(Path item, Work work) async {
///     work.step('rendering');
///     return render(chrome, item);               // or return a Task: its progress is the item's
///   }
/// }
/// ```
///
/// Items and values that are JSON already (`String`, numbers, `Path`) need nothing more to be
/// kept in a folder store or sent to a runner; any other type gives its [item] or [value]
/// [Serializer].
///
/// {@category Concurrency}
abstract class Worker<I, T> {
  const Worker();

  /// Sets this worker up, once, before its first item. What [setup] defers runs when the pool
  /// closes; its progress shows on the item that is waiting for it.
  FutureOr<void> init(Work setup) {}

  /// The work for one [item]: report on [work], defer its cleanup there.
  FutureOr<T> run(I item, Work work);

  /// How an item is kept and sent, when it is not JSON already.
  Serializer<I>? get item => null;

  /// How a value is kept and sent, when it is not JSON already.
  Serializer<T>? get value => null;
}

/// A [Worker] kept busy: at most [concurrency] of them, started as work needs them, each on an
/// isolate of its own with [isolate].
///
/// A pool is a plain value (a top-level `final` is fine): nothing starts until it is used, and
/// [close] ends it, which `Cli.run` does for you.
///
/// ```dart
/// final thumbnails = Pool(Thumbnail.new, concurrency: 4);
/// final done = await thumbnails.map(images);           // a Batch
/// final one  = await thumbnails.add(cover);            // a Job: await it, pause it…
/// await thumbnails.close();                            // stops everything; cleanups run
/// ```
///
/// With a folder [store], its jobs outlive the program: unfinished ones are continued by the
/// next run that uses the pool, and `add(item, detached: true)` runs one in a runner process
/// that carries on after this program ends (see [serve]).
///
/// {@category Concurrency}
final class Pool<I, T> implements Detachable {
  /// How many workers run at once.
  final int concurrency;

  /// Whether each worker runs on an isolate of its own. What crosses: the item, the value, the
  /// cancel and the progress; `Http.scope` and `Shell.scope` settings do not.
  final bool isolate;

  /// Where its jobs are kept between runs: [Store.memory] (the default) keeps nothing.
  @override
  final Store store;

  final Worker<I, T> Function() _create;

  Pool(Worker<I, T> Function() create, {this.concurrency = 4, this.isolate = false, Store? store})
    : _create = create,
      store = store ?? Store.memory() {
    DetachableBridge.serve ??= (pools) => serve(pools.cast());
    if (concurrency < 1) {
      throw ArgumentError.value(concurrency, 'concurrency', 'Invalid concurrency, expected at least 1');
    }
  }

  late final _lanes = _Lanes<I, T>(this);
  late final _Codec<I, T> _codec = _Codec(_create());
  final _jobs = <String, Job<I, T>>{};
  final _unfinished = <I, Job<I, T>>{};
  final _changes = StreamController<Job<I, T>>.broadcast();
  final _batches = <Batch<I, T>>{};
  bool _started = false;
  Future<void>? _closing;
  Future<void> Function()? _stop;

  /// Whether this process is the runner of this pool's detached jobs.
  bool _isRunner = false;

  /// The connection to the runner of the detached jobs, made when first needed.
  _Link<I, T>? _link;

  /// This program's unfinished jobs, kept in a folder store for the next run.
  _Record<I, T>? _record;

  /// What became of reading the store, which detached jobs wait for.
  Future<void> _opened = Future.value();

  /// Starts it on first use; a [StateError] once it is closed.
  void _use() {
    if (_closing != null) throw StateError('Cannot use the pool: it is closed');
    if (_started) return;
    _started = true;
    IoBridge.stops.add(_stop = close);
    if (store.folder != null && !_isRunner) {
      _opened = _open()..ignore();
      _opened.catchError((Object e, StackTrace st) {
        if (!_changes.isClosed) _changes.addError(e, st);
      });
    }
  }

  /// Reads the folder store: continues what a run that ended left, and shows the runner's jobs.
  Future<void> _open() async {
    final folder = store.folder!;
    final record = _record = _Record(folder, _codec);
    for (final (id, item, paused) in await record.adopt()) {
      if (_closing != null) return;
      final job = Job<I, T>._(this, id, item, isDetached: false);
      _meet(job);
      paused ? job._set(Paused(item)) : _start(job);
    }
    await record.save(_kept());
    if (_link == null) await _Link.find(this, folder);
  }

  /// Every job it knows, in the order it met them: its own and, with a folder store, the
  /// runner's. Finished ones too, until removed.
  List<Job<I, T>> get jobs {
    _use();
    return List.unmodifiable(_jobs.values);
  }

  /// The latest job for [item], or `null` when it has none.
  Job<I, T>? job(I item) {
    _use();
    if (_unfinished[item] case final job?) return job;
    for (final job in _jobs.values.toList().reversed) {
      if (job.item == item) return job;
    }
    return null;
  }

  /// Each job as it changes: added, on its way, paused, finished or removed. A store that cannot
  /// be read is an error here.
  Stream<Job<I, T>> get changes {
    _use();
    return _changes.stream;
  }

  /// [item] as a [Job]: run when a worker is free, and kept by the pool. An equal item that is
  /// not finished gives the job it already has.
  ///
  /// [detached] runs it in this pool's runner process, which outlives this program (started
  /// when none runs): the pool needs a folder [store] for it, else an [ArgumentError]. The item
  /// must make the round trip through its serializer, checked here: an [ArgumentError] if not.
  Job<I, T> add(I item, {bool detached = false}) {
    _use();
    if (detached && store.folder == null) {
      throw ArgumentError.value(
        detached,
        'detached',
        'Invalid detached: the pool needs a folder store to keep the job',
      );
    }
    if (_unfinished[item] case final existing?) return existing;
    if (store.folder != null) _codec.item(item);
    final job = Job<I, T>._(this, _newId(), item, isDetached: detached || _isRunner);
    _meet(job);
    if (detached && !_isRunner) {
      _changed(job, rest: true);
      _sendAdd(job);
    } else {
      _start(job);
    }
    return job;
  }

  Future<void> _sendAdd(Job<I, T> job) async {
    try {
      await _opened;
      final link = _link ??= _Link(this, store.folder!);
      link.add(job);
    } catch (e, st) {
      job._finish(Failed(job.item, e, st));
    }
  }

  /// [items] through the workers, at most [concurrency] at a time: a [Batch], as `parallelize`
  /// makes one, with its [retry] and [timeout]. Closing the pool stops it.
  Batch<I, T> map(Iterable<I> items, {Retry retry = Retry.none, Duration? timeout}) {
    _use();
    return _track(items.parallelize(_runItem, concurrency: concurrency, retry: retry, timeout: timeout));
  }

  Batch<I, T> _through(Stream<I> items, Retry retry, Duration? timeout) {
    _use();
    return _track(items.parallelize(_runItem, concurrency: concurrency, retry: retry, timeout: timeout));
  }

  Batch<I, T> _track(Batch<I, T> batch) {
    _batches.add(batch);
    batch.statuses.listen(null, onDone: () => _batches.remove(batch));
    return batch;
  }

  /// [item] on the next free worker, as a task of its own.
  Task<T> _runItem(I item) => TaskInternals.start(item, '$item', (work) async {
    final lane = await _lanes.take();
    try {
      return await lane.run(item, work);
    } finally {
      _lanes.give(lane);
    }
  });

  /// Stops intake, stops what runs ([Stopped]) and waits for every cleanup, the workers' own
  /// included. Detached jobs run on in their runner; with a folder store, the jobs it stopped
  /// are continued by the next run.
  Future<void> close() => _closing ??= () async {
    if (_stop case final stop?) IoBridge.stops.remove(stop);
    if (!_started) return;
    for (final batch in [..._batches]) {
      batch.cancel(_closedReason);
    }
    final local = [
      for (final job in _jobs.values)
        if (!job._remote && !job.status.isFinal) job,
    ];
    for (final job in local) {
      job._halt(_closedReason);
    }
    await Future.wait([for (final job in local) job.settled]);
    // Their statuses end when they do; their outcome stays the awaiter's to hear.
    await Future.wait([
      for (final batch in [..._batches]) batch.statuses.drain<void>(),
    ]);
    await _opened.catchError((Object _) {}); // what the store said is the changes' error
    await _record?.close(_kept());
    await _link?.close();
    // This program stops watching the detached jobs; they run on in their runner.
    for (final job in [..._jobs.values]) {
      if (job._remote && !job.status.isFinal) job._finish(Stopped(job.item, _detachedReason, label: job.label));
    }
    await _lanes.close();
    await _changes.close();
  }();

  /// The jobs a folder store keeps for the next run: those not finished, and those this pool's
  /// closing stopped.
  List<Job<I, T>> _kept() => [
    for (final job in _jobs.values)
      if (!job._remote &&
          switch (job.status) {
            Stopped(reason: _closedReason) => true,
            final status => !status.isFinal,
          })
        job,
  ];

  void _meet(Job<I, T> job) {
    _jobs[job.id] = job;
    _unfinished[job.item] = job;
  }

  void _start(Job<I, T> job) => job._zone.run(() => TaskInternals.detached(job._go));

  /// [job] moved on, or has a [note]; at [rest] (added, finished, paused, removed) the store
  /// hears of it too.
  void _changed(Job<I, T> job, {bool rest = false, Warned<I, T>? note}) {
    if (job.status.isFinal || job._removed) {
      if (identical(_unfinished[job.item], job)) _unfinished.remove(job.item);
    }
    if (!_changes.isClosed) _changes.add(job);
    if (rest || job.status is Paused) {
      if (_isRunner) {
        _runner?.persist();
      } else if (!job.isDetached) {
        _record?.save(_kept()).ignore();
      }
    }
    if (_isRunner) _runner?.tell(job, note);
  }

  void _forget(Job<I, T> job) {
    _jobs.remove(job.id);
    if (identical(_unfinished[job.item], job)) _unfinished.remove(job.item);
    if (_isRunner) _runner?.removed(job);
  }

  /// In the runner: what serves the detached jobs.
  _Runner<I, T>? _runner;

  /// Serves the pool of [pools] this process was started to run the detached jobs of, and
  /// returns at once in any other process. Make it the first line of `main` (`Cli(pools:)` does
  /// it for you): a runner is this program started again with `DART_TOOLKIT_POOL` naming the
  /// pool's store, and in it this never returns. It runs the jobs, serves every program that
  /// connects, and ends once nothing is connected and nothing is left to run.
  ///
  /// ```dart
  /// final downloads = Pool(FetchBook.new, store: Store.app('books') / 'downloads');
  ///
  /// Future<void> main() async {
  ///   await Pool.serve([downloads]);
  ///   downloads.add(book, detached: true);
  /// }
  /// ```
  static Future<void> serve(List<Pool<Object?, Object?>> pools) async {
    final folder = Env.get<String?>(_runnerKey);
    if (folder == null) return;
    final pool = pools.where((p) => p.store.folder != null && _sameFolder(p.store.folder!, folder)).firstOrNull;
    if (pool == null) {
      _Runner.note(folder, 'no pool of this program keeps its jobs in $folder: pass it to Pool.serve or Cli(pools:)');
      exit(1);
    }
    await pool._serve();
  }

  Future<Never> _serve() {
    _isRunner = true;
    _started = true;
    return (_runner = _Runner(this, store.folder!)).serve();
  }
}

/// The reason a closing pool stops its jobs with.
const _closedReason = 'the pool closed';

/// The reason a closing pool's detached jobs end with in it: they run on elsewhere.
const _detachedReason = 'the pool closed; it runs on in its runner';

bool _sameFolder(String a, String b) => File(a).absolute.path == File(b).absolute.path;

/// A fresh job id: 12 hex digits.
String _newId() => FileBridge.token().substring(0, 12);

/// Items still arriving, through a pool.
///
/// {@category Concurrency}
extension StreamThrough<I> on Stream<I> {
  /// Each event through [pool]'s workers: a [Batch], as [Pool.map] makes one for a list.
  Batch<I, T> through<T>(Pool<I, T> pool, {Retry retry = Retry.none, Duration? timeout}) =>
      pool._through(this, retry, timeout);
}

// ---- workers -------------------------------------------------------------------------------

/// A pool's workers: started as items need them, up to its concurrency, handed out in turn.
final class _Lanes<I, T> {
  final Pool<I, T> _pool;
  final _idle = <_Lane<I, T>>[];
  final _all = <_Lane<I, T>>{};
  final _waiting = Queue<Completer<_Lane<I, T>?>>();
  int _count = 0;
  bool _closed = false;

  _Lanes(this._pool);

  /// The next free worker: an idle one, a new one while under the concurrency, or the first to
  /// come free. A cancel of the enclosing scope while it waits is a [CancelledException].
  Future<_Lane<I, T>> take() async {
    final token = Cancel.token;
    while (true) {
      token?.check();
      if (_closed) throw const CancelledException(_closedReason);
      if (_idle.isNotEmpty && _waiting.isEmpty) return _idle.removeLast();
      if (_count < _pool.concurrency && _waiting.isEmpty) {
        _count++;
        try {
          final lane = _pool.isolate ? await _IsolateLane.start(_pool._create) : await _LocalLane.start(_pool._create);
          _all.add(lane);
          return lane;
        } catch (_) {
          _count--;
          if (_waiting.isNotEmpty) _waiting.removeFirst().complete(null); // the next tries to start one
          rethrow;
        }
      }
      final turn = Completer<_Lane<I, T>?>();
      _waiting.add(turn);
      final unlisten = token?.onCancel(() {
        if (_waiting.remove(turn)) turn.complete(null);
      });
      final lane = await turn.future;
      unlisten?.call();
      if (lane == null) continue; // cancelled, closed, or woken to start one
      if (token?.isCancelled ?? false) {
        give(lane);
        token!.check();
      }
      return lane;
    }
  }

  /// [lane] free again: to the first in line, else idle.
  void give(_Lane<I, T> lane) {
    if (lane.isDead) {
      _all.remove(lane);
      _count--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete(null);
    } else if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(lane);
    } else {
      _idle.add(lane);
    }
  }

  /// Ends every worker, its setup's cleanups run.
  Future<void> close() async {
    _closed = true;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(null);
    }
    await Future.wait([for (final lane in _all) lane.close()]);
    _all.clear();
    _idle.clear();
  }
}

/// One worker.
sealed class _Lane<I, T> {
  bool get isDead;

  /// [item] run on this worker, reporting on [work].
  Future<T> run(I item, Work work);

  /// Ends the worker: its setup's cleanups run.
  Future<void> close();
}

/// A worker here.
final class _LocalLane<I, T> extends _Lane<I, T> {
  final Worker<I, T> _worker;
  final _Setup _setup;

  _LocalLane._(this._worker, this._setup);

  static Future<_LocalLane<I, T>> start<I, T>(Worker<I, T> Function() create) async {
    final setup = _Setup();
    final worker = create();
    try {
      await worker.init(setup);
    } catch (e, st) {
      await setup.end(Failed(null, e, st));
      rethrow;
    }
    return _LocalLane._(worker, setup);
  }

  @override
  bool get isDead => false;

  @override
  Future<T> run(I item, Work work) async => await _worker.run(item, work);

  @override
  Future<void> close() => _setup.end(const Done(null, null));
}

/// The [Work] a worker's `init` is handed: what it defers runs when the worker ends; what it
/// reports goes to the item waiting for it.
final class _Setup implements Work {
  final _cleanups = <FutureOr<void> Function()>[];
  Status<Object?, Object?>? _ended;

  @override
  void amount(int received, {int? total, Unit unit = Unit.bytes}) =>
      TaskInternals.report(Running(null, received: received, total: total, unit: unit));

  @override
  void step(String phrase) => TaskInternals.report(Running(null, step: phrase, unit: Unit.none));

  @override
  void warn(String note) => TaskInternals.warn(NoteWarning(note));

  @override
  void defer(FutureOr<void> Function() cleanup) {
    if (_ended != null) throw StateError('Cannot defer a cleanup of a worker: it has ended');
    _cleanups.add(cleanup);
  }

  @override
  Status<Object?, Object?>? get ended => _ended;

  @override
  bool get isStopped => _ended != null;

  /// Runs the cleanups, last first, with [ended] as how the worker ended.
  Future<void> end(Status<Object?, Object?> ended) async {
    _ended ??= ended;
    while (_cleanups.isNotEmpty) {
      try {
        await _cleanups.removeLast()();
      } catch (e) {
        TaskInternals.warn(NoteWarning('cleanup failed: $e'));
      }
    }
  }
}

// ---- isolates ------------------------------------------------------------------------------

/// A worker on an isolate of its own, running [_serveIsolate].
final class _IsolateLane<I, T> extends _Lane<I, T> {
  final Isolate _isolate;
  final SendPort _inbox;
  final RawReceivePort _replies;
  final RawReceivePort _exits;
  final _pending = <int, _Pending<T>>{};
  final _closed = Completer<void>();
  int _next = 1;
  bool _dead = false;

  _IsolateLane._(this._isolate, this._inbox, this._replies, this._exits);

  /// An isolate that builds its worker from [create] (the one thing copied to it) and inits it;
  /// what init reports goes to the work around this call, what it throws is thrown here.
  static Future<_IsolateLane<I, T>> start<I, T>(Worker<I, T> Function() create) async {
    final ready = Completer<SendPort>();
    final zone = Zone.current;
    _IsolateLane<I, T>? lane;
    SendPort? inbox;
    final replies = RawReceivePort();
    final exits = RawReceivePort();
    replies.handler = (Object? message) {
      if (lane case final lane?) return lane._hear(message);
      switch (message) {
        case final SendPort port:
          inbox = port;
        case (0, #ready, _):
          ready.complete(inbox!);
        case (0, #failed, final Object failure):
          final (error, trace) = _decodeFailure(failure);
          ready.completeError(error, trace);
        case (0, #running, final Running<Object?, Object?> status):
          zone.run(() => TaskInternals.report(status));
        case (0, #warned, final Warning warning):
          zone.run(() => TaskInternals.warn(warning));
      }
    };
    exits.handler = (Object? _) {
      if (!ready.isCompleted) ready.completeError(RemoteError('The worker isolate exited while it started', ''));
      lane?._die();
    };
    try {
      final isolate = await Isolate.spawn(
        _serveIsolate<I, T>,
        (create, replies.sendPort),
        onExit: exits.sendPort,
        errorsAreFatal: false,
        debugName: 'pool',
      );
      return lane = _IsolateLane._(isolate, await ready.future, replies, exits);
    } catch (_) {
      replies.close();
      exits.close();
      rethrow;
    }
  }

  @override
  bool get isDead => _dead;

  @override
  Future<T> run(I item, Work work) async {
    if (_dead) throw RemoteError('The worker isolate has ended', '');
    final id = _next++;
    final pending = _pending[id] = _Pending<T>(Zone.current, work);
    final token = Cancel.token;
    final unlisten = token?.onCancel(() => _inbox.send((id, #cancel, '${token.reason ?? 'cancelled'}')));
    try {
      _inbox.send((id, #run, item)); // an item that cannot cross throws here, and fails only itself
      return await pending.done.future;
    } finally {
      unlisten?.call();
      _pending.remove(id);
    }
  }

  void _hear(Object? message) {
    switch (message) {
      case (0, #closed, _):
        _closed.complete();
      case (final int id, final Symbol kind, final Object? payload):
        final pending = _pending[id];
        if (pending == null) return;
        switch (kind) {
          case #running:
            pending.zone.run(() => TaskInternals.report(payload! as Running<Object?, Object?>));
          case #warned:
            pending.zone.run(() => TaskInternals.warn(payload! as Warning));
          case #stale:
            TaskInternals.stale(pending.work);
          case #value:
            pending.done.complete(payload as T);
          case #error:
            final (error, trace) = _decodeFailure(payload!);
            pending.done.completeError(error, trace);
          case #stopped:
            pending.done.completeError(CancelledException('$payload'));
        }
    }
  }

  void _die() {
    _dead = true;
    for (final pending in _pending.values) {
      if (!pending.done.isCompleted) pending.done.completeError(RemoteError('The worker isolate exited', ''));
    }
    if (!_closed.isCompleted) _closed.complete();
    _replies.close();
    _exits.close();
  }

  @override
  Future<void> close() async {
    if (_dead) return;
    _inbox.send((0, #close, null));
    await _closed.future;
    _dead = true;
    _replies.close();
    _exits.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

final class _Pending<T> {
  final Zone zone;
  final Work work;
  final done = Completer<T>();

  _Pending(this.zone, this.work);
}

/// The isolate side: build and init the worker, then run each item as a task of its own,
/// sending back its progress and its outcome, until told to close.
Future<void> _serveIsolate<I, T>((Worker<I, T> Function(), SendPort) setup) async {
  final (create, reply) = setup;
  final inbox = RawReceivePort();
  reply.send(inbox.sendPort);
  final work = _Setup();
  late final Worker<I, T> worker;
  // What init reports, the item waiting for it hears.
  final init = Task.run('init', (_) async {
    worker = create();
    await worker.init(work);
  });
  final relayInit = init.statuses.listen((status) => _sendStatus(reply, 0, status));
  switch (await init.settled) {
    case Failed(:final error, :final stackTrace):
      await relayInit.cancel();
      await work.end(Failed(null, error, stackTrace));
      reply.send((0, #failed, _encodeFailure(error, stackTrace)));
      inbox.close();
      return;
    case _:
      await relayInit.cancel();
      reply.send((0, #ready, null));
  }
  final running = <int, Task<T>>{};
  inbox.handler = (Object? message) async {
    switch (message) {
      case (final int id, #run, final Object? item):
        final task = running[id] = TaskInternals.start(item, '$item', (work) => worker.run(item as I, work));
        final relay = task.statuses.listen((status) => _sendStatus(reply, id, status));
        final outcome = await task.settled;
        await relay.cancel();
        running.remove(id);
        switch (outcome) {
          case Done(:final value, :final fresh):
            if (!fresh) reply.send((id, #stale, null));
            try {
              reply.send((id, #value, value));
            } catch (e) {
              reply.send((
                id,
                #error,
                _encodeFailure(ArgumentError('Invalid value: it cannot leave the isolate: $e'), StackTrace.current),
              ));
            }
          case Failed(:final error, :final stackTrace):
            reply.send((id, #error, _encodeFailure(error, stackTrace)));
          case Stopped(:final reason):
            reply.send((id, #stopped, reason));
          case _:
        }
      case (final int id, #cancel, final String reason):
        running[id]?.cancel(reason);
      case (0, #close, _):
        inbox.close();
        await work.end(const Done(null, null));
        reply.send((0, #closed, null));
    }
  };
}

void _sendStatus(SendPort reply, int id, Status<Object?, Object?> status) {
  switch (status) {
    case Running(:final received, :final total, :final unit, :final step):
      reply.send((
        id,
        #running,
        Running<Object?, Object?>(null, received: received, total: total, unit: unit, step: step),
      ));
    case Warned(:final warning):
      try {
        reply.send((id, #warned, warning));
      } catch (_) {
        // A warning whose cause cannot cross goes as its text.
        reply.send((id, #warned, NoteWarning('$warning')));
      }
    case _:
  }
}

/// [error] as it crosses back: itself where it can, else as the error table's JSON.
Object _encodeFailure(Object error, StackTrace trace) => (_CrossingError(error), '$trace');

Object _encodeIfNeeded(Object error) {
  try {
    // Probe whether it can be sent: a port to nowhere costs nothing.
    final probe = RawReceivePort();
    try {
      probe.sendPort.send(error);
    } finally {
      probe.close();
    }
    return error;
  } catch (_) {
    return _errorJson(error);
  }
}

/// An error on its way out of an isolate, sent whole where it can be.
final class _CrossingError {
  final Object payload;
  final bool encoded;

  _CrossingError._(this.payload, this.encoded);

  factory _CrossingError(Object error) {
    final sent = _encodeIfNeeded(error);
    return _CrossingError._(sent, !identical(sent, error));
  }
}

(Object, StackTrace) _decodeFailure(Object failure) {
  final (crossing, trace) = failure as (Object, String);
  final error = crossing as _CrossingError;
  return (error.encoded ? _errorOf(error.payload) : error.payload, StackTrace.fromString(trace));
}

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
  final _latest = <I, Job<I, T>>{};

  /// Finished jobs it may forget, oldest first: past [_keptFinished] the oldest goes.
  final _finished = Queue<Job<I, T>>();

  /// Jobs waiting for one of the [concurrency] places, each with the ticket it was queued with.
  final _queue = Queue<(Job<I, T>, int)>();

  /// How many jobs hold a place: waiting for a worker or running on one.
  int _active = 0;

  // Synchronous, so a listener keeps up with progress rather than queueing it; [_tell] keeps a
  // change made by a listener for after the one it hears.
  final _changes = StreamController<Job<I, T>>.broadcast(sync: true);
  final _told = Queue<Job<I, T>>();
  bool _telling = false;
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
    final record = _record = _Record(folder, _codec, _kept);
    for (final (id, item, paused) in await record.adopt()) {
      if (_closing != null) return;
      final job = Job<I, T>._(this, id, item, isDetached: false);
      _meet(job);
      paused ? job._set(Paused(item)) : _start(job);
    }
    await record.save();
    if (_link == null) await _Link.find(this, folder);
  }

  /// Every job it knows, in the order it met them: its own and, with a folder store, the
  /// runner's. Of the finished ones it keeps the last 100 (a [Failed] one until removed or
  /// resumed), so a long-lived pool holds no more.
  List<Job<I, T>> get jobs {
    _use();
    return List.unmodifiable(_jobs.values);
  }

  /// The latest job for [item], or `null` when it has none.
  Job<I, T>? job(I item) {
    _use();
    return _unfinished[item] ?? _latest[item];
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
      _start(job, rest: true);
    }
    return job;
  }

  Future<void> _sendAdd(Job<I, T> job) async {
    try {
      await _opened;
      (_link ??= _Link(this, store.folder!)).add(job);
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
    // Its end, not its statuses: a listener of those would queue every item's progress.
    BatchInternals.ended(batch).then((_) => _batches.remove(batch));
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
    await _record?.close();
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
    _latest[job.item] = job;
  }

  /// [job] waiting for a place, then run: at once while fewer than [concurrency] jobs hold one,
  /// else queued, so a thousand waiting jobs cost a thousand queue entries and nothing more. At
  /// [rest] (just added) the store hears of it.
  void _start(Job<I, T> job, {bool rest = false}) {
    job._stopping = null;
    job._set(Waiting(job.item, label: job.label), rest: rest);
    if (_active < concurrency && _queue.isEmpty) return _launch(job);
    _queue.add((job, job._queue()));
  }

  void _launch(Job<I, T> job) {
    _active++;
    job._zone.run(() => TaskInternals.detached(job._go));
  }

  /// A job let its place go: the next one queued takes it.
  void _vacate() {
    _active--;
    while (_active < concurrency && _queue.isNotEmpty && _closing == null) {
      final (job, ticket) = _queue.removeFirst();
      if (job._dequeue(ticket)) _launch(job);
    }
  }

  /// The most finished jobs it keeps; a [Failed] one, which [Job.resume] can run again, is kept
  /// until removed.
  static const _keptFinished = 100;

  /// [job] moved on, or has a [note]; at [rest] (added, finished, paused, removed) the store
  /// hears of it too.
  void _changed(Job<I, T> job, {bool rest = false, Warned<I, T>? note}) {
    if (job.status.isFinal || job._removed) {
      if (identical(_unfinished[job.item], job)) _unfinished.remove(job.item);
    }
    _tell(job);
    if (rest || job.status is Paused) {
      if (_isRunner) {
        _runner?.persist();
      } else if (!job.isDetached) {
        _record?.save().ignore();
      }
    }
    if (_isRunner) _runner?.tell(job, note);
  }

  /// Every listener of [changes] hears [job]; one a listener's own change brings follows it.
  void _tell(Job<I, T> job) {
    if (_changes.isClosed) return;
    _told.add(job);
    if (_telling) return;
    _telling = true;
    try {
      while (_told.isNotEmpty && !_changes.isClosed) {
        _changes.add(_told.removeFirst());
      }
    } finally {
      _telling = false;
    }
  }

  /// [job] ended [Done] or [Stopped]: kept among the last [_keptFinished], the oldest forgotten.
  /// Nothing is forgotten while closing: the jobs it stops are what the store keeps.
  void _ended(Job<I, T> job) {
    if (job._remote || job._removed || _closing != null) return;
    _finished.add(job);
    while (_finished.length > _keptFinished) {
      final old = _finished.removeFirst();
      if (identical(_jobs[old.id], old) && old.status.isFinal) _forget(old);
    }
  }

  void _forget(Job<I, T> job) {
    _jobs.remove(job.id);
    if (identical(_unfinished[job.item], job)) _unfinished.remove(job.item);
    if (identical(_latest[job.item], job)) _latest.remove(job.item);
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

/// A pool's workers: started as items need them, up to its concurrency, handed out in turn by
/// one [Semaphore] of that many permits.
final class _Lanes<I, T> {
  final Pool<I, T> _pool;
  late final _permits = Semaphore(_pool.concurrency);
  final _idle = <_Lane<I, T>>[];
  final _all = <_Lane<I, T>>{};

  /// What gives back the permit each lane in use holds.
  final _held = <_Lane<I, T>, void Function()>{};
  bool _closed = false;

  _Lanes(this._pool);

  /// The next free worker: an idle one, else a new one, once a permit is free. A cancel of the
  /// enclosing scope while it waits is a [CancelledException], with no permit taken.
  Future<_Lane<I, T>> take() async {
    if (_closed) throw const CancelledException(_closedReason);
    final release = await _permits.acquire();
    try {
      if (_closed) throw const CancelledException(_closedReason);
      while (_idle.isNotEmpty) {
        final lane = _idle.removeLast();
        if (!lane.isDead) return _hold(lane, release);
        _all.remove(lane); // its isolate ended while it was idle: its place starts a new one
      }
      final lane = _pool.isolate ? await _IsolateLane.start(_pool._create) : await _LocalLane.start(_pool._create);
      _all.add(lane);
      return _hold(lane, release);
    } catch (_) {
      release();
      rethrow;
    }
  }

  _Lane<I, T> _hold(_Lane<I, T> lane, void Function() release) {
    _held[lane] = release;
    return lane;
  }

  /// [lane] free again: idle (a dead one dropped), and its permit to the first in line.
  void give(_Lane<I, T> lane) {
    lane.isDead ? _all.remove(lane) : _idle.add(lane);
    _held.remove(lane)?.call();
  }

  /// Ends every worker, its setup's cleanups run. Whoever still waits for one is stopped by the
  /// closing pool's cancel of its work.
  Future<void> close() async {
    _closed = true;
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

/// A worker on an isolate of its own: core's [IsolateBridge], set up as [_LocalLane] is.
final class _IsolateLane<I, T> extends _Lane<I, T> {
  final IsolateBridge<I, T> _isolate;

  _IsolateLane._(this._isolate);

  /// An isolate that builds its worker from [create] (the one thing copied to it) and inits it;
  /// what init reports goes to the work around this call, what it throws is thrown here.
  static Future<_IsolateLane<I, T>> start<I, T>(Worker<I, T> Function() create) async =>
      _IsolateLane._(await IsolateBridge.start<I, T>(_isolateSetup(create), name: 'pool'));

  @override
  bool get isDead => _isolate.isDead;

  @override
  Future<T> run(I item, Work work) => _isolate.run(item);

  @override
  Future<void> close() => _isolate.close();
}

/// [create] as a worker isolate's setup: built here, so the closure copied to the isolate holds
/// only [create]. Its worker is inited as a local one is; its cleanups run when the pool closes.
Future<(FutureOr<T> Function(I, Work), Future<void> Function())> Function() _isolateSetup<I, T>(
  Worker<I, T> Function() create,
) => () async {
  final setup = _Setup();
  final worker = create();
  try {
    await worker.init(setup);
  } catch (e, st) {
    await setup.end(Failed(null, e, st));
    rethrow;
  }
  return (worker.run, () => setup.end(const Done(null, null)));
};

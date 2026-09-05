import 'dart:async';

import 'downloader.dart';
import 'pipeline.dart';

// ============================================================================
// ENGINE & CRAWLER PIPELINE
// ============================================================================

class Stats {
  int scheduled = 0;
  int completed = 0;
  int emitted = 0;
  int bytes = 0;
  DateTime? start;
  DateTime? end;
  String? reason;

  Duration get elapsed {
    if (start == null) return Duration.zero;
    return (end ?? DateTime.now()).difference(start!);
  }

  @override
  String toString() =>
      'Stats(completed: $completed, emitted: $emitted, elapsed: $elapsed)';
}

class QueueAccess<T> {
  final Engine<T> _engine;
  QueueAccess(this._engine);

  int get length => _engine.scheduler.length;
  bool get isEmpty => _engine.scheduler.isEmpty;
  bool get isNotEmpty => _engine.scheduler.isNotEmpty;
  void clear() => _engine.scheduler.clear();
  void add(dynamic requestOrUrl) => _engine.add(requestOrUrl);
}

class EngineEvents<T> {
  final Engine<T> engine;
  EngineEvents(this.engine);

  void Function()? _start;
  void Function(Stats stats)? _done;
  void Function(T item)? _item;
  Process<T>? _response;
  void Function(Response<T> res)? _progress;
  void Function(Object error, StackTrace stack)? _error;

  void start(void Function() handler) => _start = handler;
  void done(void Function(Stats stats) handler) => _done = handler;
  void item(void Function(T item) handler) => _item = handler;
  void response(Process<T> handler) => _response = handler;
  void progress(void Function(Response<T> res) handler) => _progress = handler;
  void error(void Function(Object error, StackTrace stack) handler) =>
      _error = handler;
}

class Engine<T> {
  final Scheduler<T> scheduler;
  final Downloader<T> downloader;
  final Process<T> processor;
  final int concurrency;
  final Duration delay;

  final StreamController<T> _items = StreamController<T>.broadcast();
  final Stats _stats = Stats();

  bool _running = false;
  bool _stopped = false;
  int _active = 0;

  late final QueueAccess<T> queue = QueueAccess<T>(this);
  late final EngineEvents<T> on = EngineEvents<T>(this);
  late final Router<T> router = Router<T>()..attach(this);

  Downloader<T> get dl => downloader;

  Engine({
    Scheduler<T>? scheduler,
    Downloader<T>? downloader,
    Process<T>? onResponse,
    Router<T>? processor,
    this.concurrency = 1,
    this.delay = Duration.zero,
  })  : scheduler = scheduler ?? Scheduler<T>(),
        downloader = downloader ?? HttpDownloader<T>(),
        processor = processor != null
            ? processor.call
            : (onResponse ?? ((res, eng) async {})) {
    this.scheduler.attach(this);
    this.downloader.attach(this);
    if (processor != null) {
      processor.attach(this);
    }
  }

  Stats get stats => _stats;
  Stream<T> get items => _items.stream;
  bool get isRunning => _running;
  bool get stopped => _stopped;
  bool get isIdle => _active == 0 && scheduler.isEmpty;

  void route(Pattern pattern, FutureOr<void> Function(Response<T> res) handler) {
    router.on(pattern, (res, engine) => handler(res));
  }

  void tag(String name, FutureOr<void> Function(Response<T> res) handler) {
    router.tag(name, (res, engine) => handler(res));
  }

  void add(dynamic requestOrUrl) {
    scheduler.attach(this);
    downloader.attach(this);
    scheduler.add(requestOrUrl);
    _stats.scheduled++;
  }

  void url(dynamic url) => add(url);
  void get(dynamic url) => add(Request<T>.get(url));
  void post(dynamic url, {Object? body}) => add(Request<T>.post(url, body: body));

  Future<Response<T>> download(dynamic req) => downloader.download(req);

  Future<void> save(dynamic dest, dynamic source) =>
      downloader.save(dest, source);

  void emit(T item) {
    _items.add(item);
    _stats.emitted++;
    on._item?.call(item);
  }

  void stop([String reason = 'Stopped by user']) {
    _stopped = true;
    _stats.reason = reason;
  }

  Future<Stats> run([Iterable<dynamic>? initialUrls]) async {
    if (_running) throw StateError('Engine is already running');
    _running = true;
    _stopped = false;
    _stats.start = DateTime.now();

    scheduler.attach(this);
    downloader.attach(this);

    if (initialUrls != null) {
      for (final u in initialUrls) {
        add(u);
      }
    }

    on._start?.call();

    final workers = <Future<void>>[];
    for (var i = 0; i < concurrency; i++) {
      workers.add(_worker());
    }

    await Future.wait(workers);

    _stats.end = DateTime.now();
    _running = false;

    on._done?.call(_stats);
    await _items.close();
    await downloader.close();

    return _stats;
  }

  Future<void> _worker() async {
    while (!_stopped) {
      final request = scheduler.next();
      if (request == null) {
        if (_active == 0) break;
        await Future.delayed(const Duration(milliseconds: 50));
        continue;
      }

      _active++;
      try {
        final response = await downloader.download(request);
        _stats.bytes += response.bytes.length;
        response.engine = this;

        if (on._response != null) {
          await on._response!(response, this);
        } else if (router.isNotEmpty) {
          await router(response, this);
        } else {
          await processor(response, this);
        }
        _stats.completed++;
        on._progress?.call(response);
      } catch (e, s) {
        on._error?.call(e, s);
      } finally {
        _active--;
      }

      if (delay > Duration.zero && !_stopped) {
        await Future.delayed(delay);
      }
    }
  }
}

part of '../base.dart';

/// How often one item's progress crosses from its isolate, at most; anything else crosses at once.
const _reportGap = Duration(milliseconds: 100);

/// Not API: one long-lived worker on an isolate of its own, the one `parallelize(isolate: true)`
/// and a `Pool(isolate: true)` both run their items on.
///
/// [start] runs the setup there; [run] sends an item, and what the item reports (its [Running]
/// at most every 100 ms, its warnings at once) reaches the work around the caller, its cancel
/// follows the caller's, and its outcome comes back: the value, a cancel, or the error as it
/// was (an error that cannot cross comes back rebuilt from the error table). An isolate that
/// exits fails what it was running and [isDead] says so.
final class IsolateBridge<I, T> {
  final Isolate _isolate;
  final SendPort _inbox;
  final RawReceivePort _replies;
  final RawReceivePort _exits;
  final _pending = <int, _Pending<T>>{};
  final _closed = Completer<void>();
  int _next = 1;
  bool _dead = false;

  IsolateBridge._(this._isolate, this._inbox, this._replies, this._exits);

  /// An isolate named [name] that runs [setup] once (inside a task whose progress is relayed):
  /// it answers how each item runs and what ends the worker. What setup reports goes to the work
  /// around this call, what it throws is thrown here. [setup] is the one thing copied to the
  /// isolate, so build it in a top-level function that captures only what it needs.
  static Future<IsolateBridge<I, T>> start<I, T>(
    Future<(FutureOr<T> Function(I item, Work work) run, FutureOr<void> Function() close)> Function() setup, {
    required String name,
  }) async {
    final ready = Completer<SendPort>();
    final zone = Zone.current;
    IsolateBridge<I, T>? worker;
    SendPort? inbox;
    final replies = RawReceivePort();
    final exits = RawReceivePort();
    replies.handler = (Object? message) {
      if (worker case final worker?) return worker._hear(message);
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
      worker?._die();
    };
    try {
      final isolate = await Isolate.spawn(
        _serveIsolate<I, T>,
        (setup, replies.sendPort),
        onExit: exits.sendPort,
        errorsAreFatal: false,
        debugName: name,
      );
      return worker = IsolateBridge._(isolate, await ready.future, replies, exits);
    } catch (_) {
      replies.close();
      exits.close();
      rethrow;
    }
  }

  /// Whether the isolate has exited: what it was running failed, and it runs nothing more.
  bool get isDead => _dead;

  /// [item] run on the isolate, reporting to the work around the caller and stopped by its cancel.
  Future<T> run(I item) async {
    if (_dead) throw RemoteError('The worker isolate has ended', '');
    final id = _next++;
    final pending = _pending[id] = _Pending<T>(Zone.current);
    void Function()? unlisten;
    try {
      // The item goes first: a cancel the isolate hears before it would be dropped. One that
      // cannot cross throws here, and fails only itself.
      _inbox.send((id, #run, item));
      final token = Cancel.token;
      unlisten = token?.onCancel(() => _inbox.send((id, #cancel, '${token.reason ?? 'cancelled'}')));
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
            pending.stale = true;
          case #value:
            final value = payload as T;
            // Nothing had to be done: the work around the caller hands back a stale value.
            if (pending.stale) {
              final sink = pending.zone[_sinkKey] as _Sink?;
              sink?._childDone(Done<Object?, Object?>(null, value, fresh: false));
            }
            pending.done.complete(value);
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

  /// Ends the worker once its setup's close has run.
  Future<void> close() async {
    if (_dead) return;
    _inbox.send((0, #close, null));
    await _closed.future;
    _dead = true;
    _replies.close();
    _exits.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  /// [error] as JSON: its type and what rebuilds it. Every type of the error table that `core`
  /// and `dart:io` know comes back as itself; a subtype comes back as the type it extends (a
  /// `StatusException` as an `HttpException`, a `PasswordException` as a `FormatException`).
  static Map<String, Object?> errorJson(Object error) => _errorJson(error);

  /// What [errorJson] wrote, as the error it was.
  static Object errorOf(Object? json) => _errorOf(json);
}

final class _Pending<T> {
  final Zone zone;
  final done = Completer<T>();
  bool stale = false;

  _Pending(this.zone);
}

/// The isolate side: run the setup, then each item as a task of its own, sending back its
/// progress and its outcome, until told to close.
Future<void> _serveIsolate<I, T>(
  (Future<(FutureOr<T> Function(I, Work), FutureOr<void> Function())> Function(), SendPort) message,
) async {
  final (setup, reply) = message;
  final inbox = RawReceivePort();
  reply.send(inbox.sendPort);
  late final FutureOr<T> Function(I item, Work work) run;
  late final FutureOr<void> Function() close;
  // What setup reports, the item waiting for it hears.
  final init = Task.run('init', (_) async {
    final (r, c) = await setup();
    run = r;
    close = c;
  });
  final relayInit = _Relay(reply, 0);
  final relayingInit = init.statuses.listen(relayInit.add);
  final ended = await init.settled;
  await relayingInit.cancel();
  relayInit.flush();
  if (ended case Failed(:final error, :final stackTrace)) {
    _sendFailure(reply, 0, #failed, error, stackTrace);
    inbox.close();
    return;
  }
  reply.send((0, #ready, null));
  final running = <int, Task<T>>{};
  inbox.handler = (Object? message) async {
    switch (message) {
      case (final int id, #run, final Object? item):
        final task = running[id] = TaskInternals.start(item, '$item', (work) => run(item as I, work));
        final relay = _Relay(reply, id);
        final relaying = task.statuses.listen(relay.add);
        final outcome = await task.settled;
        await relaying.cancel();
        relay.flush();
        running.remove(id);
        switch (outcome) {
          case Done(:final value, :final fresh):
            if (!fresh) reply.send((id, #stale, null));
            try {
              reply.send((id, #value, value));
            } on ArgumentError catch (e) {
              final error = ArgumentError(
                'Invalid result: a ${value.runtimeType} cannot cross isolates (${e.message})',
              );
              _sendFailure(reply, id, #error, error, StackTrace.current);
            }
          case Failed(:final error, :final stackTrace):
            _sendFailure(reply, id, #error, error, stackTrace);
          case Stopped(:final reason):
            reply.send((id, #stopped, reason));
          case _:
        }
      case (final int id, #cancel, final String reason):
        running[id]?.cancel(reason);
      case (0, #close, _):
        inbox.close();
        await close();
        reply.send((0, #closed, null));
    }
  };
}

/// One item's statuses on their way out of its isolate: a [Running] at most every [_reportGap]
/// (the latest), anything else at once, after the [Running] it held.
final class _Relay {
  final SendPort _reply;
  final int _id;
  final _since = Stopwatch();
  Running<Object?, Object?>? _held;
  Timer? _timer;

  _Relay(this._reply, this._id);

  void add(Status<Object?, Object?> status) {
    if (status is! Running<Object?, Object?>) {
      flush();
      return _sendStatus(_reply, _id, status);
    }
    if (!_since.isRunning || _since.elapsed >= _reportGap) return _send(status);
    _held = status;
    _timer ??= Timer(_reportGap - _since.elapsed, flush);
  }

  /// Sends the [Running] it holds, if any.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_held case final held?) _send(held);
  }

  void _send(Running<Object?, Object?> status) {
    _held = null;
    _since
      ..reset()
      ..start();
    _sendStatus(_reply, _id, status);
  }
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
      } on ArgumentError catch (_) {
        // A warning whose cause cannot cross goes as its text.
        reply.send((id, #warned, NoteWarning('$warning')));
      }
    case _:
  }
}

/// [error] sent back as [kind] for item [id]: itself where it can cross, else as the error
/// table's JSON. One send either way: a failed send copies nothing.
void _sendFailure(SendPort reply, int id, Symbol kind, Object error, StackTrace trace) {
  try {
    reply.send((id, kind, (error, false, '$trace')));
  } on ArgumentError catch (_) {
    // It holds what cannot cross (a port, a native resource): its type and fields go as JSON.
    reply.send((id, kind, (_errorJson(error), true, '$trace')));
  }
}

(Object, StackTrace) _decodeFailure(Object failure) {
  final (error, encoded, trace) = failure as (Object, bool, String);
  return (encoded ? _errorOf(error) : error, StackTrace.fromString(trace));
}

/// [error] as JSON: its type and what rebuilds it. Every type of the error table that `core`
/// and `dart:io` know comes back as itself; a subtype comes back as the type it extends (a
/// `StatusException` as an `HttpException`, a `PasswordException` as a `FormatException`).
Map<String, Object?> _errorJson(Object error) {
  // `is` tests, not one switch of object patterns: that switch alone cost the import 80 ms.
  Map<String, Object?>? os(OSError? os) => os == null ? null : {'message': os.message, 'code': os.errorCode};
  if (error is CancelledException) return {'type': 'cancelled', 'reason': error.reason};
  if (error is MissingException) return {'type': 'missing', 'what': error.what, 'where': ?error.where};
  if (error is TimeoutException) {
    return {'type': 'timeout', 'message': ?error.message, 'duration': ?error.duration?.inMicroseconds};
  }
  if (error is FileSystemException) {
    final type = error is PathNotFoundException
        ? 'path-not-found'
        : error is PathExistsException
        ? 'path-exists'
        : error is PathAccessException
        ? 'path-access'
        : 'file-system';
    return {'type': type, 'message': error.message, 'path': ?error.path, 'os': ?os(error.osError)};
  }
  if (error is ProcessException) {
    return {
      'type': 'process',
      'executable': error.executable,
      'arguments': error.arguments,
      'message': error.message,
      'code': error.errorCode,
    };
  }
  if (error is SocketException) {
    return {'type': 'socket', 'message': error.message, 'port': ?error.port, 'os': ?os(error.osError)};
  }
  if (error is HttpException) return {'type': 'http', 'message': error.message, 'uri': ?error.uri?.toString()};
  if (error is FormatException) {
    final source = error.source;
    return {
      'type': 'format',
      'message': error.message,
      'offset': ?error.offset,
      if (source is String && source.length <= 4096) 'source': source,
    };
  }
  if (error is ArgumentError) return {'type': 'argument', 'message': ?error.message?.toString(), 'name': ?error.name};
  if (error is StateError) return {'type': 'state', 'message': error.message};
  if (error is UnsupportedError) return {'type': 'unsupported', 'message': ?error.message};
  if (error is Error) return {'type': 'error', 'text': '$error', 'trace': '${error.stackTrace ?? ''}'};
  return {'type': 'exception', 'text': '$error'};
}

/// What [_errorJson] wrote, as the error it was.
Object _errorOf(Object? json) {
  final map = json is Map ? json : <Object?, Object?>{'type': 'exception', 'text': '$json'};
  OSError? os() => switch (map['os']) {
    {'message': final String message, 'code': final int code} => OSError(message, code),
    _ => null,
  };
  final message = '${map['message'] ?? ''}';
  final path = map['path'] as String?;
  return switch (map['type']) {
    'cancelled' => CancelledException('${map['reason']}'),
    'missing' => MissingException('${map['what']}', where: map['where'] as String?),
    'timeout' => _CarriedTimeout(
      map['message'] as String?,
      map['duration'] == null ? null : Duration(microseconds: (map['duration'] as num).toInt()),
    ),
    'path-not-found' => PathNotFoundException(path ?? '', os() ?? const OSError(), message),
    'path-exists' => PathExistsException(path ?? '', os() ?? const OSError(), message),
    'path-access' => PathAccessException(path ?? '', os() ?? const OSError(), message),
    'file-system' => FileSystemException(message, path, os()),
    'process' => ProcessException(
      '${map['executable']}',
      [for (final a in map['arguments'] as List? ?? const []) '$a'],
      message,
      (map['code'] as num?)?.toInt() ?? 0,
    ),
    'socket' => SocketException(message, osError: os(), port: (map['port'] as num?)?.toInt()),
    'http' => HttpException(message, uri: map['uri'] == null ? null : Uri.parse('${map['uri']}')),
    'format' => FormatException(message, map['source'], (map['offset'] as num?)?.toInt()),
    'argument' => ArgumentError(map['message'], map['name'] as String?),
    'state' => StateError(message),
    'unsupported' => UnsupportedError(message),
    'error' => RemoteError('${map['text']}', '${map['trace'] ?? ''}'),
    _ => _Carried('${map['text']}'),
  };
}

/// An exception of a type this library cannot rebuild (another module's), carried as its text.
final class _Carried implements Exception {
  final String text;

  const _Carried(this.text);

  @override
  String toString() => text;
}

/// A [TimeoutException] carried across: it reads as the library's own do, `TimeoutException: <message>`.
final class _CarriedTimeout extends TimeoutException {
  _CarriedTimeout(super.message, [super.duration]);

  @override
  String toString() => message == null ? super.toString() : 'TimeoutException: $message';
}

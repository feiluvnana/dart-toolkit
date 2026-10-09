part of '../core.dart';

const _cancelKey = #dartToolkitCancelToken;

/// Ambient cancellation: a scope holds a token and everything inside it that cooperates stops
/// together, with no token threaded through the calls.
///
/// ```dart
/// final stop = CancelToken();
/// await Cancel.scope(() async {
///   await for (final p in urls.download(to: 'out', concurrency: 8)) show(p);
/// }, token: stop);
/// ```
///
/// `Cli.run` opens one around the action, so a signal or `Console.exit` stops everything inside.
///
/// {@category Concurrency}
abstract final class Cancel {
  /// The token of the enclosing [scope], or `null` outside one.
  static CancelToken? get token => Zone.current[_cancelKey] as CancelToken?;

  /// Whether the enclosing [scope] has been cancelled; `false` outside one.
  static bool get isCancelled => token?.isCancelled ?? false;

  /// Why the enclosing [scope] was cancelled, or `null`.
  static Object? get reason => token?.reason;

  /// Throws a [CancelledException] if the enclosing [scope] has been cancelled; outside one it
  /// does nothing (unlike `.cancellable`, an adapter, which throws a [StateError] there).
  ///
  /// ```dart
  /// for (final item in items) {
  ///   Cancel.check();
  ///   await handle(item);
  /// }
  /// ```
  static void check() => token?.check();

  /// Runs [body] with [token] — or a fresh one — as the ambient token.
  ///
  /// A nested scope is cancelled with the outer one — [token] included, so work that outlives
  /// the body (a response still streaming) stops too, and library code opening its own scope
  /// under `Cli.run` still stops on ^C. [timeout] never reaches [token] (the ambient token is
  /// then a fresh one that [token] cancels), and neither does the way out.
  ///
  /// ```dart
  /// await Cancel.scope(() => 30.s.delay(), timeout: 5.s); // CancelledException after 5 s
  /// ```
  static Future<T> scope<T>(FutureOr<T> Function() body, {CancelToken? token, Duration? timeout}) async {
    final outer = Cancel.token;
    // A timeout must not cancel a caller's shared token for good, so it gets a linked one.
    final own = token != null && timeout == null ? token : CancelToken();
    final unlinks = <void Function()>[];
    if (token != null && !identical(token, own)) {
      unlinks.add(token.onCancel(() => own.cancel(token.reason)));
    }
    if (outer != null && !identical(outer, own) && !identical(outer, token)) {
      unlinks.add(outer.onCancel(() => own.cancel(outer.reason)));
    }
    final timer = timeout == null ? null : Timer(timeout, () => own.cancel(_TimedOut(timeout)));
    try {
      return await runZoned(() async => body(), zoneValues: {_cancelKey: own});
    } finally {
      for (final unlink in unlinks) {
        unlink();
      }
      timer?.cancel();
    }
  }
}

/// Signals cancellation to cooperating asynchronous operations.
///
/// {@category Concurrency}
class CancelToken {
  bool _isCancelled = false;
  // A list linked through its entries: registration order, and removal in O(1) with no hashing.
  _Listener? _first, _last;
  Object? _reason;

  /// Whether cancellation has been requested.
  bool get isCancelled => _isCancelled;

  /// The reason provided for cancellation, if any.
  Object? get reason => _reason;

  /// Requests cancellation of operations listening to this token.
  void cancel([Object? reason]) {
    if (_isCancelled) return;
    _isCancelled = true;
    _reason = reason;
    final pending = <void Function()>[];
    for (var at = _first; at != null; at = at.next) {
      pending.add(at.listener);
      at.token = null;
    }
    _first = _last = null;
    pending.forEach(_notify);
  }

  /// Registers [listener] to run when cancellation is requested.
  ///
  /// Returns a function that unregisters it; call it when the work finishes on its own, or a
  /// long-lived token retains every listener ever registered.
  void Function() onCancel(void Function() listener) {
    if (_isCancelled) {
      _notify(listener);
      return _nothing;
    }
    final entry = _Listener(listener, this, _last);
    if (_last case final last?) {
      last.next = entry;
    } else {
      _first = entry;
    }
    _last = entry;
    return entry.remove;
  }

  static void _nothing() {}

  static void _notify(void Function() listener) {
    try {
      listener();
    } catch (e, st) {
      Zone.current.handleUncaughtError(e, st);
    }
  }

  /// Throws a [CancelledException] if cancellation has already been requested.
  void check() {
    if (_isCancelled) throw CancelledException.of(this);
  }
}

/// One registration of [CancelToken.onCancel]; [remove] (even called twice) takes out only it.
final class _Listener {
  final void Function() listener;
  CancelToken? token;
  _Listener? previous, next;

  _Listener(this.listener, this.token, this.previous);

  void remove() {
    final t = token;
    if (t == null) return;
    token = null;
    if (previous case final p?) {
      p.next = next;
    } else {
      t._first = next;
    }
    if (next case final n?) {
      n.previous = previous;
    } else {
      t._last = previous;
    }
  }
}

/// The work was cancelled, for [reason]: a [Task] or `Batch` that was stopped, a [Cancel.scope]
/// that was cancelled. `Cancelled: <reason>`. A cancel is reported as `Stopped`, never `Failed`.
///
/// {@category Concurrency}
class CancelledException implements Exception {
  final String reason;

  const CancelledException([this.reason = 'cancelled']);

  /// What [token] throws once cancelled: its reason. A [Cancel.scope] that ran out of time
  /// throws one that is a [TimeoutException] too, so either `on` catches it.
  factory CancelledException.of(CancelToken token) => switch (token.reason) {
    final _TimedOut t => _ScopeTimeout(t.after),
    null => const CancelledException(),
    final reason => CancelledException('$reason'),
  };

  @override
  String toString() => 'Cancelled: $reason';
}

/// Why a [Cancel.scope] with a `timeout:` cancelled its token.
final class _TimedOut {
  final Duration after;
  const _TimedOut(this.after);

  @override
  String toString() => 'timed out after ${after.humanized}';
}

/// A [Cancel.scope]'s deadline: a cancel, and a timeout.
final class _ScopeTimeout extends CancelledException implements TimeoutException {
  @override
  final Duration duration;

  _ScopeTimeout(this.duration) : super('timed out after ${duration.humanized}');

  @override
  String? get message => reason;

  /// A timeout, as [TimeoutBridge] writes one: news where a plain cancel is not.
  @override
  String toString() => 'TimeoutException: $reason';
}

/// Cancellation for any [Stream].
///
/// Downloads, crawls and `retry` already read [Cancel.token]; this is for a stream that does not.
///
/// {@category Concurrency}
extension StreamCancelExtensions<T> on Stream<T> {
  /// This stream, ended with a [CancelledException] as soon as the enclosing [Cancel.scope] is
  /// cancelled, as every stream in the package ends: `await for` throws it.
  ///
  /// Throws [StateError] outside a scope.
  Stream<T> get cancellable {
    final token = Cancel.token ?? _noToken();
    late final StreamController<T> controller;
    StreamSubscription<T>? subscription;
    void Function()? unregister;

    void finish() {
      if (controller.isClosed) return;
      // A source that honours the scope too fails its own cancel; that is this stop, not news.
      subscription?.cancel().ignore();
      subscription = null;
      controller
        ..addError(CancelledException.of(token))
        ..close();
    }

    controller = StreamController<T>(
      onListen: () {
        if (token.isCancelled) return finish();
        unregister = token.onCancel(finish);
        subscription = listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            subscription = null;
            unregister?.call();
            if (!controller.isClosed) controller.close();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        unregister?.call();
        final sub = subscription;
        subscription = null;
        await sub?.cancel();
      },
    );
    return controller.stream;
  }
}

/// Cancellation for any [Future].
///
/// {@category Concurrency}
extension FutureCancelExtensions<T> on Future<T> {
  /// This future, failed with a [CancelledException] as soon as the enclosing [Cancel.scope] is
  /// cancelled. The underlying work is not interrupted. Throws [StateError] outside a scope.
  Future<T> get cancellable {
    final token = Cancel.token ?? _noToken();
    if (token.isCancelled) return Future<T>.error(CancelledException.of(token));
    final completer = Completer<T>();
    final unregister = token.onCancel(() {
      if (!completer.isCompleted) completer.completeError(CancelledException.of(token));
    });
    then(
      (value) {
        unregister();
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        unregister();
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }
}

Never _noToken() => throw StateError('No CancelToken in scope: wrap the call in Cancel.scope.');

/// Not API: [body] run in one zone where [token] is the ambient cancel, with [values] beside it:
/// one fork where `Cancel.scope` and a `runZoned` would make two (each copies its parent's values).
abstract final class CancelInternals {
  static R run<R>(R Function() body, CancelToken token, Map<Object?, Object?> values) =>
      runZoned(body, zoneValues: {_cancelKey: token, ...values});
}

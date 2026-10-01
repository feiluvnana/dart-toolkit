part of '../../core.dart';

const _cancelKey = #dartToolkitCancelToken;

/// Ambient cancellation: a scope holds a token and everything inside it that cooperates stops
/// together, with no token threaded through the calls.
///
/// ```dart
/// final stop = CancelToken();
/// await Cancel.scope(() async {
///   await for (final p in pairs.download(concurrency: 8)) show(p);
/// }, token: stop);
/// ```
///
/// `Cli.run` opens one around the action, so a signal or `Lifecycle.exit` stops everything inside.
///
/// {@category Concurrency}
class Cancel {
  /// The token of the enclosing [scope], or `null` outside one.
  static CancelToken? get token => Zone.current[_cancelKey] as CancelToken?;

  /// Whether the enclosing [scope] has been cancelled; `false` outside one.
  static bool get isCancelled => token?.isCancelled ?? false;

  /// Why the enclosing [scope] was cancelled, or `null`.
  static Object? get reason => token?.reason;

  /// Throws a [CancelledException] if the enclosing [scope] has been cancelled; outside one it
  /// does nothing (unlike `.cancellable`, an adapter that would silently do nothing there).
  ///
  /// ```dart
  /// for (final item in items) {
  ///   Cancel.throwIfCancelled();
  ///   await handle(item);
  /// }
  /// ```
  static void throwIfCancelled() => token?.throwIfCancelled();

  /// Runs [body] with [token] — or a fresh one — as the ambient token.
  ///
  /// A nested scope is cancelled with the outer one — [token] included, so work that outlives
  /// the body (a response still streaming) stops too, and library code opening its own scope
  /// under `Cli.run` still stops on ^C. [timeout] never reaches [token] (the ambient token is
  /// then a fresh one that [token] cancels), and neither does the way out.
  ///
  /// ```dart
  /// await Cancel.scope(() => page.download(), timeout: 5.s);
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
    final timer = timeout == null ? null : Timer(timeout, () => own.cancel('Timed out after ${timeout.humanized}.'));
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
  final _listeners = <void Function()>[];
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
    final pending = _listeners.toList();
    _listeners.clear();
    pending.forEach(_notify);
  }

  /// Registers [listener] to run when cancellation is requested.
  ///
  /// Returns a function that unregisters it; call it when the work finishes on its own, or a
  /// long-lived token retains every listener ever registered.
  void Function() onCancel(void Function() listener) {
    if (_isCancelled) {
      _notify(listener);
      return () {};
    }
    // A closure per registration, so an unregister (even called twice) removes only its own.
    void registration() => listener();
    _listeners.add(registration);
    return () => _listeners.remove(registration);
  }

  static void _notify(void Function() listener) {
    try {
      listener();
    } catch (e, st) {
      Zone.current.handleUncaughtError(e, st);
    }
  }

  /// Throws a [CancelledException] if cancellation has already been requested.
  void throwIfCancelled() {
    if (_isCancelled) throw _exception;
  }

  CancelledException get _exception => CancelledException(_reason?.toString() ?? 'Operation was cancelled.');
}

/// Exception thrown when an asynchronous operation is aborted via a [CancelToken].
///
/// {@category Concurrency}
class CancelledException implements Exception {
  final String message;

  const CancelledException([this.message = 'Operation was cancelled.']);

  @override
  String toString() => 'CancelledException: $message';
}

/// Cancellation for any [Stream].
///
/// Downloads, crawls and `retry` already read [Cancel.token]; this is for a stream that does not.
///
/// {@category Concurrency}
extension StreamCancelExtensions<T> on Stream<T> {
  /// This stream, ended when the enclosing [Cancel.scope] is cancelled.
  ///
  /// The stream closes rather than fails; [Cancel.isCancelled] after the loop says which it was:
  ///
  /// ```dart
  /// await for (final item in results.cancellable) { ... }
  /// if (Cancel.isCancelled) return;
  /// ```
  ///
  /// Throws [StateError] outside a scope.
  Stream<T> get cancellable {
    final token = Cancel.token ?? _noToken();
    late final StreamController<T> controller;
    StreamSubscription<T>? subscription;
    void Function()? unregister;

    void finish() {
      if (controller.isClosed) return;
      subscription?.cancel();
      subscription = null;
      controller.close();
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
    if (token.isCancelled) return Future<T>.error(token._exception);
    final completer = Completer<T>();
    final unregister = token.onCancel(() {
      if (!completer.isCompleted) completer.completeError(token._exception);
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

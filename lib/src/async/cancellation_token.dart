part of '../../async.dart';

const _cancelKey = #dartToolkitCancelToken;

/// The ambient cancellation seam.
///
/// A token is not threaded through the calls that cooperate with it; a scope holds one
/// and everything inside it stops together — the same shape as `Http.session`.
///
/// ```dart
/// final stop = CancelToken();
/// await Cancel.session(() async {
///   await for (final p in pairs.download(concurrency: 8)) show(p);
/// }, token: stop);
/// ```
///
/// `Cli.run` opens one around the action, so `ctx.cancel` is already ambient: a signal,
/// [die] or the end of the action stops every download, retry and crawl inside it.
///
/// {@category Concurrency}
class Cancel {
  /// The token of the enclosing [session], or `null` outside one.
  static CancelToken? get token => Zone.current[_cancelKey] as CancelToken?;

  /// Whether the enclosing [session] has been cancelled; `false` outside one.
  static bool get isCancelled => token?.isCancelled ?? false;

  /// Why the enclosing [session] was cancelled, or `null` — outside one, or when it was
  /// cancelled without a reason.
  static Object? get reason => token?.reason;

  /// Throws a [CancelledException] if the enclosing [session] has been cancelled.
  ///
  /// What a loop of its own calls to cooperate:
  ///
  /// ```dart
  /// for (final item in items) {
  ///   Cancel.throwIfCancelled();
  ///   await handle(item);
  /// }
  /// ```
  ///
  /// Outside a session this does nothing, for the same reason [isCancelled] is `false`
  /// there: nothing has cancelled it. That is the difference from
  /// [StreamCancelExtensions.cancellable], which throws a [StateError] outside a session —
  /// an adapter with no scope to bind to would be a wrapper that silently does nothing,
  /// where a reading of the ambient state has a true answer either way.
  static void throwIfCancelled() => token?.throwIfCancelled();

  /// Runs [body] with [token] — or a fresh one — as the ambient token.
  ///
  /// Returns what [body] returns. The token is the caller's to cancel; nothing here
  /// cancels it on the way out, so a token shared between sessions keeps working.
  static Future<T> session<T>(FutureOr<T> Function() body, {CancelToken? token}) async =>
      runZoned(() async => body(), zoneValues: {_cancelKey: token ?? CancelToken()});
}

/// Signals cancellation to cooperating asynchronous operations.
///
/// {@category Concurrency}
class CancelToken {
  bool _isCancelled = false;
  final Set<void Function()> _listeners = {};
  Object? _reason;

  CancelToken();

  /// Whether cancellation has been requested.
  bool get isCancelled => _isCancelled;

  /// The reason provided for cancellation, if any.
  Object? get reason => _reason;

  /// Requests cancellation of operations listening to this token.
  void cancel([Object? reason]) {
    if (_isCancelled) return;
    _isCancelled = true;
    _reason = reason;
    for (final listener in _listeners.toList()) {
      try {
        listener();
      } catch (_) {}
    }
    _listeners.clear();
  }

  /// Registers [listener] to run when cancellation is requested.
  ///
  /// Returns a function that unregisters it. Call it when the work finishes on its
  /// own — a long-lived token otherwise retains every listener ever registered.
  void Function() onCancel(void Function() listener) {
    if (_isCancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Throws a [CancelledException] if cancellation has already been requested.
  void throwIfCancelled() {
    if (_isCancelled) {
      throw CancelledException(_reason?.toString() ?? 'Operation was cancelled.');
    }
  }
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
/// An operation that cooperates by itself — a download, a crawl, `retry` — reads
/// [Cancel.token] and needs none of this; [cancellable] is for a stream that does not.
///
/// {@category Concurrency}
extension StreamCancelExtensions<T> on Stream<T> {
  /// This stream, ended when the enclosing [Cancel.session] is cancelled.
  ///
  /// The stream closes; it does not fail. Whether that is an ending or an error is the
  /// caller's to decide, and [Cancel.isCancelled] after the loop is what says which:
  ///
  /// ```dart
  /// await for (final item in results.cancellable) { ... }
  /// if (Cancel.isCancelled) return;
  /// ```
  ///
  /// Throws [StateError] outside a session: a token is named once, where the scope opens.
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
        if (token.isCancelled) {
          finish();
          return;
        }
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
  /// This future, failed with a [CancelledException] as soon as the enclosing
  /// [Cancel.session] is cancelled.
  ///
  /// A future has no quiet ending to offer — it completes with a value or an error — so
  /// where [StreamCancelExtensions.cancellable] closes, this one fails. The underlying work
  /// is not interrupted. Throws [StateError] outside a session.
  Future<T> get cancellable {
    final token = Cancel.token ?? _noToken();
    if (token.isCancelled) {
      return Future<T>.error(CancelledException(token.reason?.toString() ?? 'Operation was cancelled.'));
    }
    final completer = Completer<T>();
    final unregister = token.onCancel(() {
      if (!completer.isCompleted) {
        completer.completeError(CancelledException(token.reason?.toString() ?? 'Operation was cancelled.'));
      }
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

Never _noToken() => throw StateError('No CancelToken in scope: wrap the call in Cancel.session.');

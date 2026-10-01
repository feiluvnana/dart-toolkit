part of '../../async.dart';

/// An async counting semaphore.
///
/// {@category Concurrency}
class Semaphore {
  int _currentPermits;
  final _waiters = Queue<Completer<void>>();

  Semaphore(int permits) : _currentPermits = permits > 0 ? permits : 1;

  /// Permits available now.
  int get permits => _currentPermits;

  /// Callers waiting for a permit.
  int get waiting => _waiters.length;

  /// A permit, waiting for one if none is free; release it when done. Cancelling the enclosing
  /// [Cancel.scope] removes the waiter and throws [CancelledException].
  Future<Permit> acquire() async {
    final token = Cancel.token;
    token?.throwIfCancelled();
    if (_currentPermits > 0) {
      _currentPermits--;
      return Permit._(this);
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    final unregister = token?.onCancel(() {
      if (_waiters.remove(completer)) completer.completeError(_cancelledBy(token));
    });
    try {
      await completer.future;
    } finally {
      unregister?.call();
    }
    return Permit._(this);
  }

  /// Runs [action] holding a permit.
  Future<T> run<T>(FutureOr<T> Function() action) async {
    final permit = await acquire();
    try {
      return await action();
    } finally {
      permit.release();
    }
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _currentPermits++;
    }
  }
}

/// A held [Semaphore] permit.
///
/// {@category Concurrency}
class Permit {
  final Semaphore _semaphore;
  bool _released = false;

  Permit._(this._semaphore);

  /// Returns the permit to its semaphore; idempotent.
  void release() {
    if (_released) return;
    _released = true;
    _semaphore._release();
  }
}

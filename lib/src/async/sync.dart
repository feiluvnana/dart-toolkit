import 'dart:async';
import 'dart:collection';

/// A concurrency-limiting synchronization primitive.
///
/// {@category Concurrency}
class Semaphore {
  final int maxPermits;
  int _currentPermits;
  final _waiters = Queue<Completer<void>>();

  Semaphore(int permits) : maxPermits = permits > 0 ? permits : 1, _currentPermits = permits > 0 ? permits : 1;

  /// Number of currently available permits.
  int get permits => _currentPermits;

  /// Number of tasks currently waiting for a permit.
  int get waiting => _waiters.length;

  /// Acquires a permit, waiting asynchronously if none are available.
  ///
  /// The returned [Permit] must be released when the work finishes.
  Future<Permit> acquire() async {
    if (_currentPermits > 0) {
      _currentPermits--;
      return Permit._(this);
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
    return Permit._(this);
  }

  /// Executes [action] safely within this semaphore, automatically acquiring
  /// and releasing the permit.
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
      final next = _waiters.removeFirst();
      next.complete();
    } else {
      _currentPermits++;
    }
  }
}

/// A permit representing acquired access to a [Semaphore].
///
/// {@category Concurrency}
class Permit {
  final Semaphore _semaphore;
  bool _released = false;

  Permit._(this._semaphore);

  /// Whether this permit has been released.
  bool get isReleased => _released;

  /// Releases the permit back to its semaphore. Safe and idempotent to call multiple times.
  void release() {
    if (_released) return;
    _released = true;
    _semaphore._release();
  }
}

/// A mutual exclusion lock ensuring only one critical section executes at any time.
///
/// {@category Concurrency}
class Mutex {
  final Semaphore _semaphore = Semaphore(1);

  /// Whether the mutex is currently locked.
  bool get isLocked => _semaphore.permits == 0;

  /// Executes [action] while holding the mutex lock.
  Future<T> run<T>(FutureOr<T> Function() action) => _semaphore.run(action);
}

import 'dart:async';
import 'dart:collection';

/// A concurrency-limiting synchronization primitive.
class Semaphore {
  final int maxPermits;
  int _currentPermits;
  final _waiters = Queue<Completer<void>>();

  Semaphore(this.maxPermits) : _currentPermits = maxPermits > 0 ? maxPermits : 1;

  /// Number of currently available permits.
  int get availablePermits => _currentPermits;

  /// Number of tasks currently waiting for a permit.
  int get queueLength => _waiters.length;

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
class Permit {
  final Semaphore _semaphore;
  bool _released = false;

  Permit._(this._semaphore);

  /// Whether this permit has been released.
  bool get isReleased => _released;

  /// Releases this permit back to the semaphore.
  void release() {
    if (!_released) {
      _released = true;
      _semaphore._release();
    }
  }
}

/// Mutual exclusion lock (a [Semaphore] with capacity 1).
class Mutex extends Semaphore {
  Mutex() : super(1);

  /// Whether the mutex is currently locked.
  bool get isLocked => availablePermits == 0;

  /// Executes [action] exclusively, ensuring no other task runs concurrently.
  Future<T> protect<T>(FutureOr<T> Function() action) => run<T>(action);
}

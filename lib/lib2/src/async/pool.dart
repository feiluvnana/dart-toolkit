import 'dart:async';

/// A fixed-size worker pool for high-throughput batch work.
///
/// ```dart
/// final pool = Pool(4);
/// for (final file in files) {
///   pool.run(() => compress(file));
/// }
/// await pool.wait();
/// await pool.close();
/// ```
final class Pool {
  /// How many jobs may run at once.
  final int size;

  int _active = 0;
  bool _closed = false;
  final List<Completer<void>> _idle = [];
  final List<Completer<void>> _drained = [];

  Pool(this.size) {
    if (size < 1) throw ArgumentError.value(size, 'size', 'Must be at least 1');
  }

  /// Queues [fn], running it as soon as a slot is free, and answers its value.
  Future<T> run<T>(FutureOr<T> Function() fn) async {
    if (_closed) throw StateError('Pool is closed');
    while (_active >= size) {
      final waiter = Completer<void>();
      _idle.add(waiter);
      await waiter.future;
      if (_closed) throw StateError('Pool is closed');
    }
    _active++;
    try {
      return await fn();
    } finally {
      _active--;
      _release();
    }
  }

  void _release() {
    if (_idle.isNotEmpty) {
      _idle.removeAt(0).complete();
      return;
    }
    if (_active == 0) {
      for (final c in _drained) {
        c.complete();
      }
      _drained.clear();
    }
  }

  /// Waits until every queued and running job has finished.
  Future<void> wait() {
    if (_active == 0 && _idle.isEmpty) return Future<void>.value();
    final c = Completer<void>();
    _drained.add(c);
    return c.future;
  }

  /// Waits for the pool to drain and refuses further [run] calls.
  Future<void> close() async {
    if (_closed) return;
    await wait();
    _closed = true;
  }
}

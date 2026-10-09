part of '../async.dart';

/// An async counting semaphore: at most `permits` holders at once, served in turn.
///
/// ```dart
/// final gate = Semaphore(4);
/// await gate.run(() => fetch(url));             // holds a permit for the call
/// final release = await gate.acquire();         // holds one until you say
/// try { … } finally { release(); }
/// ```
///
/// {@category Concurrency}
final class Semaphore {
  int _free;
  final _waiters = Queue<Completer<void>>();

  Semaphore(int permits) : _free = permits {
    if (permits < 1) throw ArgumentError.value(permits, 'permits', 'Invalid permits, expected at least 1');
  }

  /// Runs [action] holding a permit, waiting for one if none is free.
  Future<T> run<T>(FutureOr<T> Function() action) async {
    final release = await acquire();
    try {
      return await action();
    } finally {
      release();
    }
  }

  /// Waits for a permit and returns its release, which gives it back once however often it is
  /// called. Cancelling the enclosing [Cancel.scope] while it waits throws a
  /// [CancelledException], with no permit taken.
  Future<void Function()> acquire() async {
    final token = Cancel.token;
    token?.check();
    if (_free > 0) {
      _free--;
    } else {
      final turn = Completer<void>();
      _waiters.add(turn);
      final unlisten = token?.onCancel(() {
        if (_waiters.remove(turn)) turn.completeError(CancelledException.of(token));
      });
      try {
        await turn.future;
      } finally {
        unlisten?.call();
      }
      // Cancelled as the permit was handed over: it goes to the next in line.
      if (token?.isCancelled ?? false) {
        _release();
        throw CancelledException.of(token!);
      }
    }
    var held = true;
    return () {
      if (!held) return;
      held = false;
      _release();
    };
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _free++;
    }
  }
}

/// # Bounded Work Over a Stream (internal)
///
/// At most *n* workers in flight over a source that arrives over time, in
/// either arrival order or completion order.
///
/// Implementation behind `Pipe.map.async` and `Pipe.where.async`. It lives
/// here rather than in `collection` or `concurrent` because both need it and
/// neither may depend on the other: `collection` is the bottom of the stack
/// by Rule 2, and `concurrent` already sits above it.
///
/// Not exported: reach it through the `Pipe` vocabulary.
library;

import 'dart:async';
import 'dart:collection';

// ============================================================================
// BOUNDED WORK OVER A STREAM (inorder / asdone)
// ============================================================================

/// One task's outcome, never thrown, so an abandoned sibling of a failed task
/// cannot become an unhandled async error.
sealed class _Settled<R> {
  const _Settled();
}

final class _Done<R> extends _Settled<R> {
  const _Done(this.value);
  final R value;
}

final class _Broke<R> extends _Settled<R> {
  const _Broke(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}

Future<_Settled<R>> _attempt<T, R>(
  FutureOr<R> Function(T item) worker,
  T item,
) async {
  try {
    return _Done<R>(await worker(item));
  } catch (error, stack) {
    return _Broke<R>(error, stack);
  }
}

Never _rethrow(_Broke<Object?> broke) =>
    Error.throwWithStackTrace(broke.error, broke.stack);

/// At most [size] workers in flight, yielding in the order elements arrived.
Stream<R> inorder<T, R>(
  Stream<T> source,
  FutureOr<R> Function(T item) worker,
  int size,
) async* {
  final cursor = StreamIterator<T>(source);
  final pending = Queue<Future<_Settled<R>>>();
  try {
    var more = true;
    while (true) {
      while (more && pending.length < size) {
        more = await cursor.moveNext();
        if (!more) break;
        pending.add(_attempt(worker, cursor.current));
      }
      if (pending.isEmpty) break;
      switch (await pending.removeFirst()) {
        case _Done<R>(:final value):
          yield value;
        case final _Broke<R> broke:
          _rethrow(broke);
      }
    }
  } finally {
    await cursor.cancel();
  }
}

/// At most [size] workers in flight, yielding as they finish.
Stream<R> asdone<T, R>(
  Stream<T> source,
  FutureOr<R> Function(T item) worker,
  int size,
) async* {
  final cursor = StreamIterator<T>(source);
  final active = <Future<void>>{};
  final ready = Queue<_Settled<R>>();
  Completer<void>? waiter;

  void arrive(_Settled<R> outcome) {
    ready.add(outcome);
    final woken = waiter;
    waiter = null;
    if (woken != null && !woken.isCompleted) woken.complete();
  }

  try {
    var more = true;
    while (true) {
      while (more && active.length < size) {
        more = await cursor.moveNext();
        if (!more) break;
        late final Future<void> task;
        task = _attempt(worker, cursor.current).then((outcome) {
          active.remove(task);
          arrive(outcome);
        });
        active.add(task);
      }
      while (ready.isEmpty && active.isNotEmpty) {
        await (waiter ??= Completer<void>()).future;
      }
      if (ready.isEmpty) break;
      switch (ready.removeFirst()) {
        case _Done<R>(:final value):
          yield value;
        case final _Broke<R> broke:
          _rethrow(broke);
      }
    }
  } finally {
    await cursor.cancel();
  }
}

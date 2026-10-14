/// A per-scope abort signal, carried in a zone value so a scoped run can cancel
/// its own requests without the process-wide `Http.abort()` and without a
/// public parameter. `http` reads [currentAbort] when a send starts.
library;

import 'dart:async';

/// Fires once; [future] completes when [abort] is called.
final class AbortSignal {
  final _done = Completer<void>();

  bool get aborted => _done.isCompleted;

  Future<void> get future => _done.future;

  void abort() {
    if (!_done.isCompleted) _done.complete();
  }
}

const _key = #dart_toolkit.abort;

/// The signal of the innermost [withAbort], or null.
AbortSignal? currentAbort() => Zone.current[_key] as AbortSignal?;

/// Run [body] with [signal] as [currentAbort].
R withAbort<R>(AbortSignal signal, R Function() body) => runZoned(body, zoneValues: {_key: signal});

/// Wait [d], or less when [signal] fires first; the timer never outlives it.
Future<void> sleep(Duration d, AbortSignal? signal) {
  if (signal == null) return Future<void>.delayed(d);
  if (signal.aborted) return Future<void>.value();
  final done = Completer<void>();
  final timer = Timer(d, done.complete);
  signal.future.then((_) {
    timer.cancel();
    if (!done.isCompleted) done.complete();
  });
  return done.future;
}

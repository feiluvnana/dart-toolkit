part of '../cli.dart';

/// Marks the zone of a `Cli` run with its [_RunState].
const _runKey = #dartToolkitCliRun;

/// A [Cli] run in progress: what its zone knows about it.
final class _RunState {
  /// Whether drawn work ended with failures: the run then exits 1, its lines already said.
  bool failedWork = false;

  /// The handler's work, which a signal cancels.
  Task<void>? task;
}

/// What [Console.exit] throws inside a [Cli] run, to unwind to it. An [Error], so a batch ends at
/// once and rethrows it rather than counting it a failure.
final class _Exit extends Error {
  final String? message;
  final int code;

  _Exit(this.message, this.code);

  @override
  String toString() => 'Console.exit(${message ?? ''}, code: $code)';
}

/// `dart:io`'s `exit`, the terminal put back first; reachable where [Console.exit] shadows it.
Never _terminate(int code) {
  _restoreAll();
  for (final tee in [...Console._tees]) {
    try {
      tee.closeSync();
    } catch (_) {} // best-effort: the log's disk went away
  }
  exit(code);
}

/// Runs and clears every [IoBridge.restores] entry (a picker's raw mode, a hidden echo), so a
/// second call does nothing.
void _restoreAll() {
  for (final restore in [...IoBridge.restores]) {
    IoBridge.restores.remove(restore);
    try {
      restore();
    } catch (_) {} // best-effort: restoring the terminal on the way out
  }
}

/// Watches SIGINT and SIGTERM for [run]: the first puts the terminal back and cancels the
/// handler's work (its cleanups then run), a second leaves at once. Returns the unwatch.
void Function() _watchSignals(_RunState run) {
  var seen = false;
  void signalled(ProcessSignal signal) {
    // A child given the terminal (`Shell.interact`) owns ^C: it handles the key, the run goes on.
    if (ProcessBridge.interactive > 0) return;
    _restoreAll();
    if (seen) {
      ProcessBridge.killHaltedSync();
      _terminate(128 + signal.signalNumber);
    }
    seen = true;
    Console._region.clear();
    run.task?.cancel('Interrupted');
  }

  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  for (final signal in [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm]) {
    try {
      subscriptions.add(signal.watch().listen(signalled));
    } catch (_) {} // a platform that cannot watch this signal
  }
  return () {
    for (final s in subscriptions) {
      s.cancel();
    }
  };
}

/// Runs [cleanups] last first, then every [IoBridge.stops] entry (an open pool), within ten
/// seconds in all; says which were cut short.
Future<void> _closeAll(List<FutureOr<void> Function()> cleanups) async {
  const limit = Duration(seconds: 10);
  final clock = Clock.current;
  final deadline = clock.elapsed + limit;
  var cut = 0;
  Future<void> within(FutureOr<void> Function() cleanup) async {
    final left = deadline - clock.elapsed;
    if (left <= Duration.zero) {
      cut++;
      return;
    }
    try {
      await Future.sync(cleanup).timeout(left);
    } on TimeoutException {
      cut++;
    } catch (e) {
      Console.warn('Cleanup failed: ${_oneLine('$e')}');
    }
  }

  for (final cleanup in cleanups.reversed) {
    await within(cleanup);
  }
  cleanups.clear();
  await Future.wait([
    for (final stop in [...IoBridge.stops]) within(stop),
  ]);
  if (cut > 0) Console.warn('$cut cleanup${cut == 1 ? '' : 's'} cut short after ${limit.humanized}');
}

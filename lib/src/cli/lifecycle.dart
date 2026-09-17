import 'dart:async';
import 'dart:io';

import 'ansi.dart';
import '../util/stdio.dart';

final List<FutureOr<void> Function()> _exitHooks = [];
StreamSubscription<ProcessSignal>? _sigintSub;
StreamSubscription<ProcessSignal>? _sigtermSub;

void _ensureSignalHandlers() {
  if (_sigintSub != null) return;

  void handleSignal(ProcessSignal signal) async {
    await runExitHooks();
    exit(128 + signal.signalNumber);
  }

  try {
    _sigintSub = ProcessSignal.sigint.watch().listen(handleSignal);
  } catch (_) {}

  try {
    if (!Platform.isWindows) {
      _sigtermSub = ProcessSignal.sigterm.watch().listen(handleSignal);
    }
  } catch (_) {}
}

/// Executes all registered exit hooks in registration order.
///
/// {@category CLI}
Future<void> runExitHooks() async {
  for (final hook in List.of(_exitHooks)) {
    try {
      await hook();
    } catch (_) {}
  }
}

/// Clears all registered exit hooks and resets signal listeners.
///
/// {@category CLI}
void clearExitHooks() {
  _exitHooks.clear();
  _sigintSub?.cancel();
  _sigtermSub?.cancel();
  _sigintSub = null;
  _sigtermSub = null;
}

/// Registers [callback] to run on SIGINT, SIGTERM or normal exit.
///
/// Returns a function that unregisters it.
///
/// {@category CLI}
void Function() onExit(FutureOr<void> Function() callback) {
  _exitHooks.add(callback);
  _ensureSignalHandlers();
  return () => _exitHooks.remove(callback);
}

/// Prints [message] to stderr, awaits the exit hooks, and exits with [exitCode].
///
/// Await it — `await die('...')` has static type [Never], so the code after it is
/// still unreachable.
///
/// {@category CLI}
Future<Never> die(String message, {int exitCode = 1}) async {
  ConsoleIo.err.writeln('  ✖ $message'.red);
  await runExitHooks();
  exit(exitCode);
}

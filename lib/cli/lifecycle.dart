import 'dart:async';
import 'dart:io';

import 'ansi.dart';
import 'stdio.dart';

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

/// Registers a cleanup hook [callback] to run when the process receives termination signals or exits.
///
/// Returns a function to unregister the hook.
///
/// Example:
/// ```dart
/// final unregister = onExit(() async {
///   await cleanupTempContainers();
/// });
/// ```
///
/// {@category CLI}
void Function() onExit(FutureOr<void> Function() callback) {
  _exitHooks.add(callback);
  _ensureSignalHandlers();
  return () => _exitHooks.remove(callback);
}

/// Prints [message] to stderr and immediately terminates the process with [exitCode], running exit hooks first.
///
/// Example:
/// ```dart
/// die('Configuration file is missing');
/// ```
///
/// {@category CLI}
Never die(String message, {int exitCode = 1}) {
  ConsoleIo.err.writeln('  ✖ $message'.red);
  for (final hook in List.of(_exitHooks)) {
    try {
      hook();
    } catch (_) {}
  }
  exit(exitCode);
}

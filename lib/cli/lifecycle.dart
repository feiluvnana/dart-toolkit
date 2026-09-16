import 'dart:async';
import 'dart:io';

import 'ansi.dart';

FutureOr<void> Function()? _exitHook;
StreamSubscription<ProcessSignal>? _sigintSub;
StreamSubscription<ProcessSignal>? _sigtermSub;

void _ensureSignalHandlers() {
  if (_sigintSub != null) return;

  void handleSignal(ProcessSignal signal) async {
    final hook = _exitHook;
    if (hook != null) {
      try {
        await hook();
      } catch (_) {}
    }
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

/// Registers a cleanup hook [callback] to run when the process receives termination signals (SIGINT / SIGTERM).
///
/// Subsequent calls to [onExit] override the previous callback. Passing `null` removes the hook and detaches signal listeners.
///
/// Example:
/// ```dart
/// onExit(() async {
///   await cleanupTempContainers();
/// });
/// ```
void onExit(FutureOr<void> Function()? callback) {
  _exitHook = callback;
  if (callback != null) {
    _ensureSignalHandlers();
  } else {
    _sigintSub?.cancel();
    _sigtermSub?.cancel();
    _sigintSub = null;
    _sigtermSub = null;
  }
}

/// Prints [message] to stderr and immediately terminates the process with [exitCode].
///
/// Example:
/// ```dart
/// die('Configuration file is missing');
/// ```
Never die(String message, {int exitCode = 1}) {
  stderr.writeln('  ✖ $message'.red);
  exit(exitCode);
}

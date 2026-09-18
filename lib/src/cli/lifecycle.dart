part of '../../cli.dart';

final List<FutureOr<void> Function()> _exitHooks = [];
StreamSubscription<ProcessSignal>? _sigintSub;
StreamSubscription<ProcessSignal>? _sigtermSub;

bool _exiting = false;

void _ensureSignalHandlers() {
  if (_sigintSub != null) return;

  void handleSignal(ProcessSignal signal) async {
    // A second signal while the hooks run must not run them again.
    if (_exiting) return;
    _exiting = true;
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

/// Registers [callback] to run on SIGINT, SIGTERM, [die], or when [Cli.run] returns.
///
/// Returns a function that unregisters it. The signal watch keeps the isolate alive, so
/// a script without a [Cli] must end with [die], `exit`, or [clearExitHooks].
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

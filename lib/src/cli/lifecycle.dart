part of '../../cli.dart';

final List<FutureOr<void> Function()> _exitHooks = [];
StreamSubscription<ProcessSignal>? _sigintSub;
StreamSubscription<ProcessSignal>? _sigtermSub;

bool _exiting = false;

void _ensureSignalHandlers() {
  if (_sigintSub != null) return;

  void handleSignal(ProcessSignal signal) async {
    // A second signal while the listeners run must not run them again.
    if (_exiting) return;
    _exiting = true;
    await _runExitHooks();
    _terminate(128 + signal.signalNumber);
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

/// Runs every exit listener in registration order; one that throws does not stop the rest.
Future<void> _runExitHooks() async {
  for (final hook in List.of(_exitHooks)) {
    try {
      await hook();
    } catch (_) {}
  }
}

/// Forgets every listener and stops the signal watch.
void _clearExitHooks() {
  _exitHooks.clear();
  _sigintSub?.cancel();
  _sigtermSub?.cancel();
  _sigintSub = null;
  _sigtermSub = null;
}

/// `dart:io`'s `exit`, reachable from inside [Lifecycle] where the static shadows the name.
Never _terminate(int code) => exit(code);

void _noop() {}

/// The process lifecycle: what runs on the way out, and the way out itself.
///
/// Two shapes and no others. `onExit` registers a listener for the exit event, and `exit`
/// is the event happening — a pair that reads the same way round whichever end you start
/// from. There is no third spelling for *run the listeners*, no second spelling for *forget
/// them*, and nothing here is named after the list it keeps.
///
/// ```dart
/// Lifecycle.onExit(chrome.close);      // register
/// Lifecycle.onExit(null);              // forget every listener
///
/// await Lifecycle.exit();              // run them, leave with 0
/// await Lifecycle.exit('no URL given') // say why in red, leave with 1
/// ```
///
/// It is a namespace rather than two top-level functions for one reason: a top-level `exit`
/// would **silently** shadow `dart:io`'s in every file that imports this package, because
/// Dart resolves a name to a non-platform library without calling it ambiguous. Nobody
/// writing `exit(0)` should get someone else's.
///
/// {@category CLI}
class Lifecycle {
  /// Registers [callback] to run on SIGINT, SIGTERM, [exit], or when [Cli.run] returns.
  ///
  /// Listeners run in registration order, and one that throws does not stop the rest, so a
  /// cleanup that fails cannot strand the ones behind it.
  ///
  /// Returns a function that removes *this* listener — for a cleanup that stops being
  /// necessary once the work it guarded has succeeded. `onExit(null)` removes *every*
  /// listener and stops the signal watch, which is the reset [Cli.run] does on the way out
  /// and the one a test wants between cases; it returns a function that does nothing, since
  /// there is nothing left to remove.
  ///
  /// ```dart
  /// final release = Lifecycle.onExit(unlock);
  /// await deploy();
  /// release();                       // it worked; nothing to undo
  /// ```
  ///
  /// The signal watch keeps the isolate alive, so a script with no [Cli] around it must end
  /// with [exit], `dart:io`'s `exit`, or `onExit(null)`.
  static void Function() onExit(FutureOr<void> Function()? callback) {
    if (callback == null) {
      _clearExitHooks();
      return _noop;
    }
    _exitHooks.add(callback);
    _ensureSignalHandlers();
    return () => _exitHooks.remove(callback);
  }

  /// Runs every exit listener and ends the process.
  ///
  /// With a [message] it is written to stderr in red first and [code] defaults to 1 — what a
  /// program does when it has to stop and say why. With none, [code] defaults to 0.
  ///
  /// Await it: the static type is [Never], so whatever follows is unreachable and a
  /// `??` reads as the answer or the end of the program.
  ///
  /// ```dart
  /// final file = (ctx.rest.firstOrNull ?? await Lifecycle.exit('read needs a file')).path;
  /// ```
  static Future<Never> exit([String? message, int? code]) async {
    if (message != null) Io.err.writeln('  ✖ $message'.red);
    await _runExitHooks();
    _terminate(code ?? (message == null ? 0 : 1));
  }
}

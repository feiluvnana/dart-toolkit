part of '../../cli.dart';

final List<FutureOr<void> Function()> _exitHooks = [];
StreamSubscription<ProcessSignal>? _sigintSub;
StreamSubscription<ProcessSignal>? _sigtermSub;

bool _exiting = false;

void _ensureSignalHandlers() {
  if (_sigintSub != null) return;

  void handleSignal(ProcessSignal signal) async {
    // The terminal first: a ^C during `Console.secret` must not leave echo off behind it.
    Console._restoreTerminal();
    // A second signal while the listeners run means a cleanup hangs: leave now.
    if (_exiting) {
      killHaltedProcessesSync();
      _terminate(128 + signal.signalNumber);
    }
    _exiting = true;
    await _runExitHooks();
    await killHaltedProcesses();
    _terminate(128 + signal.signalNumber);
  }

  try {
    _sigintSub = ProcessSignal.sigint.watch().listen(handleSignal);
  } catch (_) {}
  try {
    if (!Platform.isWindows) _sigtermSub = ProcessSignal.sigterm.watch().listen(handleSignal);
  } catch (_) {}
}

Future<void>? _hooksRun;

/// Runs every exit listener in registration order; one that throws does not stop the rest.
Future<void> _runExitHooks() => _hooksRun ??= () async {
  for (final hook in List.of(_exitHooks)) {
    try {
      await hook();
    } catch (_) {}
  }
}();

/// `dart:io`'s `exit`, reachable from inside [Lifecycle] where the static shadows the name.
Never _terminate(int code) {
  for (final restore in List.of(IoBridge.restores)) {
    try {
      restore();
    } catch (_) {}
  }
  exit(code);
}

void _noop() {}

/// The process lifecycle: what runs on the way out, and the way out itself.
///
/// ```dart
/// Lifecycle.onExit(chrome.close);      // register
/// Lifecycle.onExit(null);              // forget every listener
///
/// await Lifecycle.exit();              // run them, leave with 0
/// await Lifecycle.exit('no URL given') // say why in red, leave with 1
/// ```
///
/// A namespace, because a top-level `exit` would silently shadow `dart:io`'s in every file
/// that imports this package.
///
/// {@category CLI}
class Lifecycle {
  /// Registers [callback] to run on SIGINT, SIGTERM, [exit], or when [Cli.run] returns.
  ///
  /// Listeners run in registration order; one that throws does not stop the rest, and a
  /// second ^C leaves at once. Returns this listener's removal. `onExit(null)` removes every
  /// listener and stops the signal watch — what [Cli.run] does on the way out, and what a
  /// test wants between cases.
  ///
  /// ```dart
  /// final release = Lifecycle.onExit(unlock);
  /// await deploy();
  /// release();                       // it worked; nothing to undo
  /// ```
  ///
  /// The signal watch keeps the isolate alive, so a script with no [Cli] must end with
  /// [exit] or `onExit(null)`.
  static void Function() onExit(FutureOr<void> Function()? callback) {
    if (callback == null) {
      _exitHooks.clear();
      _hooksRun = null;
      _sigintSub?.cancel();
      _sigtermSub?.cancel();
      _sigintSub = _sigtermSub = null;
      return _noop;
    }
    _exitHooks.add(callback);
    _ensureSignalHandlers();
    return () => _exitHooks.remove(callback);
  }

  /// Runs every exit listener and ends the process.
  ///
  /// A [message] (any object) goes to stderr as the theme's error line first, and [code]
  /// then defaults to 1, else 0. The type is [Never], so `??` reads as the answer or the end:
  ///
  /// ```dart
  /// final file = (ctx.rest.firstOrNull ?? await Lifecycle.exit('read needs a file')).path;
  /// ```
  static Future<Never> exit([Object? message, int? code]) async {
    Console._stopAll();
    if (message != null) {
      final t = Console.theme;
      Console._durable(() => Io.err.writeln(t._line(t.danger, t.error, '$message')));
    }
    await _runExitHooks();
    await killHaltedProcesses();
    _terminate(code ?? (message == null ? 0 : 1));
  }
}

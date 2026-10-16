/// The only `ProcessSignal` subscriber in the package.
///
/// No module watches signals or calls `exit` itself: a live
/// `ProcessSignal.watch` keeps the VM alive, and an `exit` from one module
/// would cut short another's async cleanup (an orphaned browser profile).
///
/// Facades register ordered cleanup hooks via [onExit] and pending waits
/// via [onInterrupt] (or [interruptible] / [guard]). The first registration
/// installs `SIGINT`/`SIGTERM`/`SIGHUP` watchers (only the signals the OS
/// has — Windows only `SIGINT`); the last removal cancels them so the
/// script may exit.
///
/// Ctrl-C (the first `SIGINT`) interrupts instead of exiting: every
/// registered wait fails with [InterruptedException] (its stop kills the
/// program, aborts the request, ends the pipeline), so the script's
/// `finally` blocks run; waits started afterwards fail at once, while file
/// work still runs. The process then exits 130 once no toolkit work has been
/// in flight for [_quiet] (busy hooks and waits; an uncaught
/// [InterruptedException] is not reported), after the hooks run. A second
/// `SIGINT` stops waiting: the hooks run and the process exits; a third
/// while they run exits at once. `SIGTERM`/`SIGHUP` run the hooks and exit
/// (143/129) as before.
///
/// `tui` in raw mode reports Ctrl-C as a key, not termination: it calls
/// [claimInterrupt] with a predicate (usually `() => !stdin.echoMode`);
/// while the predicate holds, `SIGINT` is delivered to the app's own
/// handler instead.
///
/// A [Scope] is the same interruption for one piece of work: waits
/// registered in a zone carrying it fail with [InterruptedException] once it
/// is cancelled, and new ones there fail at once; the script goes on (`tui`
/// cancels what a `Tui.run` started when it quits).
///
/// Resize (`SIGWINCH`) is not an exit: [onResize] multiplexes the single
/// `SIGWINCH` subscription. No other file may call `ProcessSignal.watch`.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';

import '../core.dart' show InterruptedException;
import 'progress.dart' show runGuard;

final _hooks = <Object, (FutureOr<void> Function(), bool)>{};
final _stops = <Object, (void Function(), Scope?)>{};
final _resizeCbs = <Object, void Function()>{};
StreamSubscription<io.ProcessSignal>? _sigintSub;
StreamSubscription<io.ProcessSignal>? _sigtermSub;
StreamSubscription<io.ProcessSignal>? _sighupSub;
StreamSubscription<io.ProcessSignal>? _sigwinchSub;
bool Function()? _interruptClaim;
var _exiting = false;
var _interrupted = false;
Timer? _idle;

/// A `SIGINT` before this time is the terminal's Ctrl-C that already ended a
/// child (see [interrupt]), not a second one.
DateTime? _echoUntil;

/// How long the toolkit must sit idle after Ctrl-C before the process exits.
const _quiet = Duration(milliseconds: 50);

/// True once Ctrl-C interrupted the script, or the current zone's [Scope]
/// was cancelled: outside waits fail at once.
bool get interrupted => _interrupted || (_scope?.cancelled ?? false);

final _scopeKey = Object();

Scope? get _scope => Zone.current[_scopeKey] as Scope?;

/// Toolkit waits that can be cancelled together, as Ctrl-C cancels all:
/// run the work in a zone with [values] (a scope made inside another is
/// cancelled with it too).
final class Scope {
  Scope() : _parent = _scope;

  final Scope? _parent;
  var _cancelled = false;

  /// The zone values that put work in this scope.
  late final Map<Object?, Object?> values = {_scopeKey: this};

  bool get cancelled => _cancelled || (_parent?.cancelled ?? false);

  bool _within(Scope scope) => identical(this, scope) || (_parent?._within(scope) ?? false);

  /// Fail every wait registered in this scope with [InterruptedException];
  /// later ones in it fail at once. The rest of the script is untouched.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final mine = [
      for (final MapEntry(:key, value: (_, scope)) in _stops.entries)
        if (scope != null && scope._within(this)) key,
    ];
    for (final token in mine) {
      final stop = _stops.remove(token);
      try {
        stop?.$1();
      } catch (_) {}
    }
    _maybeUninstall();
  }
}

/// True when this process shares a terminal, so the terminal's Ctrl-C
/// reaches its children too. (`stdin.hasTerminal` says yes for any
/// character device, `< /dev/null` too: a terminal's modes can be read.)
bool get onTerminal {
  try {
    if (io.stdout.hasTerminal || io.stderr.hasTerminal) return true;
    if (!io.stdin.hasTerminal) return false;
    io.stdin.echoMode;
    return true;
  } catch (_) {
    return false;
  }
}

/// Register [cleanup] to run when the process ends on a signal. Returns a
/// token for [offExit]. Hooks run in reverse registration order. A [busy]
/// hook marks work in flight (a temp file, a child): after Ctrl-C the
/// process waits for it to go; a resident one (a terminal restore, an open
/// browser) does not hold the exit.
Object onExit(FutureOr<void> Function() cleanup, {bool busy = true}) {
  final token = Object();
  _hooks[token] = (cleanup, busy);
  _install();
  return token;
}

/// Remove a hook registered by [onExit]. The last removal cancels the
/// watchers 1 ms later, so back-to-back hooks (one per atomic write) reuse
/// them and nothing keeps the VM alive.
void offExit(Object token) {
  _hooks.remove(token);
  _maybeUninstall();
}

/// Run [stop] on Ctrl-C while registered: it ends one pending wait, failing
/// it with [InterruptedException]. Returns a token for [offInterrupt]. Check
/// [interrupted] first: once interrupted, a new wait fails at once.
Object onInterrupt(void Function() stop) {
  final token = Object();
  _stops[token] = (stop, _scope);
  _install();
  return token;
}

/// Remove a stop registered by [onInterrupt].
void offInterrupt(Object token) {
  _stops.remove(token);
  _maybeUninstall();
}

/// [work]'s result, or an [InterruptedException] as soon as Ctrl-C arrives
/// (after [stop], which ends the work; its later outcome is dropped). Once
/// interrupted, fails at once.
Future<T> interruptible<T>(Future<T> work, {void Function()? stop}) {
  if (interrupted) {
    work.ignore();
    try {
      stop?.call();
    } catch (_) {}
    return Future.error(const InterruptedException());
  }
  final done = Completer<T>();
  final token = onInterrupt(() {
    try {
      stop?.call();
    } catch (_) {}
    if (!done.isCompleted) done.completeError(const InterruptedException());
  });
  work.then(
    (value) {
      offInterrupt(token);
      if (!done.isCompleted) done.complete(value);
    },
    onError: (Object e, StackTrace st) {
      offInterrupt(token);
      if (!done.isCompleted) done.completeError(e, st);
    },
  );
  return done.future;
}

/// [source], failing with [InterruptedException] (and cancelling [source])
/// on Ctrl-C while it is read. Listened after Ctrl-C, an [outside] source
/// (a program) fails at once; any other (a write saving state) runs.
Stream<T> guard<T>(Stream<T> source, {bool outside = false}) {
  if (interrupted && !outside) return source;
  late final StreamController<T> out;
  StreamSubscription<T>? sub;
  Object? token;
  void off() {
    final t = token;
    token = null;
    if (t != null) offInterrupt(t);
  }

  out = StreamController<T>(
    sync: true,
    onListen: () {
      if (interrupted) {
        if (!outside) {
          sub = source.listen(out.add, onError: out.addError, onDone: out.close);
          return;
        }
        out.addError(const InterruptedException());
        unawaited(out.close());
        return;
      }
      token = onInterrupt(() {
        token = null;
        final s = sub;
        sub = null;
        s?.cancel().ignore();
        if (!out.isClosed) {
          out.addError(const InterruptedException());
          unawaited(out.close());
        }
      });
      sub = source.listen(
        out.add,
        onError: out.addError,
        onDone: () {
          off();
          unawaited(out.close());
        },
      );
    },
    onPause: () => sub?.pause(),
    onResume: () => sub?.resume(),
    onCancel: () {
      off();
      final s = sub;
      sub = null;
      return s?.cancel();
    },
  );
  return out.stream;
}

/// Interrupt as Ctrl-C would: for a child that died of the terminal's
/// `SIGINT` before our watcher heard it. The `SIGINT` that follows within a
/// second is that same Ctrl-C, not a second one.
void interrupt() {
  if (_interrupted || _exiting) return;
  _echoUntil = DateTime.now().add(const Duration(seconds: 1));
  _install();
  _interrupt();
}

/// While [asKey] returns true, `SIGINT` is not termination (tui raw mode:
/// Ctrl-C is a key). Pass `null` (or a predicate returning false) to restore
/// termination. Only one claimant; the latest call wins.
void claimInterrupt(bool Function()? asKey) {
  _interruptClaim = asKey;
}

/// Run [onSignal] on terminal resize. Backed by the single `SIGWINCH`
/// subscription owned here; on platforms without `SIGWINCH` (Windows) the
/// callback never fires and callers fall back to polling the size at frame
/// time. Returns a token for [offResize].
Object onResize(void Function() onSignal) {
  final token = Object();
  _resizeCbs[token] = onSignal;
  if (_resizeCbs.length == 1) _installWinch();
  return token;
}

/// Remove a resize callback. The last removal cancels the `SIGWINCH`
/// subscription.
void offResize(Object token) {
  _resizeCbs.remove(token);
  if (_resizeCbs.isEmpty) {
    try {
      _sigwinchSub?.cancel();
    } catch (_) {}
    _sigwinchSub = null;
  }
}

void _maybeUninstall() {
  if (_hooks.isNotEmpty || _stops.isNotEmpty || _interrupted) return;
  Timer(const Duration(milliseconds: 1), () {
    if (_hooks.isEmpty && _stops.isEmpty && !_interrupted) _uninstallSignals();
  });
}

void _install() {
  // From now on a `>` run in flight fails on Ctrl-C; one begun after it
  // (a `finally` saving state) runs.
  runGuard ??= guard;
  // SIGINT always exists (Windows too).
  try {
    _sigintSub ??= io.ProcessSignal.sigint.watch().listen((_) => _handle(130, isSigint: true), onError: (_) {});
  } catch (_) {}
  if (io.Platform.isWindows) return;
  try {
    _sigtermSub ??= io.ProcessSignal.sigterm.watch().listen((_) => _handle(143, isSigint: false), onError: (_) {});
  } catch (_) {}
  try {
    _sighupSub ??= io.ProcessSignal.sighup.watch().listen((_) => _handle(129, isSigint: false), onError: (_) {});
  } catch (_) {}
}

void _installWinch() {
  if (io.Platform.isWindows) return;
  try {
    _sigwinchSub ??= io.ProcessSignal.sigwinch.watch().listen((_) {
      for (final cb in List<void Function()>.of(_resizeCbs.values)) {
        try {
          cb();
        } catch (_) {}
      }
    }, onError: (_) {});
  } catch (_) {}
}

void _uninstallSignals() {
  for (final sub in [_sigintSub, _sigtermSub, _sighupSub]) {
    try {
      sub?.cancel();
    } catch (_) {}
  }
  _sigintSub = _sigtermSub = _sighupSub = null;
}

void _handle(int code, {required bool isSigint}) {
  // A signal while the hooks run: the user insists, exit now (the hooks
  // that already ran stay done; the rest are skipped).
  if (_exiting) io.exit(code);
  if (isSigint) {
    try {
      if (_interruptClaim?.call() == true) return;
    } catch (_) {}
    final echo = _echoUntil;
    _echoUntil = null;
    if (echo != null && DateTime.now().isBefore(echo)) return;
    if (!_interrupted) return _interrupt();
  }
  unawaited(_finish(code));
}

/// Fail every pending wait, then exit 130 once the toolkit is idle.
void _interrupt() {
  _interrupted = true;
  io.exitCode = 130;
  _quietUncaught();
  final stops = [for (final (stop, _) in _stops.values) stop];
  _stops.clear();
  for (final stop in stops) {
    try {
      stop();
    } catch (_) {}
  }
  var idleTicks = 0;
  final tick = Duration(microseconds: _quiet.inMicroseconds ~/ 2);
  _idle = Timer.periodic(tick, (_) {
    final busy = _stops.isNotEmpty || _hooks.values.any((h) => h.$2);
    idleTicks = busy ? 0 : idleTicks + 1;
    if (idleTicks >= 2) unawaited(_finish(130));
  });
}

/// After Ctrl-C an uncaught error must not end the process with 255 before
/// the hooks run: the [InterruptedException] that escapes `main` (its
/// `finally` done) is expected and silent; any other is printed as the VM
/// would.
void _quietUncaught() {
  try {
    final port = RawReceivePort((Object? message) {
      if (message is! List || message.isEmpty) return;
      final error = '${message[0]}';
      if (error.startsWith('InterruptedException')) return;
      io.stderr.writeln('Unhandled exception:\n$error\n${message.length > 1 ? message[1] ?? '' : ''}');
    });
    port.keepIsolateAlive = false;
    Isolate.current.addErrorListener(port.sendPort);
    Isolate.current.setErrorsFatal(false);
  } catch (_) {}
}

Future<void> _finish(int code) async {
  if (_exiting) return;
  _exiting = true;
  _idle?.cancel();
  // Hooks run in reverse registration order.
  final hooks = List.of(_hooks.values).reversed;
  for (final (hook, _) in hooks) {
    try {
      await Future.sync(hook).timeout(const Duration(seconds: 5), onTimeout: () {});
    } catch (_) {}
  }
  io.exit(code);
}

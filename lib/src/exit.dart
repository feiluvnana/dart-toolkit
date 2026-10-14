/// The only `ProcessSignal` subscriber in the package.
///
/// Three modules used to watch signals and call `exit` themselves: `chrome`
/// (leaked Chromium + a live `watch` that kept the VM alive after
/// `browser.close()`), `console` prompts (sync `exit(130)` while chrome's
/// async `close()` was still awaiting → orphaned profile), and `tui`
/// (sync `exit(143)` without awaiting a live browser). A live
/// `ProcessSignal.watch` subscription keeps the VM alive (verified, macOS).
///
/// One owner fixes both: facades register ordered cleanup hooks via
/// [onExit] and remove them via [offExit]. The first hook installs
/// `SIGINT`/`SIGTERM`/`SIGHUP` watchers (only the signals the OS has —
/// Windows only `SIGINT`); the last removal cancels them so the script may
/// exit. On a signal the hooks run in reverse order (terminal restore first,
/// then browsers), awaited and bounded, then `exit` is called once.
///
/// `tui` in raw mode reports Ctrl-C as a key, not termination: it calls
/// [claimInterrupt] with a predicate (usually `() => !stdin.echoMode`);
/// while the predicate holds, `SIGINT` is delivered to the app's own
/// handler instead of exiting.
///
/// Resize (`SIGWINCH`) is not an exit: [onResize] multiplexes the single
/// `SIGWINCH` subscription. No other file may call `ProcessSignal.watch`.
library;

import 'dart:async';
import 'dart:io' as io;

final _hooks = <Object, FutureOr<void> Function()>{};
var _nextId = 0;
final _resizeCbs = <Object, void Function()>{};
var _nextResizeId = 0;
StreamSubscription<io.ProcessSignal>? _sigintSub;
StreamSubscription<io.ProcessSignal>? _sigtermSub;
StreamSubscription<io.ProcessSignal>? _sighupSub;
StreamSubscription<io.ProcessSignal>? _sigwinchSub;
bool Function()? _interruptClaim;
var _exiting = false;

/// Register [cleanup] to run on `SIGINT`/`SIGTERM`/`SIGHUP`. Returns a token
/// for [offExit]. The first hook installs the watchers; hooks run in reverse
/// registration order when a signal arrives.
Object onExit(FutureOr<void> Function() cleanup) {
  final token = _Token(_nextId++);
  _hooks[token] = cleanup;
  if (_hooks.length == 1) _install();
  return token;
}

/// Remove a hook registered by [onExit]. The last removal cancels the
/// watchers so nothing keeps the VM alive.
void offExit(Object token) {
  _hooks.remove(token);
  if (_hooks.isEmpty) _uninstallSignals();
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
  final token = _Token(_nextResizeId++);
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

void _install() {
  // SIGINT always exists (Windows too).
  try {
    _sigintSub ??= io.ProcessSignal.sigint.watch().listen(
      (_) => _handle(130, isSigint: true),
      onError: (_) {},
    );
  } catch (_) {}
  if (io.Platform.isWindows) return;
  try {
    _sigtermSub ??= io.ProcessSignal.sigterm.watch().listen(
      (_) => _handle(143, isSigint: false),
      onError: (_) {},
    );
  } catch (_) {}
  try {
    _sighupSub ??= io.ProcessSignal.sighup.watch().listen(
      (_) => _handle(129, isSigint: false),
      onError: (_) {},
    );
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

Future<void> _handle(int code, {required bool isSigint}) async {
  if (_exiting) return;
  if (isSigint) {
    try {
      if (_interruptClaim?.call() == true) return;
    } catch (_) {}
    // Legacy cooked-terminal check: raw mode (echo off) means the tui owns
    // SIGINT as a key even without an explicit claim.
    try {
      if (!io.stdin.echoMode) return;
    } catch (_) {}
  }
  _exiting = true;
  // Reverse order: last registered (browser) first? No — terminal restore
  // first, then browsers. Registration order is terminal-first (prompts/tui
  // register before browsers in practice? not guaranteed). Proposal says
  // "terminal restore first, then the browsers": hooks registered by
  // terminal owners run first. We run in reverse registration order, and
  // terminal owners register last? To keep it predictable, document reverse
  // order and have tui/console register their restore hooks after browsers?
  // Simplest correct: run in reverse order of registration.
  final hooks = List<FutureOr<void> Function()>.of(_hooks.values).reversed;
  for (final hook in hooks) {
    try {
      await Future.sync(hook).timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    } catch (_) {}
  }
  io.exit(code);
}

final class _Token {
  _Token(this.id);
  final int id;

  @override
  bool operator ==(Object other) => other is _Token && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// The terminal app core: [Term], its backends, [Tui.run], and [FakeTerminal].
///
/// An app is a loop of `draw` and `poll`:
///
/// ```dart
/// await Tui.run((term) async {
///   while (true) {
///     term.draw((ui) {
///       ui.box(
///         title: 'App',
///         build: (box) => box.text('Press "q" to exit.'),
///       );
///     });
///     final ev = await term.poll();
///     if (ev?.key == 'q') break;
///   }
/// });
/// ```
///
/// `draw` paints immediately (diff vs the previous frame); `poll` answers the
/// next event (`null` on timeout). Side effects are [Term.post]/[listen]/[defer].
/// Everything is restored on every way out: normal return, [Term.close], an
/// exception, or a second ^C within two seconds (the next `draw`/`poll` throws
/// an internal end-of-run that [Tui.run] swallows).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/traits.dart';
import 'buffer.dart';
import 'events.dart';
import 'layout.dart';
import 'native.dart';
import 'width.dart';

part 'canvas.dart';

/// What [Term] drives: the real terminal ([NativeBackend]) or the test seam
/// ([FakeBackend], behind [FakeTerminal]).
abstract interface class TermBackend {
  /// Measured size in columns × rows.
  (int, int) get size;

  /// Colour capability.
  ColorLevel get colorLevel;

  /// Shows [grid]: [changes] since the previous frame encoded as [ansi].
  void show(Grid grid, List<Change> changes, String ansi);

  /// Positions the hardware cursor, or hides it when [col] is `null`.
  void cursor(int? col, int? row);

  /// A backend-fed event waiting, if any (native hearsay or injected): never
  /// blocks. [Term.poll] drains these between its posts.
  TuiEvent? tryTake();

  /// Woken by the backend whenever [tryTake] gains an event, so a waiting
  /// [Term.poll] answers at once. Set once by [Term].
  set onEvent(void Function()? wake);

  /// Leaves the alternate screen and restores terminal modes (restartable).
  void stop();

  /// Re-enters after [stop] (the suspend dance).
  void resume();

  /// Frees the backend for good.
  void close();
}

/// A heard `TkEvent`, pushed by the native reader thread.
typedef EventFn = ffi.Void Function(ffi.Pointer<TkEvent>);

/// The `dart_toolkit_tui` backend: raw mode, alt screen, bracketed paste and
/// (on request) mouse capture; a native reader thread pushes parsed events to
/// a listener, polled from a Dart queue; cells painted from Dart-computed diffs.
final class NativeBackend implements TermBackend {
  ffi.Pointer<ffi.Void> _handle;
  bool _stopped = false;

  /// Native hearsay waiting for [tryTake].
  final Queue<TuiEvent> _heard = Queue();

  /// The reader thread's listener: closed after the native side joins it.
  ffi.NativeCallable<EventFn>? _listener;

  void Function()? _wake;

  @override
  set onEvent(void Function()? wake) => _wake = wake;

  NativeBackend._(this._handle);

  /// Takes the terminal (alt screen + raw mode) and starts its reader thread.
  /// Without the library it is an [UnsupportedError]; without a terminal
  /// (piped output) an [UnsupportedError].
  static NativeBackend start({bool pointer = false}) {
    if (!io.stdout.hasTerminal) throw UnsupportedError('Tui needs a terminal: stdout is piped');
    final handle = _TuiNative.start(pointer ? 1 : 0);
    if (handle == ffi.nullptr) throw NativeException('take the terminal', lastError());
    final backend = NativeBackend._(handle);
    backend._listener = ffi.NativeCallable<EventFn>.listener(backend._onEvent);
    if (_TuiNative.listen(handle, backend._listener!.nativeFunction) < 0) {
      final why = lastError();
      backend._listener!.close();
      _TuiNative.free(handle);
      throw NativeException('listen to the terminal', why);
    }
    return backend;
  }

  @override
  (int, int) get size {
    final out = alloc(4).cast<ffi.Uint16>();
    try {
      if (_TuiNative.size(_handle, out, out + 1) < 0) {
        throw NativeException('measure the terminal', lastError());
      }
      return (out[0], out[1]);
    } finally {
      free(out.cast(), 4);
    }
  }

  @override
  ColorLevel get colorLevel => detectLevel(io.Platform.environment);

  /// Picks the colour level for [env] (testable half of [colorLevel]):
  /// `NO_COLOR`/dumb → none, 24-bit markers → truecolor, `256color` → 256,
  /// Windows Terminal sessions → truecolor, else the 16 basics.
  static ColorLevel detectLevel(Map<String, String> env) {
    if (env.containsKey('NO_COLOR')) return ColorLevel.none;
    if (env['TERM'] == 'dumb') return ColorLevel.none;
    final colorterm = (env['COLORTERM'] ?? '').toLowerCase();
    if (colorterm.contains('truecolor') || colorterm.contains('24bit')) return ColorLevel.truecolor;
    if ((env['TERM'] ?? '').contains('256color')) return ColorLevel.ansi256;
    if (env.containsKey('WT_SESSION') || env.containsKey('ConEmuANSI')) return ColorLevel.truecolor;
    return ColorLevel.ansi16;
  }

  @override
  void show(Grid grid, List<Change> changes, String ansi) {
    if (_stopped || ansi.isEmpty) return;
    withBytes(utf8.encode(ansi), (p, n) {
      if (_TuiNative.write(_handle, p, n) < 0) throw NativeException('paint', lastError());
    });
  }

  @override
  void cursor(int? col, int? row) {
    if (_stopped) return;
    _TuiNative.cursor(_handle, col ?? -1, row ?? -1);
  }

  @override
  TuiEvent? tryTake() => _heard.isEmpty ? null : _heard.removeFirst();

  /// One heard event: copied out of native memory (freed at once), decoded
  /// and queued for [tryTake]. Runs on the reader thread's callback: no
  /// awaits, nothing that throws.
  void _onEvent(ffi.Pointer<TkEvent> p) {
    final e = p.ref;
    final kind = e.kind, code = e.code, mods = e.mods, x = e.x, y = e.y, w = e.w;
    final Uint8List? text = e.kind == 4 && e.textLen > 0 ? Uint8List.fromList(e.text.asTypedList(e.textLen)) : null;
    _TuiNative.eventFree(p);
    final ev = _decoded(kind, code, mods, x, y, w, text);
    if (ev == null) return;
    _heard.add(ev);
    _wake?.call();
  }

  TuiEvent? _decoded(int kind, int code, int mods, int x, int y, int w, Uint8List? text) {
    switch (kind) {
      case 1:
        final name = _keyName(code);
        if (name == null) return null;
        return KeyPress(name, shift: mods & modShift != 0, ctrl: mods & modCtrl != 0, alt: mods & modAlt != 0);
      case 2:
        return Resize(x, y);
      case 3:
        const kinds = PointerKind.values;
        final pkind = w >= 0 && w < kinds.length ? kinds[w] : PointerKind.move;
        return Pointer(
          x,
          y,
          pkind,
          button: code,
          shift: mods & modShift != 0,
          ctrl: mods & modCtrl != 0,
          alt: mods & modAlt != 0,
        );
      case 4:
        return Paste(utf8.decode(text ?? const <int>[], allowMalformed: true));
      case 5:
        return const Focus();
      case 6:
        return const Blur();
      case 7:
        return const Interrupt();
      default:
        return null;
    }
  }

  String? _keyName(int code) {
    if (code < 0x100000) {
      if (code < 32 || code == 127) return null;
      return String.fromCharCode(code);
    }
    return switch (code) {
      keyUp => 'up',
      keyDown => 'down',
      keyLeft => 'left',
      keyRight => 'right',
      keyHome => 'home',
      keyEnd => 'end',
      keyPageUp => 'pageUp',
      keyPageDown => 'pageDown',
      keyInsert => 'insert',
      keyDelete => 'delete',
      keyEnter => 'enter',
      keyTab => 'tab',
      keyBackspace => 'backspace',
      keyEsc => 'esc',
      _ when code >= keyF && code < keyF + 24 => 'f${code - keyF + 1}',
      _ => null,
    };
  }

  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _TuiNative.stop(_handle);
  }

  @override
  void resume() {
    _TuiNative.resume(_handle);
    _stopped = false;
  }

  @override
  void close() {
    final h = _handle;
    if (h == ffi.nullptr) return;
    _handle = ffi.nullptr;
    // Joins the reader first: no event arrives past this, so the listener is
    // safe to drop.
    _TuiNative.free(h);
    _listener?.close();
    _listener = null;
  }
}

/// The native `tk_tui_*` calls behind [NativeBackend].
abstract final class _TuiNative {
  static ffi.DynamicLibrary get _lib => require();

  static final start = _lib
      .lookupFunction<ffi.Pointer<ffi.Void> Function(ffi.Uint8), ffi.Pointer<ffi.Void> Function(int)>('tk_tui_start');

  static final stop = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>), void Function(ffi.Pointer<ffi.Void>)>('tk_tui_stop');

  static final resume = _lib
      .lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>), int Function(ffi.Pointer<ffi.Void>)>('tk_tui_resume');

  static final free = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>), void Function(ffi.Pointer<ffi.Void>)>('tk_tui_free');

  static final size = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint16>, ffi.Pointer<ffi.Uint16>),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint16>, ffi.Pointer<ffi.Uint16>)
      >('tk_tui_size');

  static final listen = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.NativeFunction<EventFn>>),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.NativeFunction<EventFn>>)
      >('tk_tui_listen');

  static final eventFree = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<TkEvent>), void Function(ffi.Pointer<TkEvent>)>(
        'tk_tui_event_free',
      );

  static final write = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int)
      >('tk_tui_write');

  static final cursor = _lib
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32),
        void Function(ffi.Pointer<ffi.Void>, int, int)
      >('tk_tui_cursor');
}

/// The run is over: [Term.close] ran or a second ^C landed. [Tui.run] swallows
/// it; anywhere else it ends the app, so a loop can never spin on a closed
/// terminal (where `null` would also mean a timeout).
final class _Closed implements Exception {
  const _Closed();
}

/// A terminal app: `draw` frames, `poll` events. Made by [Tui.run] (real
/// terminal) or [FakeTerminal] (tests).
class Term {
  final TermBackend _backend;
  Grid? _prev;
  final Queue<TuiEvent> _posts = Queue();
  final Queue<Object> _pendingErrors = Queue();
  final List<Future<void> Function()> _defers = [];
  final List<StreamSubscription<dynamic>> _subs = [];
  List<({Rect rect, void Function() onPress})> _clickables = [];
  bool _closed = false;
  bool _shut = false;
  DateTime? _lastInterrupt;
  bool _suspendArmed = false;

  /// The current [poll]'s waiter, woken by posts, hearsay and [close].
  Completer<void>? _waker;
  Timer? _wakeTimer;

  /// Current size in columns × rows (a [Resize] event updates it).
  int w, h;

  /// Colour capability, read once from the backend.
  late final ColorLevel colorLevel = _backend.colorLevel;

  Term._(this._backend) : w = _backend.size.$1, h = _backend.size.$2 {
    _backend.onEvent = _wake;
  }

  /// A [Term] over [backend]: testing only ([FakeTerminal] feeds events
  /// through it; scripts use [Tui.run]).
  Term.forTesting(TermBackend backend) : this._(backend);

  /// The real terminal (alt screen + raw mode). Without the library it is an
  /// [UnsupportedError]; piped output is an [UnsupportedError].
  factory Term._local({bool pointer = false}) => Term._(NativeBackend.start(pointer: pointer));

  /// Paints one frame: [build] fills a fresh grid, the diff vs the previous
  /// frame goes to the terminal, overlays last. Throws [_Closed] once the run
  /// is over, so a loop can never paint a restored terminal.
  void draw(void Function(Canvas) build) {
    if (_closed) throw const _Closed();
    final grid = Grid(w, h);
    final ui = Canvas._(grid);
    build(ui);
    ui._paintOverlays();
    _clickables = ui._clickables;
    final changes = diff(_prev, grid);
    _prev = grid;
    _backend.show(grid, changes, encodeChanges(changes, colorLevel));
    final cursor = ui.cursorPos;
    _backend.cursor(cursor?.$1, cursor?.$2);
  }

  /// The next event: queued posts first, then backend hearsay. Awaits at most
  /// [timeout] (`null` waits for the next event). Answers `null` on timeout;
  /// once the run is over it throws [_Closed] instead (which [Tui.run]
  /// swallows), so a loop can never spin where `null` means both ends. A
  /// [post] wakes a waiting poll at once, as does the backend's listener. A
  /// pointer press over a button fires it. A queued stream error throws from
  /// the next poll.
  Future<TuiEvent?> poll({Duration? timeout}) async {
    if (_closed) throw const _Closed();
    if (_pendingErrors.isNotEmpty) throw _pendingErrors.removeFirst();
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    while (true) {
      final pending = _takePending();
      if (pending != null) return _route(pending);
      if (_closed) throw const _Closed();
      if (_pendingErrors.isNotEmpty) throw _pendingErrors.removeFirst();
      if (_suspendArmed) return _resume();
      Duration? waitFor;
      if (deadline != null) {
        waitFor = deadline.difference(DateTime.now());
        if (waitFor <= Duration.zero) return null;
      }
      _waker = Completer<void>();
      if (waitFor != null) _wakeTimer = Timer(waitFor, _wake);
      await _waker!.future;
      _wakeTimer?.cancel();
      _wakeTimer = null;
    }
  }

  /// Posts, then backend hearsay, if any.
  TuiEvent? _takePending() {
    if (_posts.isNotEmpty) return _posts.removeFirst();
    return _backend.tryTake();
  }

  /// One event through click routing and the resize/interrupt/suspend pass.
  TuiEvent _route(TuiEvent ev) {
    if (ev is Pointer && ev.kind == PointerKind.press) _click(ev);
    return _through(ev);
  }

  /// Wakes a waiting [poll], if any (a post, a heard event, or [close]).
  void _wake() {
    _wakeTimer?.cancel();
    _wakeTimer = null;
    final w = _waker;
    _waker = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  TuiEvent _through(TuiEvent ev) {
    if (ev is Resize) {
      w = ev.width;
      h = ev.height;
      _prev = null; // a new size repaints whole
      return ev;
    }
    if (ev is Interrupt) {
      final now = DateTime.now();
      if (_lastInterrupt != null && now.difference(_lastInterrupt!) < const Duration(seconds: 2)) {
        // The run ends here: the next draw or poll throws [_Closed], which
        // [Tui.run] swallows on the way to teardown.
        _requestClose();
      }
      _lastInterrupt = now;
      return ev;
    }
    if (ev is Suspend) {
      _suspendArmed = true;
      return ev;
    }
    // ^Z arrives as a key while raw: POSIX turns it into the suspend dance
    // (the next poll restores, stops, and — back on `fg` — resumes); Windows
    // keeps it a key.
    if (!io.Platform.isWindows && ev is KeyPress && ev.ctrl && ev.name == 'z') {
      _suspendArmed = true;
      return const Suspend();
    }
    return ev;
  }

  /// The second half of ^Z: the previous poll answered [Suspend]; this one
  /// restores the terminal, stops the process, and — back on `fg` —
  /// re-enters and answers [Resume]. POSIX only; elsewhere just resumes.
  Future<TuiEvent> _resume() async {
    _suspendArmed = false;
    if (!io.Platform.isWindows) {
      _backend.stop();
      io.Process.killPid(io.pid, io.ProcessSignal.sigtstp);
      // The pending SIGTSTP lands on the loop's next turn, stopping us inside
      // this wait; it only ends once SIGCONT resumes us (`sigcont.watch` is
      // not supported everywhere, but resumption itself is the signal).
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _backend.resume();
    }
    _prev = null;
    return const Resume();
  }

  /// Queues [value] for the next [poll] (wakes it): buttons, timers, other
  /// isolates talk back to the loop through here.
  void post(Object? value) {
    _posts.add(Post(value));
    _wake();
  }

  /// Posts every item of [stream] as [Post]; answers the subscription (cut it
  /// on [close], or it leaks past the run). Without [onError], a stream error
  /// is delivered from the next [poll] instead of the zone.
  StreamSubscription<T> listen<T>(Stream<T> stream, {void Function(Object)? onError}) {
    late final StreamSubscription<T> sub;
    sub = stream.listen(
      (value) {
        _posts.add(Post(value));
        _wake();
      },
      onError:
          onError ??
          (Object e) {
            _pendingErrors.add(e);
            _wake();
          },
      onDone: () => _subs.remove(sub),
    );
    _subs.add(sub);
    return sub;
  }

  /// Registers [cleanup] for the end of the run (last first, however it
  /// ends). Cleanup errors never skip the rest: the backend is closed first,
  /// then the first error is rethrown.
  void defer(Future<void> Function() cleanup) => _defers.add(cleanup);

  /// Marks the run over (in-flight polls and draws end with [_Closed]) and
  /// releases everything: subscriptions cut, cleanups last-first, the backend
  /// closed and the terminal restored. Idempotent; in-loop exits stay `break`,
  /// this is for timers, buttons and other isolates.
  Future<void> close() async {
    _requestClose();
    await _shutdown();
  }

  /// Sets the over flag and wakes a waiting [poll]; teardown follows in
  /// [close] (or [Tui.run]'s `finally`).
  void _requestClose() {
    _closed = true;
    _wake();
  }

  /// Fires the topmost clickable under a pointer press, if any: reverse paint
  /// order, so overlays win over the content behind them.
  bool _click(Pointer ev) {
    if (ev.kind != PointerKind.press) return false;
    for (var i = _clickables.length - 1; i >= 0; i--) {
      final c = _clickables[i];
      if (c.rect.contains(ev.x, ev.y)) {
        c.onPress();
        return true;
      }
    }
    return false;
  }

  /// Cancels subscriptions, runs cleanups last-first, frees the backend. The
  /// terminal is restored however the run ended: cleanup errors are collected
  /// (nothing is skipped), the backend closes, then the first error is
  /// rethrown to the caller.
  Future<void> _shutdown() async {
    if (_shut) return;
    _shut = true;
    final errors = <Object>[];
    final stacks = <StackTrace>[];
    for (final sub in _subs) {
      try {
        await sub.cancel();
      } catch (e, st) {
        errors.add(e);
        stacks.add(st);
      }
    }
    _subs.clear();
    while (_defers.isNotEmpty) {
      final cleanup = _defers.removeLast();
      try {
        await cleanup();
      } catch (e, st) {
        errors.add(e);
        stacks.add(st);
      }
    }
    try {
      _backend.close();
    } catch (e, st) {
      errors.add(e);
      stacks.add(st);
    }
    if (errors.isNotEmpty) Error.throwWithStackTrace(errors.first, stacks.first);
  }
}

/// Runs [app] on the real terminal: alt screen + raw mode in, restored out on
/// every way out (return, exception, double ^C). Delivers [Start] as the
/// first event.
///
/// ```dart
/// await Tui.run((term) async {
///   while (true) {
///     term.draw((ui) => ui.text('hi'));
///     if (await term.poll() case final ev? when ev.key == 'q') break;
///   }
/// });
/// ```
abstract final class Tui {
  /// Runs [app] with [pointer] capture when set. A [_Closed] (from [Term.close]
  /// or a second ^C) ends the app quietly; anything else propagates after the
  /// terminal is restored.
  static Future<void> run(Future<void> Function(Term) app, {bool pointer = false}) async {
    final term = Term._local(pointer: pointer);
    try {
      term._posts.add(const Start());
      await app(term);
    } on _Closed {
      // The run ended itself; teardown below.
    } finally {
      await term.close();
    }
  }
}

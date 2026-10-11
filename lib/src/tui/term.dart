/// The terminal app core: [Term], its backends, [Tui.run], and [FakeTerminal].
///
/// An app is a loop of `draw` and `poll` (proposal 12:1 verbatim):
///
/// ```dart
/// await Tui.run((term) async {
///   while (true) {
///     term.draw((ui) {
///       ui.box(title: 'App');
///       ui.text('Press "q" to exit.');
///     });
///     final ev = await term.poll();
///     if (ev?.key == 'q') break;
///   }
/// });
/// ```
///
/// `draw` paints immediately (diff vs the previous frame); `poll` answers the
/// next event (`null` on timeout, or after [Term.quit]). Side effects are
/// [Term.post]/[listen]/[defer] (and the [Tui] statics delegating to the
/// ambient run). Everything is restored on every way out: normal return, quit,
/// exception, or a second ^C within two seconds.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;

import 'buffer.dart';
import 'canvas.dart';
import 'events.dart';
import 'native.dart';

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

  /// The next event, or `null` on [timeout].
  Future<TuiEvent?> pollOnce(Duration timeout);

  /// Leaves the alternate screen and restores terminal modes (restartable).
  void stop();

  /// Re-enters after [stop] (the suspend dance).
  void resume();

  /// Frees the backend for good.
  void close();
}

/// The `dart_toolkit_tui` backend: raw mode, alt screen, bracketed paste and
/// (on request) mouse capture; events parsed natively, cells painted from
/// Dart-computed diffs.
final class NativeBackend implements TermBackend {
  ffi.Pointer<ffi.Void> _handle;
  bool _stopped = false;

  NativeBackend._(this._handle);

  /// Takes the terminal (alt screen + raw mode). Without the library it is an
  /// [UnsupportedError]; without a terminal (piped output) a [TuiException].
  static NativeBackend start({bool pointer = false}) {
    if (!io.stdout.hasTerminal) throw const TuiException('no terminal to take over (output is piped)');
    final handle = _TuiNative.start(80, 24, pointer ? 1 : 0);
    if (handle == ffi.nullptr) throw TuiException('Cannot take the terminal: ${Lib2Tui.lastError()}');
    return NativeBackend._(handle);
  }

  @override
  (int, int) get size {
    final out = Lib2Tui.alloc(4).cast<ffi.Uint16>();
    try {
      if (_TuiNative.size(_handle, out, out + 1) < 0) {
        throw TuiException('Cannot measure the terminal: ${Lib2Tui.lastError()}');
      }
      return (out[0], out[1]);
    } finally {
      Lib2Tui.free(out.cast(), 4);
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
    Lib2Tui.withBytes(utf8.encode(ansi), (p, n) {
      if (_TuiNative.write(_handle, p, n) < 0) throw TuiException('Cannot paint: ${Lib2Tui.lastError()}');
    });
  }

  @override
  void cursor(int? col, int? row) {
    if (_stopped) return;
    _TuiNative.cursor(_handle, col ?? -1, row ?? -1);
  }

  @override
  Future<TuiEvent?> pollOnce(Duration timeout) async {
    final size = ffi.sizeOf<TkEvent>();
    final ev = Lib2Tui.alloc(size).cast<TkEvent>();
    try {
      final rc = _TuiNative.poll(_handle, ev, timeout.inMilliseconds);
      if (rc == 0) return null;
      if (rc < 0) throw TuiException('Cannot poll the terminal: ${Lib2Tui.lastError()}');
      return _decode(ev);
    } finally {
      Lib2Tui.free(ev.cast(), size);
    }
  }

  TuiEvent? _decode(ffi.Pointer<TkEvent> ev) {
    final e = ev.ref;
    switch (e.kind) {
      case 1:
        final name = _keyName(e.code);
        if (name == null) return null;
        return KeyPress(
          name,
          shift: e.mods & Lib2Tui.modShift != 0,
          ctrl: e.mods & Lib2Tui.modCtrl != 0,
          alt: e.mods & Lib2Tui.modAlt != 0,
        );
      case 2:
        return Resize(e.x, e.y);
      case 3:
        const kinds = PointerKind.values;
        final kind = e.w >= 0 && e.w < kinds.length ? kinds[e.w] : PointerKind.move;
        return Pointer(
          e.x,
          e.y,
          kind,
          button: e.code,
          shift: e.mods & Lib2Tui.modShift != 0,
          ctrl: e.mods & Lib2Tui.modCtrl != 0,
          alt: e.mods & Lib2Tui.modAlt != 0,
        );
      case 4:
        final text = utf8.decode(e.text.asTypedList(e.textLen), allowMalformed: true);
        Lib2Tui.freeGiven(e.text, e.textLen);
        return Paste(text);
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
      Lib2Tui.keyUp => 'up',
      Lib2Tui.keyDown => 'down',
      Lib2Tui.keyLeft => 'left',
      Lib2Tui.keyRight => 'right',
      Lib2Tui.keyHome => 'home',
      Lib2Tui.keyEnd => 'end',
      Lib2Tui.keyPageUp => 'pageUp',
      Lib2Tui.keyPageDown => 'pageDown',
      Lib2Tui.keyInsert => 'insert',
      Lib2Tui.keyDelete => 'delete',
      Lib2Tui.keyEnter => 'enter',
      Lib2Tui.keyTab => 'tab',
      Lib2Tui.keyBackspace => 'backspace',
      Lib2Tui.keyEsc => 'esc',
      _ when code >= Lib2Tui.keyF && code < Lib2Tui.keyF + 24 => 'f${code - Lib2Tui.keyF + 1}',
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
    _TuiNative.free(h);
  }
}

/// The native `tk_tui_*` calls behind [NativeBackend].
abstract final class _TuiNative {
  static ffi.DynamicLibrary get _lib => Lib2Tui.require();

  static final start = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Uint16, ffi.Uint16, ffi.Uint8),
        ffi.Pointer<ffi.Void> Function(int, int, int)
      >('tk_tui_start');

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

  static final poll = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<TkEvent>, ffi.Uint64),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<TkEvent>, int)
      >('tk_tui_poll');

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

/// A terminal app: `draw` frames, `poll` events. Made by [Tui.run] (real
/// terminal) or [FakeTerminal] (tests).
class Term {
  final TermBackend _backend;
  Grid? _prev;
  final Queue<TuiEvent> _posts = Queue();
  final List<Future<void> Function()> _defers = [];
  final List<StreamSubscription<dynamic>> _subs = [];
  List<Clickable> _clickables = [];
  bool _quit = false;
  DateTime? _lastInterrupt;
  bool _suspendArmed = false;

  /// Current size in columns × rows (a [Resize] event updates it).
  int width, height;

  /// Colour capability, read once from the backend.
  late final ColorLevel colorLevel = _backend.colorLevel;

  Term(this._backend) : width = _backend.size.$1, height = _backend.size.$2;

  /// The real terminal (alt screen + raw mode). Without the library it is an
  /// [UnsupportedError]; piped output is a [TuiException].
  factory Term.local({bool pointer = false}) => Term(NativeBackend.start(pointer: pointer));

  /// Paints one frame: [build] fills a fresh grid, the diff vs the previous
  /// frame goes to the terminal, overlays last.
  void draw(void Function(Canvas) build) {
    final grid = Grid(width, height);
    final ui = Canvas(grid);
    build(ui);
    ui.paintOverlays();
    _clickables = ui.clickables;
    final changes = diff(_prev, grid);
    _prev = grid;
    _backend.show(grid, changes, encodeChanges(changes, colorLevel));
    final cursor = ui.cursorPos;
    _backend.cursor(cursor?.$1, cursor?.$2);
  }

  /// The next event: queued posts first, then the terminal. Awaits at most
  /// [timeout] (`null` waits for the next event). Answers `null` on timeout
  /// or after [quit].
  Future<TuiEvent?> poll({Duration? timeout}) async {
    if (_posts.isNotEmpty) return _posts.removeFirst();
    if (_quit) return null;
    if (_suspendArmed) return _resume();
    final ev = timeout == null ? await _pollForever() : await _backend.pollOnce(timeout);
    if (ev == null) return null;
    return _through(ev);
  }

  /// Unprocessed backend events until one arrives or [_quit]; [poll] runs
  /// [_through] on the answer exactly once.
  Future<TuiEvent?> _pollForever() async {
    while (true) {
      final ev = await _backend.pollOnce(const Duration(milliseconds: 250));
      if (ev != null) return ev;
      if (_posts.isNotEmpty) return _posts.removeFirst();
      if (_quit) return null;
    }
  }

  TuiEvent _through(TuiEvent ev) {
    if (ev is Resize) {
      width = ev.width;
      height = ev.height;
      _prev = null; // a new size repaints whole
      return ev;
    }
    if (ev is Interrupt) {
      final now = DateTime.now();
      if (_lastInterrupt != null && now.difference(_lastInterrupt!) < const Duration(seconds: 2)) _quit = true;
      _lastInterrupt = now;
      return ev;
    }
    if (ev is Suspend) {
      _suspendArmed = true;
      return ev;
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
      await io.ProcessSignal.sigcont.watch().first;
      _backend.resume();
    }
    _prev = null;
    return const Resume();
  }

  /// Queues [message] for the next [poll] (wakes it): buttons, timers, other
  /// isolates talk back to the loop through here.
  void message(Object? message) => _posts.add(Post(message));

  /// Runs [future] and posts its value; [onError] (else the zone) hears a
  /// failure. Never blocks the loop.
  void post(Future<dynamic> future, {void Function(Object)? onError}) {
    future.then(
      (value) => _posts.add(Post(value)),
      onError: (Object e) {
        if (onError != null) {
          onError(e);
        } else {
          Zone.current.handleUncaughtError(e, StackTrace.current);
        }
      },
    );
  }

  /// Posts every item of [stream] as [Post]; answers the subscription (cut it
  /// on [close], or it leaks past the run).
  StreamSubscription<T> listen<T>(Stream<T> stream, {void Function(Object)? onError}) {
    late final StreamSubscription<T> sub;
    sub = stream.listen(
      (value) => _posts.add(Post(value)),
      onError: onError ?? (Object e) => Zone.current.handleUncaughtError(e, StackTrace.current),
      onDone: () => _subs.remove(sub),
    );
    _subs.add(sub);
    return sub;
  }

  /// Registers [cleanup] for the end of the run (last first, however it
  /// ends). A failing cleanup is reported to the zone, never the outcome.
  void defer(Future<void> Function() cleanup) => _defers.add(cleanup);

  /// Ends the run after the current [poll]: in-loop exits stay `break`, this
  /// is for timers, buttons and other isolates.
  void quit() => _quit = true;

  /// Fires the clickable under a pointer press, if any.
  bool click(Pointer ev) {
    if (ev.kind != PointerKind.press) return false;
    for (final c in _clickables) {
      if (c.rect.contains(ev.x, ev.y)) {
        c.onPressed();
        return true;
      }
    }
    return false;
  }

  /// Cancels subscriptions, runs cleanups last-first, frees the backend. The
  /// terminal is restored however the run ended.
  Future<void> close() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    while (_defers.isNotEmpty) {
      final cleanup = _defers.removeLast();
      try {
        await cleanup();
      } catch (e, st) {
        Zone.current.handleUncaughtError(e, st);
      }
    }
    _backend.close();
  }
}

/// Runs [app] on the real terminal: alt screen + raw mode in, restored out on
/// every way out (return, [Term.quit], exception, double ^C). Delivers [Start]
/// as the first event.
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
  static const _key = #tuiTerm;

  /// Runs [app] with [pointer] capture when set.
  static Future<void> run(Future<void> Function(Term) app, {bool pointer = false}) async {
    final term = Term.local(pointer: pointer);
    try {
      await runZoned(() async {
        term._posts.add(const Start());
        await app(term);
      }, zoneValues: {_key: term});
    } finally {
      await term.close();
    }
  }

  static Term get _ambient =>
      Zone.current[_key] as Term? ?? (throw StateError('No Tui app running: Tui.post/listen/defer/quit need Tui.run'));

  /// Runs [future] and posts its value to the ambient app.
  static void post(Future<dynamic> future, {void Function(Object)? onError}) => _ambient.post(future, onError: onError);

  /// Posts every item of [stream] to the ambient app.
  static StreamSubscription<T> listen<T>(Stream<T> stream, {void Function(Object)? onError}) =>
      _ambient.listen(stream, onError: onError);

  /// Registers [cleanup] for the end of the ambient run.
  static void defer(Future<void> Function() cleanup) => _ambient.defer(cleanup);

  /// Ends the ambient run after the current poll.
  static void quit() => _ambient.quit();

  /// Queues [message] for the ambient app's next poll.
  static void message(Object? message) => _ambient.message(message);
}

/// The in-memory terminal tests drive: a [Term] over recorded cells.
///
/// ```dart
/// final term = FakeTerminal(width: 20, height: 6);
/// term.draw((ui) => ui.text('hi'));
/// expect(term.snapshot, ['hi', '', '', '', '', '']);
/// term.send('q');
/// expect(await term.poll(), KeyPress('q'));
/// ```
final class FakeTerminal extends Term {
  FakeTerminal({int width = 80, int height = 24, ColorLevel colorLevel = ColorLevel.truecolor})
    : super(FakeBackend(width, height, colorLevel));

  FakeBackend get _fake => super._backend as FakeBackend;

  /// Whether [close] ran on the backend.
  bool get closed => _fake.closed;

  /// Frames painted so far (cell grids).
  List<Grid> get frames => _fake.frames;

  /// Changed-cell counts per frame (the diff budget tests assert on).
  List<int> get changeCounts => _fake.changeCounts;

  /// Raw ANSI bytes written so far.
  String get bytes => _fake.bytes;

  /// The latest frame as text rows.
  List<String> get snapshot => frames.isEmpty ? List.filled(height, '') : frames.last.rows;

  /// Injects a key press.
  void send(String name, {bool ctrl = false, bool alt = false, bool shift = false}) =>
      _fake.inject(KeyPress(name, ctrl: ctrl, alt: alt, shift: shift));

  /// Injects typed text, one key per character.
  void sendText(String text) {
    for (var i = 0; i < text.length; i++) {
      _fake.inject(KeyPress(text[i]));
    }
  }

  /// Injects ^C the way the native backend delivers it: as [Interrupt], never
  /// as a key.
  void interrupt() => _fake.inject(const Interrupt());

  /// Injects a bracketed paste.
  void sendPaste(String text) => _fake.inject(Paste(text));

  /// Injects a pointer press (tap).
  void tap(int x, int y, {int button = 0}) => _fake.inject(Pointer(x, y, PointerKind.press, button: button));

  /// Resizes the screen: the next poll answers [Resize], the next draw is whole.
  void resize(int width, int height) => _fake.resize(width, height);
}

/// The recording backend behind [FakeTerminal]: frames, diff counts and bytes
/// are kept; injected events answer polls.
final class FakeBackend implements TermBackend {
  int _width, _height;
  final ColorLevel _colorLevel;
  final Queue<TuiEvent> _injected = Queue();
  final List<Grid> frames = [];
  final List<int> changeCounts = [];
  final StringBuffer _bytes = StringBuffer();
  bool closed = false;

  FakeBackend(this._width, this._height, this._colorLevel);

  @override
  (int, int) get size => (_width, _height);

  @override
  ColorLevel get colorLevel => _colorLevel;

  @override
  void show(Grid grid, List<Change> changes, String ansi) {
    frames.add(grid);
    changeCounts.add(changes.length);
    _bytes.write(ansi);
  }

  String get bytes => _bytes.toString();

  @override
  void cursor(int? col, int? row) {}

  @override
  Future<TuiEvent?> pollOnce(Duration timeout) async {
    if (_injected.isNotEmpty) return _injected.removeFirst();
    await Future<void>.delayed(timeout);
    return _injected.isNotEmpty ? _injected.removeFirst() : null;
  }

  /// Queues [ev] for the next poll.
  void inject(TuiEvent ev) => _injected.add(ev);

  /// Resizes and queues the [Resize] event.
  void resize(int width, int height) {
    _width = width;
    _height = height;
    _injected.add(Resize(width, height));
  }

  @override
  void stop() {}

  @override
  void resume() {}

  @override
  void close() {
    closed = true;
  }
}

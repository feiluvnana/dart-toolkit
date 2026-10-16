// Session: loop, zone, routing, App/Screen/Tui.
part of '../tui.dart';

/// An event binding: a shown label plus the action it runs.
/// Binding names list alternatives separated by spaces (`'b escape'`).
/// An empty label hides the binding from the key help.
typedef Binding = (String label, FutureOr<void> Function() action);

/// Mouse event names usable in [Binding] maps.
const _mouseNames = {'click', 'doubleclick', 'rightclick', 'middleclick', 'wheelup', 'wheeldown'};

/// Lifecycle event names usable in [Binding] maps.
const _lifecycleNames = {'show', 'resize', 'focus', 'blur'};

/// The height of a region that grows with its content (scroll bodies).
const _unbounded = 1 << 20;

bool _isMouse(String name) => _mouseNames.contains(name);
bool _isLifecycle(String name) => _lifecycleNames.contains(name);

final _checkedMaps = Expando<bool>('checked bindings');

/// [map] with every binding name checked where it is built: each
/// alternative is a key (`keys.canonicalize`), a mouse or a lifecycle
/// event, so a typo (`'escpae'`) is an [ArgumentError] instead of a key
/// that shows in the help and never fires.
Map<String, Binding> _checked(Map<String, Binding> map) {
  if (_checkedMaps[map] == true) return map;
  for (final name in map.keys) {
    for (final alt in keys.splitBinding(name)) {
      final lower = alt.toLowerCase();
      if (!_isMouse(lower) && !_isLifecycle(lower)) keys.canonicalize(alt);
    }
  }
  _checkedMaps[map] = true;
  return map;
}

bool _sameId(Object? a, Object? b) => identical(a, b) || (a is String && b is String && a == b);

/// The app handle handed to `screen` and bindings.
final class App<S> {
  App._(this._s);

  final _Session<S> _s;

  /// Switch state; the next redraw calls `screen` with it.
  void go(S state) => _s._go(state);

  /// A status-row message until the next [status] or error.
  void status(String message) => _s._say(message);

  /// Return the state from [Tui.run]. What the app still has in flight (its
  /// `work`, handlers) fails its pending toolkit waits with
  /// `InterruptedException`, as on Ctrl-C, and the script goes on.
  void quit() => _s._quit();
}

/// One screen description: a draw function plus title, status mode line and
/// key bindings.
/// An unknown binding name in [keys] is an [ArgumentError].
final class Screen {
  // ignore: prefer_initializing_formals – the public arguments keep their names.
  Screen(void Function(Region r) draw, {String? title, String? status, Map<String, Binding> keys = const {}})
    : _draw = draw,
      // ignore: prefer_initializing_formals
      _title = title,
      // ignore: prefer_initializing_formals
      _status = status,
      _keys = _checked(keys);

  final void Function(Region r) _draw;
  final String? _title;
  final String? _status;
  final Map<String, Binding> _keys;
}

/// Entry point: run a state-driven app.
abstract final class Tui {
  static bool _active = false;

  /// Own the loop: redraw (coalesced to 60 fps) after input, handler work,
  /// `go`/`status` and resize; spinners tick every 80 ms. Returns
  /// the state once [App.quit] is called. A second [run] while
  /// one is active throws [StateError]. Throws `StdoutException` when stdout
  /// is not a terminal (or `TERM=dumb`). Leave with [App.quit] (and `exitCode` for a status),
  /// never `exit()` in a handler: where dart leads the terminal's session
  /// (`ssh -t host dart app.dart`) the session ends before the terminal is
  /// restored, and it stays raw.
  ///
  /// [work] starts once the screen is shown; when it ends the screen stays
  /// until the app quits. Quitting first cancels it (its pending toolkit
  /// waits fail with `InterruptedException`, so its `finally` runs) and
  /// [run] returns once it has ended. An error it throws leaves the screen
  /// and is rethrown here. With no terminal (piped, `TERM=dumb`) [work]
  /// runs without a screen, Console printing its bars and log, and [run]
  /// returns when it ends.
  static Future<S> run<S>(
    S state,
    Screen Function(S state, App<S> app) screen, {
    Color? accent,
    Future<void> Function()? work,
  }) {
    if (_active) throw StateError('Tui.run is already active');
    _active = true;
    final session = _Session<S>(
      state,
      screen,
      out: io.stdout.write,
      size: () => (io.stdout.terminalColumns, io.stdout.terminalLines),
      accent: accent,
      work: work,
    );
    return session._run().whenComplete(() => _active = false);
  }
}

/// One focusable thing drawn this frame.
final class _F {
  _F(this.id, this.x, this.y, this.w, this.h, this.order, this.tryKey, {this.onMap});

  final Object id;
  final int x;
  final int y;
  final int w;
  final int h;
  final int order;
  final bool Function(_Ev ev)? tryKey;
  final Map<String, Binding>? onMap;
}

/// A routed input event.
sealed class _Ev {}

final class _KeyEv extends _Ev {
  _KeyEv(this.name, {this.text, this.paste = false, this.fallback = false});

  final String name;
  final String? text;
  final bool paste;

  /// Routing rule 5: offered to a drawn widget that isn't focused.
  final bool fallback;
}

final class _ClickEv extends _Ev {
  _ClickEv(this.x, this.y, this.kind);

  final int x;
  final int y;
  final String kind;
}

final class _WheelEv extends _Ev {
  _WheelEv(this.x, this.y, this.dir);

  final int x;
  final int y;
  final int dir;
}

final class _Session<S> implements term.TuiBridge {
  _Session(this._state, this._screenFn, {required this.out, required this.size, required this.accent, this.work});

  S _state;
  final Screen Function(S state, App<S> app) _screenFn;
  final void Function(String) out;
  final (int, int) Function() size;
  final Color? accent;
  final Future<void> Function()? work;
  late final App<S> app = App<S>._(this);

  /// What the app starts (handlers, [work]) runs in this scope: quitting
  /// cancels its toolkit waits.
  final _scope = exit.Scope();

  /// [work] running, never failing (its error becomes [_fatal]).
  Future<void>? _working;

  var _w = 80;
  var _h = 24;
  List<List<_Cell>> _grid = const [];
  List<List<_Cell>>? _shown;

  /// The cursor escape last written, so a move alone still paints.
  String? _shownCursor;
  var _repaint = true;

  final _pending = <int>[];
  final _signals = <String>[];
  int? _heldSince;
  var _heldLength = 0;

  (int, int)? _mouse;
  (int, int)? _lastClick;
  int _lastClickAt = 0;
  Object? _focusId;
  // Per-widget memory is held weakly (Expando), so widgets that are gone
  // are collected; string ids (buttons) live in a capped map.
  final _focusSeq = Expando<int>();
  final _strSeq = <String, int>{};
  var _seq = 0;
  final _focusables = <_F>[];
  var _order = 0;
  final _listStarts = Expando<int>();

  String? _sayMsg;
  String? _error;
  String? _statusLine;
  Map<String, Binding> _drawnKeys = const {};
  var _keysStale = false;

  /// Bindings of the current state: after [_go], rebuilt before the next
  /// redraw so a key arriving first never runs the old state's handler.
  Map<String, Binding> get _keys {
    if (_keysStale) {
      _keysStale = false;
      _drawnKeys = _screenFn(_state, app)._keys;
    }
    return _drawnKeys;
  }

  String? _title;
  Object? _shownState;

  final _popups = <_Popup>[];
  final _scrolls = <_ScrollCtx>[];
  final _drawnFields = <Field>{};
  final _clickBase = Expando<int>();
  final _suggests = <Field, _Suggest>{};
  _Suggest? _activeSg;
  final _prompts = <_Prompt>[];
  final _cBars = <Object, ({term.BarState Function() state, bool keep})>{};

  /// Bars that ended, shown as their ✓/✗ row for 2 s by `Region.bars`.
  final _cDone = <({term.BarState state, bool ok, int at})>[];

  /// Whether the last frame drew `Region.bars`/`Region.log`: Console's bars
  /// and lines then live there, not in the status row.
  var _barsShown = false, _logShown = false;
  var _termFocused = true;
  var _focusReported = false; // set by the first focus event
  var _statusY = 23;

  // Open-layout measuring (see [_measured]).
  List<int>? _mSlots;
  var _mNext = 0;
  final _mPending = <void Function()>[];
  final _mBuild = <int, int>{};
  var _refocused = false;
  var _spinVisible = false;

  /// The spinner frame follows the clock, so redraws from a busy stream
  /// can't starve it.
  int get _spinTick => _now() ~/ 80;
  (int, int)? _cursorPos;
  var _caps = _fallbackCaps;
  bool _testMode = false;

  var _dirty = true;
  var _quitFlag = false;
  Object? _fatal;
  StackTrace? _fatalStack;
  var _activeH = 0;
  var _done = false;
  Completer<void>? _waker;
  var _lastPaint = 0;
  final _subs = <StreamSubscription<Object?>>[];
  term.TermModes? _modes;
  var _entered = false;
  Zone? _zone;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  ZoneSpecification _spec() => ZoneSpecification(
    // Wake after the callback ran, so the redraw sees what it changed.
    scheduleMicrotask: (self, parent, zone, f) {
      parent.scheduleMicrotask(zone, () {
        try {
          f();
        } finally {
          _dirtyAndWake();
        }
      });
    },
    createTimer: (self, parent, zone, duration, f) => parent.createTimer(zone, duration, () {
      try {
        f();
      } finally {
        _dirtyAndWake();
      }
    }),
    createPeriodicTimer: (self, parent, zone, period, f) => parent.createPeriodicTimer(zone, period, (timer) {
      try {
        f(timer);
      } finally {
        _dirtyAndWake();
      }
    }),
    // Stream and I/O callbacks (socket data, a reply's listen). Marks
    // the frame dirty on every callback, including each socket chunk of
    // a download started from a key: wakeups, not paints (frames are
    // still coalesced to 60 fps), so this stays as is. An optional
    // future throttle could dirty at most once per millisecond here.
    runUnary: <R, T>(self, parent, zone, R Function(T) f, T arg) {
      try {
        return parent.runUnary(zone, f, arg);
      } finally {
        _dirtyAndWake();
      }
    },
    handleUncaughtError: (self, parent, zone, e, st) {
      _handlerError(e, st);
      _dirtyAndWake();
    },
  );

  Future<T> _zoneRun<T>(Future<T> Function() fn) {
    final z = _zone;
    if (z == null) return fn();
    return z.run(fn);
  }

  // --- run loop ----------------------------------------------------------

  Future<S> _run() async {
    final refused = !io.stdout.hasTerminal
        ? 'no terminal for the TUI: stdout is piped or redirected (use Console for that output, or run in a terminal)'
        : term.TerminalCaps.isDumb(io.Platform.environment)
        ? 'TERM=dumb takes no escape sequences: no TUI (use Console)'
        : null;
    if (refused != null) {
      final work = this.work;
      if (work == null) throw io.StdoutException(refused);
      await work();
      return _state;
    }
    // Handlers run in the redraw zone; the loop itself stays outside it, or
    // its own timers and awaits would wake it forever and starve I/O.
    runZoned(() => _zone = Zone.current, zoneSpecification: _spec(), zoneValues: _scope.values);
    // An error no handler owns (a timer the script started earlier) would
    // print on the alternate screen and vanish with it: it fails the run
    // instead, so its trace lands after the screen is left.
    final uncaught = RawReceivePort((Object? m) {
      if (m case [final String e, final String? st]) {
        _fatal ??= _Uncaught(e);
        _fatalStack ??= StackTrace.fromString(st ?? '');
        _wake();
      }
    });
    Isolate.current
      ..setErrorsFatal(false)
      ..addErrorListener(uncaught.sendPort);
    await _enter();
    try {
      await _loop();
    } finally {
      Isolate.current
        ..removeErrorListener(uncaught.sendPort)
        ..setErrorsFatal(true);
      uncaught.close();
      _scope.cancel();
      await _leave();
      await _working;
    }
    // The work failed while it wound down.
    if (_fatal case final e?) Error.throwWithStackTrace(e, _fatalStack ?? StackTrace.empty);
    return _state;
  }

  /// Start [work] in the redraw zone, once the screen is shown.
  void _startWork() {
    final work = this.work;
    if (work == null) return;
    // Listened inside the zone: an error never crosses out of it.
    _working = _zone!.run(
      () => Future.sync(work).then(
        (_) => _dirtyAndWake(),
        onError: (Object e, StackTrace st) {
          if (e is InterruptedException && _scope.cancelled) return;
          _fatal ??= e;
          _fatalStack ??= st;
          _wake();
        },
      ),
    );
  }

  Future<void> _loop() async {
    _draw();
    _paint();
    _startWork();
    while (!_quitFlag) {
      if (_fatal != null) {
        final e = _fatal!;
        final st = _fatalStack ?? StackTrace.empty;
        _fatal = null;
        Error.throwWithStackTrace(e, st);
      }
      final active = _activeH > 0 || _spinVisible || _cBars.isNotEmpty;
      _waker ??= Completer<void>();
      final w = _waker!;
      // Wake on an event, or: when a redraw waits out the 60 fps gap, when
      // a held ESC or split sequence needs another look, or for the next
      // spinner frame.
      final wait = _dirty
          ? math.max(0, 16 - (_now() - _lastPaint))
          : _pending.isNotEmpty
          ? term.escapeWait.inMilliseconds
          : active
          ? 80
          : null;
      if (wait == null) {
        await w.future;
      } else {
        try {
          await w.future.timeout(Duration(milliseconds: wait));
        } on TimeoutException {
          if (!_dirty && _pending.isEmpty) {
            _dirty = true;
          }
        }
      }
      if (identical(_waker, w)) _waker = null;
      _pollInput();
      if (_dirty && _now() - _lastPaint >= 16) {
        _dirty = false;
        _draw();
        _paint();
      }
      try {
        final (w2, h2) = size();
        if (w2 != _w || h2 != _h) {
          _w = math.max(1, w2);
          _h = math.max(1, h2);
          _repaint = true;
          _fireLifecycle('resize');
          _dirty = true;
          _draw();
          _paint();
        }
      } catch (_) {}
    }
  }

  void _wake() {
    if (_done) return;
    final w = _waker;
    if (w != null && !w.isCompleted) w.complete();
  }

  void _dirtyAndWake() {
    if (_done) return;
    _dirty = true;
    _wake();
  }

  /// Show [e] in the status row: a toolkit error's message, anything else
  /// without its SDK type prefix (`HttpException: `, `FormatException: `,
  /// `Exception: `). [st] is kept and printed to stderr after the app quits
  /// (the alternate screen would hide it now).
  void _failStatus(Exception e, [StackTrace? st]) {
    final text = e is ToolkitException ? e.message : '$e'.replaceFirst(_sdkPrefix, '');
    _error = '$_failMark ${_firstLine(text)}';
    _sayMsg = null;
    if (st != null) {
      _errorLog.add((e, st));
      if (_errorLog.length > 20) _errorLog.removeAt(0);
    }
    _dirtyAndWake();
  }

  /// `✗`, or `x` where the locale is not UTF-8 (as in Console).
  String get _failMark => _caps.ascii ? 'x' : '✗';
  String get _okMark => _caps.ascii ? '+' : '✓';

  /// Handler failures shown in the status row, with their stacks, for
  /// stderr after [_leave] restores the terminal (the last 20).
  final _errorLog = <(Exception, StackTrace)>[];

  static final _sdkPrefix = RegExp(r'^(?:[A-Z]\w*)?(?:Exception|Error): ');

  static String _firstLine(String s) {
    final i = s.indexOf('\n');
    return (i < 0 ? s : s.substring(0, i)).trim();
  }

  // --- state ops ---------------------------------------------------------

  void _go(S state) {
    _state = state;
    _keysStale = true;
    _sayMsg = null;
    _dirtyAndWake();
  }

  void _say(String message) {
    _sayMsg = message;
    _error = null;
    _dirtyAndWake();
  }

  void _quit() {
    _quitFlag = true;
    _cancelPrompts();
    _wake();
  }

  /// Prompts still open get null, like escape, so their callers resume and
  /// run their `finally` blocks.
  void _cancelPrompts() {
    for (final p in [..._prompts]) {
      p.cancel();
    }
    _prompts.clear();
  }

  /// `Console.notify` while the app runs: silent while the terminal reports
  /// that it has focus; always sent when it never reports focus.
  @override
  void notify(String message) {
    if (_focusReported && _termFocused) return;
    out(term.notifyCodes(message));
  }

  /// `ConsoleUtils.copy` while the app runs.
  @override
  void copy(String text) => out(term.copyCodes(text));

  // --- term.TuiBridge (Console-in-Tui routing) -----------------------------

  @override
  Object barStarted(term.BarState Function() state, {required bool keep}) {
    final id = Object();
    _cBars[id] = (state: state, keep: keep);
    // New work replaces a stale message, so its progress shows.
    _sayMsg = _error = null;
    _dirtyAndWake();
    return id;
  }

  @override
  void barChanged(Object id) => _dirtyAndWake();

  @override
  void log(String line, {required bool failed}) {
    // Drawn by the screen's Region.log; else the status row says it.
    _logShown ? _dirtyAndWake() : _say(line);
  }

  @override
  void barEnded(Object id, bool ok) {
    final bar = _cBars.remove(id);
    if (bar != null && _barsShown) {
      if (bar.keep || !ok) _cDone.add((state: bar.state(), ok: ok, at: _now()));
    } else if (!ok && bar != null) {
      _error = '$_failMark ${bar.state().label ?? ''}'.trimRight();
    }
    _dirtyAndWake();
  }

  /// The rows `Region.bars` draws, each fitted to a width: the live bars,
  /// oldest first, then the ones that ended in the last 2 s.
  List<String Function(int width)> _barRows() {
    final now = _now();
    _cDone.removeWhere((d) => now - d.at > 2000);
    final frames = fmt.spinFrames(ascii: _caps.ascii);
    return [
      for (final bar in _cBars.values)
        if (bar.state() case final b)
          (w) => b.spinning
              ? term.truncateWidth('${frames[_spinTick % frames.length]} ${b.label ?? ''}'.trimRight(), w)
              : term.barLine(w, label: b.label, done: b.done, total: b.total, unit: b.unit, rate: b.rate, ascii: _caps.ascii),
      for (final d in _cDone)
        (w) => term.truncateWidth(
          '${d.ok ? _okMark : _failMark} ${d.state.label ?? ''}  ${fmt.fmtCounts(d.state.done, d.state.total, d.state.unit)}'.trimRight(),
          w,
        ),
    ];
  }

  @override
  Future<String?> promptAsk(String question, {required bool secret, Duration? timeout}) {
    final p = _Ask(question, secret: secret);
    return _open(p, p.done, timeout);
  }

  @override
  Future<bool?> promptConfirm(String question, bool or, {Duration? timeout}) {
    final p = _Confirm(question, or);
    return _open(p, p.done, timeout);
  }

  @override
  Future<String?> promptChoose(String question, List<String> choices, int initial, {Duration? timeout}) {
    if (choices.isEmpty) {
      throw ArgumentError.value(choices, 'choices', 'must not be empty');
    }
    final p = _Choose(question, choices, initial);
    return _open(p, p.done, timeout);
  }

  @override
  Future<List<int>?> promptPick(String question, List<String> choices, Set<int> initial, {Duration? timeout}) {
    if (choices.isEmpty) {
      throw ArgumentError.value(choices, 'choices', 'must not be empty');
    }
    final p = _Choose(question, choices, initial.isEmpty ? 0 : initial.reduce(math.min), marked: {...initial});
    return _open(p, p.picks, timeout);
  }

  /// Show prompt [p]; after [timeout] with no answer it closes like Escape.
  Future<T?> _open<T>(_Prompt p, Completer<T?> done, Duration? timeout) {
    if (_done || _quitFlag) p.cancel(); // after quit: no screen to answer on
    _prompts.add(p);
    _dirtyAndWake();
    if (timeout == null || done.isCompleted) return done.future;
    final timer = Timer(timeout, () {
      if (done.isCompleted) return;
      _prompts.remove(p);
      p.cancel();
      _dirtyAndWake();
    });
    return done.future.whenComplete(timer.cancel);
  }

  /// One identity per key set, so a `Region.on` region is the same
  /// focusable on every frame.
  final _bindIds = <String, Object>{};
  Object _bindId(Map<String, Binding> events) => _bindIds.putIfAbsent(events.keys.join('\x00'), Object.new);

  void _setFocus(Object id) {
    if (!_sameId(_focusId, id)) {
      _focusId = id;
      _stampFocus(id);
    }
  }

  int _focusStamp(Object id) => (id is String ? _strSeq[id] : _focusSeq[id]) ?? -1;

  void _stampFocus(Object id) {
    if (id is! String) {
      _focusSeq[id] = ++_seq;
      return;
    }
    if (_strSeq.length > 256) _strSeq.clear();
    _strSeq[id] = ++_seq;
  }

  void _addFocusable(
    Object id,
    int x,
    int y,
    int w,
    int h,
    int order,
    bool Function(_Ev ev)? tryKey, {
    Map<String, Binding>? onMap,
  }) {
    _focusables.add(_F(id, x, y, w, h, order, tryKey, onMap: onMap == null ? null : _checked(onMap)));
  }

  int _listStart(Object id, int n, int h) => _listStarts[id]?.clamp(0, math.max<int>(0, n - h)) ?? 0;

  void _listStartSave(Object id, int start) => _listStarts[id] = start;

  final _styleCache = <(Color?, Color?, int), int>{};
  final _styles = <(Color?, Color?, int)>[];

  /// SGR text per packed style id, built once per id for [_sgrCaps]; cleared
  /// with the style table or when the capabilities change.
  final _sgrCache = <int, String>{};
  term.TerminalCaps? _sgrCaps;

  /// Last-layout memos, one per markdown call site (see [_mdLayout]):
  /// an `identical` source is an O(1) hit, a streamed append re-lays only
  /// from the last block boundary.
  final _mdMemos = <_MdMemo>[];

  /// Markdown runs: fenced code in the accent, or dim without one.
  int _mdStyle(_MdSeg g, Color? color, Color? background, Set<Style> style) => accent != null || color != null
      ? _pack(g.fg == _mdCode ? (accent ?? color) : g.fg ?? color, g.bg ?? background, {...g.style, ...style})
      : _pack(null, background, g.fg == Color.gray ? {...g.style, ...style, Style.dim} : {...g.style, ...style});

  /// A selected row or tab: bold on [highlight], else the accent, else
  /// reverse video.
  int _selected(Color? highlight, Color? fg, Set<Style> style) {
    final bg = highlight ?? accent;
    return _pack(bg == null ? fg : null, bg, {...style, Style.bold, if (bg == null) Style.reverse});
  }

  int _pack(Color? fg, Color? bg, Set<Style> style) {
    var bits = 0;
    for (final s in style) {
      bits |= switch (s) {
        Style.bold => 1,
        Style.dim => 2,
        Style.italic => 4,
        Style.underline => 8,
        Style.strike => 16,
        Style.reverse => 32,
      };
    }
    return _packBits(fg, bg, bits);
  }

  int _packBits(Color? fg, Color? bg, int bits) {
    if (fg == null && bg == null && bits == 0) return 0;
    final key = (fg, bg, bits);
    return _styleCache.putIfAbsent(key, () {
      _styles.add(key);
      return _styles.length;
    });
  }

  (Color?, Color?, int) _unpack(int packed) =>
      packed == 0 || packed > _styles.length ? (null, null, 0) : _styles[packed - 1];
  // --- input -------------------------------------------------------------

  void _pollInput() {
    _decode();
    for (final name in _signals) {
      _routeKey(name);
    }
    _signals.clear();
    if (_pending.isEmpty) {
      _heldSince = null;
      return;
    }
    final now = _now();
    if (_heldSince == null || _pending.length != _heldLength) {
      _heldSince = now;
      _heldLength = _pending.length;
      return;
    }
    // One resolver with the Console prompts: a lone ESC is Escape, a split
    // UTF-8 character (Vietnamese, CJK over SSH) is never Escape, and an
    // unterminated paste waits for its end.
    final key = term.resolveHeld(_pending, Duration(milliseconds: now - _heldSince!));
    if (key == null) return;
    _pending.clear();
    _heldSince = null;
    if (key.isNotEmpty) _routeKey(key);
  }

  void _decode() {
    if (_pending.isEmpty) return;
    final parsed = term.decodeKeys(_pending);
    _pending.removeRange(0, parsed.consumed);
    for (final event in parsed.events) {
      switch (event) {
        case term.TermKey(:final name):
          _routeKey(name);
        case term.TermType(:final text, :final paste):
          _routeText(text, paste);
        case term.TermClick(:final x, :final y, :final kind):
          _mouse = (x, y);
          _clickAt(kind, x, y);
        case term.TermHover(:final x, :final y):
          _mouse = (x, y);
          _released(); // motion without a button: let go
          _dirtyAndWake();
        case term.TermDrag(:final x, :final y):
          _mouse = (x, y);
          final drag = _dragging;
          if (drag != null) {
            for (final ctx in _scrolls) {
              if (identical(ctx.scroll, drag)) _scrollTo(ctx, y);
            }
          } else {
            _selectTo(x, y);
          }
        case term.TermRelease():
          _released();
        case term.TermFocus(:final gained):
          _termFocused = gained;
          _focusReported = true;
          _fireLifecycle(gained ? 'focus' : 'blur');
          _dirtyAndWake();
      }
    }
  }

  /// The scroll whose scrollbar the left button is dragging.
  Scroll? _dragging;

  /// Where the left button went down: a drag from there selects text.
  (int, int)? _pressAt;

  /// The selection, as (x, y) screen cells from where the drag began to
  /// where it is; rows run within [_selCols] (the scroll it began in, else
  /// the whole width). Drawn reversed until the next click.
  (int, int)? _selFrom, _selTo;
  var _selCols = (0, 0);
  var _selecting = false;

  void _selectTo(int x, int y) {
    final from = _pressAt;
    if (from == null) return;
    if (!_selecting) {
      _selecting = true;
      _selFrom = from;
      _selCols = (0, _w);
      for (final c in _scrolls) {
        if (from.$1 >= c.gx && from.$1 < c.gx + c.w - 1 && from.$2 >= c.gy && from.$2 < c.gy + c.viewH) {
          _selCols = (c.gx, c.gx + c.w - 1); // the scrollbar is not text
        }
      }
    }
    _selTo = (x.clamp(_selCols.$1, _selCols.$2 - 1), y.clamp(0, math.max(0, _h - 1)));
    _dirtyAndWake();
  }

  /// The button let go: a selection is copied (OSC 52).
  void _released() {
    _dragging = null;
    _pressAt = null;
    if (!_selecting) return;
    _selecting = false;
    final text = _selText();
    if (text.isEmpty) return;
    copy(text);
    _say('copied ${text.length} characters');
  }

  /// The selected cells, row by row: (y, first x, last x), inclusive.
  Iterable<(int, int, int)> _selRows() sync* {
    final a = _selFrom, b = _selTo;
    if (a == null || b == null) return;
    final (start, end) = (a.$2 < b.$2 || (a.$2 == b.$2 && a.$1 <= b.$1)) ? (a, b) : (b, a);
    for (var y = start.$2; y <= end.$2 && y < _grid.length; y++) {
      yield (y, y == start.$2 ? start.$1 : _selCols.$1, y == end.$2 ? end.$1 : _selCols.$2 - 1);
    }
  }

  String _selText() => [
    for (final (y, x0, x1) in _selRows())
      [
        for (var x = x0; x <= x1 && x < _grid[y].length; x++)
          if (_grid[y][x].width > 0) _grid[y][x].ch,
      ].join().trimRight(),
  ].join('\n');

  /// Reverse the selected cells of this frame.
  void _drawSelection() {
    for (final (y, x0, x1) in _selRows()) {
      for (var x = x0; x <= x1 && x < _grid[y].length; x++) {
        final c = _grid[y][x];
        final (fg, bg, bits) = c.style <= 0 ? (null, null, 0) : _styles[c.style - 1];
        _grid[y][x] = _Cell(c.ch, _packBits(fg, bg, bits ^ 32), c.width, link: c.link);
      }
    }
  }

  /// Put the scrollbar thumb at screen row [y] of [ctx]: the top row shows
  /// the start, the bottom row the end (which pins a following scroll).
  void _scrollTo(_ScrollCtx ctx, int y) {
    final maxOff = math.max(0, ctx.buf.length - ctx.viewH);
    final row = (y - ctx.gy).clamp(0, math.max(0, ctx.viewH - 1));
    final st = ctx.scroll;
    st._off = ctx.viewH <= 1 ? maxOff : (row * maxOff / (ctx.viewH - 1)).round();
    st._pinned = st._off >= maxOff;
    _dirtyAndWake();
  }

  void _clickAt(String kind, int x, int y) {
    _dragging = null;
    _pressAt = kind == 'click' ? (x, y) : null;
    if (_selFrom != null) {
      _selFrom = _selTo = null;
      _dirty = true;
    }
    if (kind == 'click') {
      final now = _now();
      final last = _lastClick;
      if (last != null && last.$1 == x && last.$2 == y && now - _lastClickAt < 400) {
        _lastClick = null;
        _routeMouse('doubleclick', x, y);
        return;
      }
      _lastClick = (x, y);
      _lastClickAt = now;
    }
    _routeMouse(kind, x, y);
  }

  void _routeText(String text, bool paste) {
    if (text.isEmpty) return;
    // Fast typing arrives as one chunk: route it a character at a time, so
    // bindings and focus apply to each.
    if (!paste && text.runes.length > 1) {
      for (final r in text.runes) {
        _routeText(String.fromCharCode(r), false);
      }
      return;
    }
    if (_prompts.isNotEmpty) {
      _promptRouteText(text, paste);
      return;
    }
    final single = !paste && text.runes.length == 1;
    // Focused on-region bindings and buttons come before falling back.
    if (single) {
      final r = text.runes.single;
      final nm = r == 0x20 ? 'space' : String.fromCharCode(r);
      final fid = _focusId;
      if (fid != null && fid is! Field && fid is! String) {
        for (final f in _focusables) {
          if (identical(f.id, fid) && f.onMap != null) {
            final b = _lookup(f.onMap!, nm);
            if (b != null) {
              _invoke(b.$2);
              return;
            }
            break;
          }
        }
      }
      if (fid is String) {
        _routeKey(nm); // focused button: space/letters are keys
        return;
      }
      // Screen keys before the rule-5 input fallback (mirrors 4-before-5);
      // a focused input (rule 2) takes its text first.
      final b = fid is Field ? null : _lookup(_keys, nm);
      if (b != null) {
        _invoke(b.$2);
        return;
      }
    }
    _F? target;
    for (final f in _focusables) {
      if (f.id is Field && f.tryKey != null && _sameId(f.id, _focusId)) {
        target = f;
        break;
      }
    }
    target ??= _focusables.where((f) => f.id is Field && f.tryKey != null).firstOrNull;
    if (target != null) {
      target.tryKey!(_KeyEv('', text: text, paste: paste));
      return;
    }
    if (single) {
      final r = text.runes.single;
      _routeKey(r == 0x20 ? 'space' : String.fromCharCode(r));
    }
  }

  bool _routeKey(String name) {
    if (name == 'ctrl+z' && _modes?.isigCleared == true && _lookup(_keys, name) == null) {
      unawaited(_suspend());
      return true;
    }
    // 1. Open popup (suggest list, Console prompts).
    if (_routeSuggest(name)) return true;
    if (_prompts.isNotEmpty && _promptKey(_prompts.last, name)) return true;
    if (name == 'wheelup' || name == 'wheeldown') {
      final m = _mouse;
      if (m != null) {
        return _routeWheel(m.$1, m.$2, name == 'wheelup' ? -1 : 1);
      }
    }
    final fid = _focusId;
    if (fid != null) {
      for (final f in _focusables) {
        if (_sameId(f.id, fid) && f.tryKey != null) {
          if (f.tryKey!(_KeyEv(name))) return true;
          break;
        }
      }
      for (final f in _focusables) {
        if (_sameId(f.id, fid) && f.onMap != null) {
          final b = _lookup(f.onMap!, name);
          if (b != null) {
            _invoke(b.$2);
            return true;
          }
          break;
        }
      }
    }
    if (name == 'tab' || name == 'shift+tab') {
      if (!_bindsTab(name)) {
        _moveFocus(name == 'tab' ? 1 : -1);
        return true;
      }
    }
    final b = _lookup(_keys, name);
    if (b != null) {
      _invoke(b.$2);
      return true;
    }
    for (final f in _focusables) {
      if (_sameId(f.id, fid)) continue;
      if (f.tryKey != null && f.tryKey!(_KeyEv(name, fallback: true))) {
        return true;
      }
    }
    for (final f in _focusables) {
      if (_sameId(f.id, fid)) continue;
      if (f.onMap != null) {
        final ob = _lookup(f.onMap!, name);
        if (ob != null) {
          _setFocus(f.id);
          _invoke(ob.$2);
          return true;
        }
      }
    }
    if (name == 'ctrl+c') {
      _quit();
      return true;
    }
    return false;
  }

  bool _bindsTab(String name) {
    if (_lookup(_keys, name) != null) return true;
    final fid = _focusId;
    if (fid != null) {
      for (final f in _focusables) {
        if (_sameId(f.id, fid) && f.onMap != null) {
          if (_lookup(f.onMap!, name) != null) return true;
        }
      }
    }
    return false;
  }

  void _moveFocus(int dir) {
    if (_focusables.isEmpty) return;
    var idx = _focusables.indexWhere((f) => _sameId(f.id, _focusId));
    idx = idx < 0 ? (dir > 0 ? -1 : 0) : idx;
    idx = (idx + dir) % _focusables.length;
    if (idx < 0) idx += _focusables.length;
    _setFocus(_focusables[idx].id);
    _dirtyAndWake();
  }

  Binding? _lookup(Map<String, Binding> map, String name) {
    for (final entry in map.entries) {
      if (keys.matchesBinding(entry.key, name)) return entry.value;
    }
    return null;
  }

  bool _routeMouse(String kind, int x, int y) {
    if (_prompts.isNotEmpty) return _promptMouse(kind, x, y);
    _F? best;
    var bestArea = 1 << 30;
    var bestOrder = -1;
    for (final f in _focusables) {
      final mouseable = (kind == 'click' && f.tryKey != null) || (f.onMap != null && _lookup(f.onMap!, kind) != null);
      if (!mouseable) continue;
      if (x < f.x || x >= f.x + f.w || y < f.y || y >= f.y + f.h) continue;
      final area = f.w * f.h;
      if (area < bestArea || (area == bestArea && f.order > bestOrder)) {
        best = f;
        bestArea = area;
        bestOrder = f.order;
      }
    }
    if (best != null) {
      if (kind == 'click' && best.tryKey != null) {
        if (best.tryKey!(_ClickEv(x, y, kind))) return true;
      }
      if (best.onMap != null) {
        final b = _lookup(best.onMap!, kind);
        if (b != null) {
          _setFocus(best.id);
          _invoke(b.$2);
          return true;
        }
      }
    }
    final b = _lookup(_keys, kind);
    if (b != null) {
      _invoke(b.$2);
      return true;
    }
    return false;
  }

  bool _routeWheel(int x, int y, int dir) {
    if (_prompts.isNotEmpty) {
      final p = _prompts.last;
      if (p is _Choose) {
        return _promptKey(p, dir < 0 ? 'wheelup' : 'wheeldown');
      }
      return true; // modal: swallow
    }
    _F? best;
    var bestArea = 1 << 30;
    var bestOrder = -1;
    for (final f in _focusables) {
      if (f.tryKey == null) continue;
      if (x < f.x || x >= f.x + f.w || y < f.y || y >= f.y + f.h) continue;
      final area = f.w * f.h;
      if (area < bestArea || (area == bestArea && f.order > bestOrder)) {
        best = f;
        bestArea = area;
        bestOrder = f.order;
      }
    }
    if (best != null && best.tryKey!(_WheelEv(x, y, dir))) return true;
    final b = _lookup(_keys, dir < 0 ? 'wheelup' : 'wheeldown');
    if (b != null) {
      _invoke(b.$2);
      return true;
    }
    return false;
  }

  void _invoke(FutureOr<void> Function() action) {
    _activeH++;
    _dirtyAndWake();
    try {
      final r = _zone != null ? _zone!.run(action) : action();
      if (r is Future) {
        r.then(
          (_) {
            _activeH--;
            _dirtyAndWake();
          },
          onError: (Object e, StackTrace st) {
            _activeH--;
            _handlerError(e, st);
            _dirtyAndWake();
          },
        );
      } else {
        _activeH--;
      }
    } catch (e, st) {
      _activeH--;
      _handlerError(e, st);
    }
  }

  void _handlerError(Object e, StackTrace st) {
    if (e is InterruptedException && _scope.cancelled) return; // quit while it waited
    if (e is Exception) {
      _failStatus(e, st);
    } else {
      _fatal ??= e;
      _fatalStack ??= st;
      _wake();
    }
  }

  void _fireLifecycle(String name) {
    final b = _lookup(_keys, name);
    if (b != null) _invoke(b.$2);
  }
  // --- draw & paint ------------------------------------------------------

  /// Clear what one draw pass registers.
  void _resetFrame() {
    _focusables.clear();
    _popups.clear();
    _scrolls.clear();
    _drawnFields.clear();
    _activeSg = null;
    _order = 0;
    _spinVisible = false;
    _barsShown = _logShown = false;
    _cursorPos = null;
    for (final row in _grid) {
      row.fillRange(0, row.length, _Cell.blank);
    }
  }

  /// Run [draw] until the heights of open `rows`/`box` settle: the first
  /// pass measures, later passes lay out with the measures (at most 4).
  void _measured(void Function() draw, void Function() reset) {
    _mSlots = null;
    _mNext = 0;
    _mPending.clear();
    _mBuild.clear();
    draw();
    for (var pass = 0; _mNext > 0 && pass < 4; pass++) {
      for (final resolve in _mPending.reversed) {
        resolve();
      }
      final next = List<int>.generate(_mNext, (k) => _mBuild[k] ?? 0);
      final was = _mSlots;
      if (was != null &&
          was.length == next.length &&
          Iterable<int>.generate(next.length).every((k) => was[k] == next[k])) {
        break;
      }
      reset();
      _mSlots = next;
      _mNext = 0;
      _mPending.clear();
      _mBuild.clear();
      draw();
    }
    _mSlots = null;
    _mNext = 0;
    _mPending.clear();
    _mBuild.clear();
  }

  /// Build and draw one frame. [reuse] is this frame's [Screen] when the
  /// refocus pass draws again: the screen function runs once per frame.
  void _draw([Screen? reuse]) {
    if (_styles.length > 4096) {
      // Packed ids die with the table; every cell is re-packed this frame.
      _styleCache.clear();
      _styles.clear();
      _sgrCache.clear();
      _repaint = true;
    }
    _resetFrame();
    if (!_testMode) _caps = term.TerminalCaps.forStdout; // cached per run
    // Fresh working grid every draw; _shown keeps last-painted state so the
    // paint still writes only changed cells.
    if (_grid.length != _h || _grid.isNotEmpty && _grid.first.length != _w) {
      _grid = List.generate(_h, (_) => List.filled(_w, _Cell.blank));
      _shown = null;
      _repaint = true;
    }
    final screen = reuse ?? _screenFn(_state, app);
    _keysStale = false;
    _drawnKeys = screen._keys;
    _title = screen._title;
    _statusLine = screen._status;
    final h = _h;
    final titleH = screen._title == null ? 0 : 1;
    final bodyH = math.max(0, h - titleH - 1);
    if (_grid.length != h) {
      _grid = List.generate(h, (_) => List.filled(_w, _Cell.blank));
      _shown = null;
      _repaint = true;
    }
    _measured(() {
      screen._draw(Region._(this, _grid, 0, titleH, _w, bodyH));
      if (titleH == 1) {
        Region._(
          this,
          _grid,
          0,
          0,
          _w,
          1,
        ).write(' ${_title ?? ''} ', color: accent, style: accent == null ? {Style.reverse} : {});
      }
    }, _resetFrame);
    _statusY = _h - 1;
    _drawStatus();
    _compositeScrolls();
    _drawPrompt();
    _compositePopups();
    if (_focusables.isNotEmpty && !_focusables.any((f) => _sameId(f.id, _focusId))) {
      _F? best;
      for (final f in _focusables) {
        if (best == null || _focusStamp(f.id) > _focusStamp(best.id)) best = f;
      }
      best ??= _focusables.first;
      _focusId = best.id;
      _stampFocus(best.id);
      // Draw again so the newly focused widget shows its focus (cursor,
      // accent) in this frame, not the next.
      if (!_refocused) {
        _refocused = true;
        try {
          _draw(screen);
        } finally {
          _refocused = false;
        }
        return;
      }
    }
    _drawSelection();
    if (!identical(_shownState, _state)) {
      _shownState = _state;
      _fireLifecycle('show');
    }
    // Drop suggest state for fields that are no longer drawn.
    _suggests.removeWhere((field, sg) {
      if (_drawnFields.contains(field)) return false;
      if (identical(_activeSg, sg)) _activeSg = null;
      return true;
    });
  }

  void _drawStatus() {
    final y = _statusY;
    if (y < 0) return;
    String left;
    int leftStyle = 0;
    if (_error != null) {
      left = _error!;
      leftStyle = accent == null ? _pack(null, null, {Style.bold}) : _pack(Color.red, null, {});
    } else if (_sayMsg != null) {
      left = _sayMsg!;
    } else if (_cBars.isNotEmpty && !_barsShown) {
      left = _consoleStatus();
    } else if (_statusLine != null) {
      left = _statusLine!;
    } else {
      left = '';
    }
    final helps = <String>[];
    for (final entry in _keys.entries) {
      if (entry.value.$1.trim().isEmpty) continue;
      final alts = keys.splitBinding(entry.key).where((a) => !_isMouse(a) && !_isLifecycle(a)).toList();
      if (alts.isEmpty) continue;
      final shown = alts.first == 'escape' ? 'esc' : alts.first;
      helps.add('$shown ${entry.value.$1}');
    }
    var help = helps.join(' · ');
    final leftW = term.displayWidth(left);
    var helpW = term.displayWidth(help);
    while (help.isNotEmpty && leftW + 1 + helpW > _w) {
      final cut = help.indexOf('·');
      help = cut < 0 ? '' : help.substring(cut + 1).trimLeft();
      helpW = term.displayWidth(help);
    }
    if (leftW <= _w) {
      _writeRaw(y, 0, _w, left, leftStyle);
      if (helpW > 0) _writeRaw(y, _w - helpW, _w, help, 0);
    } else {
      _writeRaw(y, 0, _w, term.truncateWidth(left, _w), leftStyle);
    }
  }

  /// The running Console bars for the status row: a spinner until one
  /// counts, then `label ━━━╸── counts  rate`.
  String _consoleStatus() {
    final frames = fmt.spinFrames(ascii: _caps.ascii);
    final parts = <String>[];
    for (final entry in _cBars.values) {
      final bar = entry.state();
      final lab = bar.label == null ? '' : '${bar.label} ';
      if (bar.spinning) {
        parts.add('${frames[_spinTick % frames.length]} ${bar.label ?? ''}'.trimRight());
        continue;
      }
      final total = bar.total;
      final glyphs = total == null || total <= 0 ? '' : '${fmt.barGlyphs(bar.done, total, 10, ascii: _caps.ascii)} ';
      parts.add('$lab$glyphs${fmt.fmtCounts(bar.done, total, bar.unit)}  ${fmt.fmtPace(bar.rate, bar.unit)}');
    }
    return parts.join(' · ');
  }

  void _writeRaw(int row, int from, int end, String text, int style) {
    if (row < 0 || row >= _grid.length) return;
    end = math.min(end, _w);
    var col = from;
    // One grapheme cluster per cell, as in Region.write: combining marks
    // (Vietnamese tones) stay on their letter.
    final runes = [
      for (final r in text.runes)
        if (!_isControl(r)) r,
    ];
    for (var i = 0; i < runes.length && col < end;) {
      final (w, next) = term.cluster(runes, i);
      final ch = String.fromCharCodes(runes, i, next);
      i = next;
      if (w == 0) continue;
      if (col + w > end) break;
      _grid[row][col] = _Cell(ch, style, w);
      if (w == 2) _grid[row][col + 1] = _Cell('', style, 0);
      col += w;
    }
  }

  void _compositeScrolls() {
    for (final ctx in _scrolls) {
      final contentH = math.max(ctx.buf.length, 1);
      final st = ctx.scroll;
      if (st._follow && st._pinned) {
        st._off = math.max(0, contentH - ctx.viewH);
      }
      st._off = st._off.clamp(0, math.max<int>(0, contentH - ctx.viewH));
      for (var r = 0; r < ctx.viewH; r++) {
        final src = st._off + r;
        final dst = ctx.gy + r;
        if (dst < 0 || dst >= _grid.length) continue;
        if (src < ctx.buf.length) {
          final row = ctx.buf[src];
          for (var c = 0; c < ctx.w && c < row.length; c++) {
            if (ctx.gx + c < _grid[dst].length) {
              _grid[dst][ctx.gx + c] = row[c];
            }
          }
        }
      }
      if (contentH > ctx.viewH && ctx.w > 0) {
        // Thumb: as tall as the visible share, at the top at offset 0 and
        // on the last row at the end.
        final size = math.max(1, ctx.viewH * ctx.viewH ~/ contentH);
        final maxOff = contentH - ctx.viewH;
        final top = ((ctx.viewH - size) * st._off / maxOff).round();
        for (var r = 0; r < ctx.viewH; r++) {
          final dst = ctx.gy + r;
          if (dst < 0 || dst >= _grid.length) continue;
          final ch = (r >= top && r < top + size) ? (_caps.ascii ? '#' : '█') : (_caps.ascii ? '|' : '│');
          final dx = ctx.gx + ctx.w - 1;
          if (dx >= 0 && dx < _grid[dst].length) {
            _grid[dst][dx] = _Cell(ch, 0, 1);
          }
        }
      }
    }
  }

  void _compositePopups() {
    for (final p in _popups) {
      for (var r = 0; r < p.h; r++) {
        final dst = p.y + r;
        if (dst < 0 || dst >= _grid.length) continue;
        for (var c = 0; c < p.w; c++) {
          final dx = p.x + c;
          if (dx < 0 || dx >= _grid[dst].length) continue;
          _grid[dst][dx] = p.buf[r][c];
        }
      }
    }
  }

  // --- terminal life -----------------------------------------------------
  //
  // Signals go through `src/exit.dart`, the only `ProcessSignal` subscriber
  // in the package: terminal restore is an [exit.onExit] hook, resizes an
  // [exit.onResize] callback, and raw-mode Ctrl-C is a key through
  // [exit.claimInterrupt] (see [_watchSignals]). Nothing here watches a
  // signal or calls `exit` directly: on SIGTERM/SIGHUP the restore hook runs
  // first, then the browsers' hooks, then `exit.dart` exits (143/129).

  Object? _exitToken;
  Object? _resizeToken;

  Future<void> _enter() async {
    try {
      final (w, h) = size();
      _w = math.max(1, w);
      _h = math.max(1, h);
    } catch (_) {}
    _grid = List.generate(_h, (_) => List.filled(_w, _Cell.blank));
    // Keys come from the terminal even when stdin is a pipe (`ls | app`).
    term.ttyInput = true;
    _modes = term.captureModes();
    await _startGuard();
    term.setRawModes(_modes, false);
    _listenStdin();
    _watchSignals();
    out(_enterCodes);
    _repaint = true;
    _dirty = true;
    _entered = true;
    term.TuiBridge.current = this;
  }

  /// Wire process signals through `src/exit.dart` instead of watching them
  /// here.
  void _watchSignals() {
    _exitToken = exit.onExit(() {
      _restoreTerminal();
    }, busy: false);
    _resizeToken = exit.onResize(() {
      term.TerminalCaps.invalidate();
      _repaint = true;
      _dirtyAndWake();
    });
    // POSIX clears ISIG, so Ctrl-C is the byte 0x03; Windows still raises
    // SIGINT, which `exit.dart` hands to this claim instead of exiting (an
    // external `kill -INT` lands here too). After [_leave] SIGINT terminates.
    exit.claimInterrupt(() {
      if (_done) return false;
      _signals.add('ctrl+c');
      _wake();
      return true;
    });
  }

  void _unwatchSignals() {
    final exitToken = _exitToken;
    _exitToken = null;
    if (exitToken != null) exit.offExit(exitToken);
    final resizeToken = _resizeToken;
    _resizeToken = null;
    if (resizeToken != null) exit.offResize(resizeToken);
    exit.claimInterrupt(null);
  }

  io.Process? _guard;
  var _suspending = false;

  /// A watchdog shell that puts the terminal back if this process dies
  /// without leaving (`exit()` in a handler, a VM crash), when no Dart code
  /// runs to do it: it saves the `stty` state before raw mode, then waits
  /// for its stdin to close and, unless `done` came first, restores the
  /// modes and writes the leave codes. POSIX with a terminal only.
  Future<void> _startGuard() async {
    if (io.Platform.isWindows || !io.stdout.hasTerminal) return;
    try {
      final g = await io.Process.start('/bin/sh', ['-c', _guardScript, 'tui', _leaveCodes]);
      unawaited(g.stderr.drain<void>());
      await g.stdout.first.timeout(const Duration(seconds: 2)); // the state is saved
      _guard = g;
    } catch (_) {}
  }

  static const _guardScript =
      'trap "" INT; s=\$(stty -g </dev/tty) || exit 0; echo; l=; while IFS= read -r x; do l=\$x; done; '
      '[ "\$l" = done ] || { stty "\$s" </dev/tty; printf %s "\$1" >/dev/tty; }';

  void _stopGuard() {
    final g = _guard;
    _guard = null;
    if (g == null) return;
    try {
      g.stdin.writeln('done');
      unawaited(g.stdin.close().catchError((_) {}));
    } catch (_) {}
  }

  static const _enterCodes =
      '\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h\x1b[>1u';
  static const _leaveCodes =
      '\x1b[<u\x1b[0m\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?7h\x1b[?25h\x1b[?1049l';

  void _listenStdin() => _subs.add(
    term.sharedStdin().listen(
      (b) {
        _pending.addAll(b);
        _wake();
      },
      onError: (Object e) => _inputLost('$e'),
      onDone: () => _inputLost('closed'),
    ),
  );

  /// The terminal reader ended (not a suspend, which cancels it first):
  /// with no keys and no Ctrl-C (ISIG is off) the app could never quit.
  void _inputLost(String why) {
    if (_done || _fatal != null) return;
    _fatal = io.StdinException('the TUI lost its terminal input ($why): no keys, no Ctrl-C');
    _wake();
  }

  /// Ctrl-Z (POSIX): give the terminal back, stop this process, and take the
  /// terminal again when the shell continues it.
  Future<void> _suspend() async {
    if (_suspending) return;
    _suspending = true;
    final modes = _modes;
    out(_leaveCodes);
    if (modes != null) term.restoreModes(modes);
    // The tty reader must be gone before the stop: a `cat` still reading
    // the terminal would eat the shell's keystrokes (and EINTR kills it).
    final subs = [..._subs];
    _subs.clear();
    for (final sub in subs) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    await term.inputStopped();
    _suspending = false;
    if (_done) return; // quit while the reader stopped
    try {
      await io.stdout.flush();
    } catch (_) {}
    io.Process.killPid(io.pid, io.ProcessSignal.sigstop);
    term.setRawModes(modes, false);
    _listenStdin();
    out(_enterCodes);
    _repaint = true;
    _dirtyAndWake();
  }

  /// Write the leave codes and restore terminal modes. Idempotent: both the
  /// exit hook and the normal [_leave] path call it.
  void _restoreTerminal() {
    if (!_entered) return;
    _entered = false;
    _done = true;
    try {
      out(_leaveCodes);
      final modes = _modes;
      if (modes != null) term.restoreModes(modes);
    } catch (_) {}
    _stopGuard();
    if (identical(term.TuiBridge.current, this)) {
      term.TuiBridge.current = null;
    }
  }

  Future<void> _leave() async {
    _done = true;
    _unwatchSignals();
    _cancelPrompts();
    if (!_entered) return;
    _wake();
    await Future.wait(
      _subs.map((sub) async {
        try {
          await sub.cancel();
        } catch (_) {}
      }),
    );
    _subs.clear();
    _restoreTerminal();
    term.ttyInput = false;
    try {
      await io.stdout.flush();
    } catch (_) {}
    for (final (e, st) in _errorLog) {
      try {
        io.stderr.writeln('tui: a handler failed: $e\n$st');
      } catch (_) {}
    }
    _errorLog.clear();
  }
}

/// An error that reached the isolate uncaught during [Tui.run], as the VM
/// reports it: its text.
final class _Uncaught extends Error {
  _Uncaught(this._text);

  final String _text;

  @override
  String toString() => _text;
}

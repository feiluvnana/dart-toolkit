// Session: loop, zone, routing, App/Screen/Tui.
part of '../tui.dart';
/// An event binding: a shown label plus the action it runs.
/// Binding names list alternatives separated by spaces (`'b escape'`).
/// An empty label hides the binding from the key help.
typedef Binding = (String label, FutureOr<void> Function() action);

/// Mouse event names usable in [Binding] maps.
const _mouseNames = {
  'click',
  'doubleclick',
  'rightclick',
  'middleclick',
  'wheelup',
  'wheeldown',
};

/// Lifecycle event names usable in [Binding] maps.
const _lifecycleNames = {'show', 'resize', 'focus', 'blur'};

/// The height of an inline (or print) region: as tall as its content.
const _unbounded = 1 << 20;

bool _isMouse(String name) => _mouseNames.contains(name);
bool _isLifecycle(String name) => _lifecycleNames.contains(name);

bool _sameId(Object? a, Object? b) =>
    identical(a, b) || (a is String && b is String && a == b);
/// The app handle handed to `screen` and bindings.
final class App<S> {
  App._(this._s);

  final _Session<S> _s;

  /// The current state object.
  S state() => _s._state;

  /// Switch state; the next redraw calls `screen` with it.
  void goTo(S state) => _s._go(state);

  /// A status-row message until the next [showStatus] or error.
  void showStatus(String message) => _s._say(message);

  /// Commit a drawing above the live area into the scrollback (inline mode).
  /// In full screen this throws [StateError].
  void printAbove(void Function(Region r) draw) => _s._print(draw);

  /// A desktop notification (OSC 9/777, bell fallback). Silent while the
  /// terminal reports focus; always sent when it never reports focus.
  void notify(String message) => _s._notify(message);

  /// Copy text to the clipboard (OSC 52).
  void copyToClipboard(String text) => _s._copy(text);

  /// Return the state from [Tui.run] (pending handlers keep running).
  void quit() => _s._quit();
}

/// One screen description: a draw function plus title, status mode line and
/// key bindings.
final class Screen {
  // ignore: prefer_initializing_formals – the public arguments keep their names.
  Screen(void Function(Region r) draw,
      {String? title, String? status, Map<String, Binding> keys = const {}})
      : _draw = draw,
        // ignore: prefer_initializing_formals
        _title = title,
        // ignore: prefer_initializing_formals
        _status = status,
        // ignore: prefer_initializing_formals
        _keys = keys;

  final void Function(Region r) _draw;
  final String? _title;
  final String? _status;
  final Map<String, Binding> _keys;
}

/// Entry point: run a state-driven app.
abstract final class Tui {
  static bool _active = false;

  /// Own the loop: redraw on every input event, handler settle, `goTo` /
  /// `showStatus`, resize, and at most every 80 ms while work is pending or
  /// a spinner is
  /// visible. Returns the state passed to [App.quit]. A second [run] while
  /// one is active throws [StateError]. Throws [StdoutException] when stdout
  /// is not a terminal.
  static Future<S> run<S>(S state,
      Screen Function(S state, App<S> app) screen,
      {bool fullscreen = true, Color accent = Color.orange}) {
    if (_active) throw StateError('Tui.run is already active');
    _active = true;
    final session = _Session<S>(state, screen,
        out: io.stdout.write,
        size: () => (io.stdout.terminalColumns, io.stdout.terminalLines),
        accent: accent,
        fullscreen: fullscreen);
    return session._run().whenComplete(() => _active = false);
  }
}
/// One focusable thing drawn this frame.
final class _F {
  _F(this.id, this.x, this.y, this.w, this.h, this.order, this.tryKey,
      {this.onMap, this.fixed = false});

  /// Inside a popup: screen coordinates, never shifted by inline layout.
  final bool fixed;

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

/// Open suggest-completion state for one [TextField].
final class _Suggest {
  _Suggest(this.field);

  final TextField field;
  String word = '';
  int wordStart = 0;
  List<String> matches = const [];
  var index = 0;
  var gen = 0;
  var open = false;
}

/// A Console prompt shown as a modal popup (ask/confirm/choose).
final class _Prompt {
  _Prompt.ask(this.question, this.secret)
      : kind = 0,
        choices = const [],
        completer = Completer<String>();

  _Prompt.confirm(this.question)
      : kind = 1,
        secret = false,
        choices = const [],
        completer = Completer<bool>();

  _Prompt.choose(this.question, this.choices)
      : kind = 2,
        secret = false,
        completer = Completer<String>();

  final int kind; // 0 ask, 1 confirm, 2 choose
  final String question;
  final bool secret;
  final List<String> choices;
  final TextField field = TextField();
  final Selection<int> pick = Selection<int>();
  String? error;
  int start = 0, shown = 0, top = 0; // choose: first visible choice, rows shown, screen row of the first
  final Completer<Object> completer; // String (ask/choose) or bool (confirm)
}

/// A Console progress bar mirrored into the status row.
final class _CBridge {
  _CBridge(this.total, this.label) : start = DateTime.now();

  final int? total;
  final String? label;
  var done = 0;
  var bytes = false;
  final DateTime start;
}

bool _isWordSuggestChar(int r) =>
    (r >= 0x30 && r <= 0x39) ||
    (r >= 0x41 && r <= 0x5A) ||
    r == 0x5F ||
    (r >= 0x61 && r <= 0x7A) ||
    r == 0x40 ||
    r == 0x2F ||
    r == 0x3A ||
    r == 0x2E ||
    r == 0x2B ||
    r == 0x2D;
final class _Session<S> implements term.TuiBridge {
  _Session(this._state, this._screenFn,
      {required this.out,
      required this.size,
      required this.accent,
      required this.fullscreen});

  S _state;
  final Screen Function(S state, App<S> app) _screenFn;
  final void Function(String) out;
  final (int, int) Function() size;
  final Color accent;
  final bool fullscreen;
  late final App<S> app = App<S>._(this);

  var _w = 80;
  var _h = 24;
  List<List<_Cell>> _grid = const [];
  List<List<_Cell>>? _shown;
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
  Map<String, Binding> _keys = const {};
  String? _title;
  Object? _shownState;

  final _popups = <_Popup>[];
  final _scrolls = <_ScrollCtx>[];
  final _drawnFields = <TextField>{};
  final _clickBase = Expando<int>();
  final _suggests = <TextField, _Suggest>{};
  _Suggest? _activeSg;
  final _prompts = <_Prompt>[];
  final _cSpinners = <Object, String>{};
  final _cBars = <Object, _CBridge>{};
  var _termFocused = true;
  var _focusReported = false; // set by the first focus event
  var _usedRows = 0;
  var _statusY = 23;

  // Open-layout measuring (see [_measured]).
  List<int>? _mSlots;
  var _mNext = 0;
  final _mPending = <void Function()>[];
  final _mBuild = <int, int>{};
  var _refocused = false;
  var _liveH = 0;
  int _curR = -1;
  var _spinVisible = false;
  var _spinTick = 0;
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
        createTimer: (self, parent, zone, duration, f) =>
            parent.createTimer(zone, duration, () {
              try {
                f();
              } finally {
                _dirtyAndWake();
              }
            }),
        createPeriodicTimer: (self, parent, zone, period, f) =>
            parent.createPeriodicTimer(zone, period, (timer) {
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
          // Escape in a Console prompt ends the handler silently.
          if (e is io.StdinException) {
            _dirtyAndWake();
            return;
          }
          if (e is Exception) {
            _failStatus(e);
          } else {
            _fatal ??= e;
            _fatalStack ??= st;
          }
          _dirtyAndWake();
        },
      );

  Future<T> _zoneRun<T>(Future<T> Function() fn) {
    final z = _zone;
    if (z == null) return fn();
    return z.run(fn);
  }

  Future<void> _settleForTest() async {
    for (var k = 0; k < 200; k++) {
      await Future<void>.delayed(Duration.zero);
      if (_activeH == 0) {
        await Future<void>.delayed(Duration.zero);
        if (_activeH == 0) return;
      }
    }
  }

  // --- run loop ----------------------------------------------------------

  Future<S> _run() async {
    if (!io.stdout.hasTerminal) {
      throw const io.StdoutException('no terminal for the TUI');
    }
    // Handlers run in the redraw zone; the loop itself stays outside it, or
    // its own timers and awaits would wake it forever and starve I/O.
    runZoned(() => _zone = Zone.current, zoneSpecification: _spec());
    await _enter();
    try {
      await _loop();
      return _state;
    } finally {
      await _leave();
    }
  }

  Future<void> _loop() async {
    _draw();
    _paintNow();
    while (!_quitFlag) {
      if (_fatal != null) {
        final e = _fatal!;
        final st = _fatalStack ?? StackTrace.empty;
        _fatal = null;
        Error.throwWithStackTrace(e, st);
      }
      final active = _activeH > 0 ||
          _spinVisible ||
          _cSpinners.isNotEmpty ||
          _cBars.isNotEmpty;
      _waker ??= Completer<void>();
      final w = _waker!;
      // Wake on an event, or: when a redraw waits out the 60 fps gap, when
      // a held ESC or split sequence needs another look, or for the next
      // spinner frame.
      final wait = _dirty
          ? math.max(0, 16 - (_now() - _lastPaint))
          : _pending.isNotEmpty
              ? 30
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
            _spinTick++;
            _dirty = true;
          }
        }
      }
      if (identical(_waker, w)) _waker = null;
      _pollInput();
      if (_dirty && _now() - _lastPaint >= 16) {
        _dirty = false;
        _draw();
        _paintNow();
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
          _paintNow();
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

  void _failStatus(Exception e) {
    var first = _firstLine('$e');
    // `Exception('msg')` stringifies as `Exception: msg`; the status shows
    // the message's first line.
    const prefix = 'Exception: ';
    if (first.startsWith(prefix)) first = first.substring(prefix.length);
    _error = '✗ $first';
    _sayMsg = null;
    _dirtyAndWake();
  }

  static String _firstLine(String s) {
    final i = s.indexOf('\n');
    return (i < 0 ? s : s.substring(0, i)).trim();
  }

  // --- state ops ---------------------------------------------------------

  void _go(S state) {
    _state = state;
    _sayMsg = null;
    _dirtyAndWake();
  }

  void _say(String message) {
    _sayMsg = message;
    _error = null;
    _dirtyAndWake();
  }

  void _print(void Function(Region r) draw) {
    if (fullscreen) throw StateError('printAbove needs inline mode');
    _printInline(draw);
  }

  /// Render [draw] at full width and commit it above the live area.
  void _printInline(void Function(Region r) draw) {
    if (_curR >= 0) {
      out('\r\x1b[${_liveH - _curR}B');
      _curR = -1;
    }
    final buf = <List<_Cell>>[List.filled(_w, _Cell.blank)];
    final nf = _focusables.length,
        np = _popups.length,
        ns = _scrolls.length,
        no = _order;
    void restore() {
      _focusables.length = nf;
      _popups.length = np;
      _scrolls.length = ns;
      _order = no;
    }

    _measured(() {
      draw(Region._(this, buf, 0, 0, _w, _unbounded, grow: true, open: true));
    }, () {
      restore();
      buf
        ..clear()
        ..add(List.filled(_w, _Cell.blank));
    });
    restore();
    var n = buf.length;
    while (n > 0 && buf[n - 1].every((c) => c == _Cell.blank)) {
      n--;
    }
    final sb = StringBuffer();
    if (_liveH > 0) sb.write('\r\x1b[${_liveH}A\x1b[J');
    for (var r = 0; r < n; r++) {
      sb.write('\r\x1b[2K');
      sb.write(_renderRow(buf[r]));
      sb.write('\n');
    }
    out(sb.toString());
    _liveH = 0;
    _dirtyAndWake();
  }
  void _notify(String message) {
    // Silent only while the terminal reports that it has focus.
    if (_focusReported && _termFocused) return;
    String esc(String s) => s.replaceAll('\x1b', '').replaceAll('\x07', '');
    out('\x1b]9;${esc(message)}\x07');
    out('\x1b]777;notify;${esc(message)}\x07');
    out('\x07');
  }

  void _copy(String text) {
    final b64 = base64.encode(utf8.encode(text));
    out('\x1b]52;c;$b64\x1b\\');
  }

  void _quit() {
    _quitFlag = true;
    _wake();
  }

  // --- term.TuiBridge (Console-in-Tui routing) -----------------------------

  @override
  Object spinStarted(String label) {
    final id = Object();
    _cSpinners[id] = label;
    // New work replaces a stale message, so its progress shows.
    _sayMsg = _error = null;
    _dirtyAndWake();
    return id;
  }

  @override
  void spinEnded(Object id, bool ok) {
    final label = _cSpinners.remove(id);
    if (!ok && label != null) _error = '✗ $label'.trimRight();
    _dirtyAndWake();
  }

  @override
  Object barStarted(int? total, String? label) {
    final id = Object();
    _cBars[id] = _CBridge(total, label);
    _sayMsg = _error = null;
    _dirtyAndWake();
    return id;
  }

  @override
  void barMode(Object id, bool bytes) {
    final bar = _cBars[id];
    if (bar != null) bar.bytes = bytes;
  }

  @override
  void barTick(Object id, int count) {
    final bar = _cBars[id];
    if (bar == null) return;
    bar.done += count;
    final total = bar.total;
    if (total != null && total > 0 && bar.done > total) bar.done = total;
    _dirtyAndWake();
  }

  @override
  void barEnded(Object id, bool ok) {
    final bar = _cBars.remove(id);
    if (!ok && bar != null) _error = '✗ ${bar.label ?? ''}'.trimRight();
    _dirtyAndWake();
  }

  @override
  Future<String> promptAsk(String question, {required bool secret}) {
    final p = _Prompt.ask(question, secret);
    _prompts.add(p);
    _dirtyAndWake();
    return p.completer.future.then((v) => v as String);
  }

  @override
  Future<bool> promptConfirm(String question) {
    final p = _Prompt.confirm(question);
    _prompts.add(p);
    _dirtyAndWake();
    return p.completer.future.then((v) => v as bool);
  }

  @override
  Future<String> promptChoose(String question, List<String> choices) {
    if (choices.isEmpty) {
      throw ArgumentError.value(choices, 'choices', 'must not be empty');
    }
    final p = _Prompt.choose(question, choices);
    p.pick.setItems(List<int>.generate(choices.length, (k) => k));
    _prompts.add(p);
    _dirtyAndWake();
    return p.completer.future.then((v) => v as String);
  }

  /// One identity per key set, so a `Region.bind` region is the same
  /// focusable on every frame.
  final _bindIds = <String, Object>{};
  Object _bindId(Map<String, Binding> events) =>
      _bindIds.putIfAbsent(events.keys.join('\x00'), Object.new);

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

  bool _focusIn(int x, int y, int w, int h) {
    final id = _focusId;
    if (id == null) return false;
    for (final f in _focusables) {
      if (_sameId(f.id, id) &&
          f.x < x + w &&
          f.x + f.w > x &&
          f.y < y + h &&
          f.y + f.h > y) {
        return true;
      }
    }
    return false;
  }

  void _addFocusable(Object id, int x, int y, int w, int h, int order,
      bool Function(_Ev ev)? tryKey,
      {Map<String, Binding>? onMap, bool fixed = false}) {
    _focusables.add(
        _F(id, x, y, w, h, order, tryKey, onMap: onMap, fixed: fixed));
  }

  int _listStart(Object id, int n, int h) =>
      _listStarts[id]?.clamp(0, math.max<int>(0, n - h)) ?? 0;

  void _listStartSave(Object id, int start) => _listStarts[id] = start;

  final _styleCache = <(Color?, Color?, int), int>{};
  final _styles = <(Color?, Color?, int)>[];
  /// Last-layout memos, one per markdown call site (see [_mdLayout]):
  /// an `identical` source is an O(1) hit, a streamed append re-lays only
  /// from the last block boundary.
  final _mdMemos = <_MdMemo>[];

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
    final waited = now - _heldSince!;
    final maybeCsi = _pending.length >= 2 &&
        _pending[0] == 0x1b &&
        (_pending[1] == 0x5b || _pending[1] == 0x4f);
    if (maybeCsi) {
      if (waited < 1000) return;
      _pending.clear();
      _heldSince = null;
      return;
    }
    if (_pending.length <= 2 && waited >= 30) {
      if (_pending.length == 1 || _pending[1] == 0x1b) {
        _routeKey('escape');
      } else if (_pending[1] < 0x80) {
        _routeKey('alt+${String.fromCharCode(_pending[1])}');
      }
      _pending.clear();
      _heldSince = null;
      return;
    }
    if (waited < 1000) return;
    _pending.clear();
    _heldSince = null;
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
          _dirtyAndWake();
        case term.TermFocus(:final gained):
          _termFocused = gained;
          _focusReported = true;
          _fireLifecycle(gained ? 'focus' : 'blur');
          _dirtyAndWake();
      }
    }
  }

  void _clickAt(String kind, int x, int y) {
    if (kind == 'click') {
      final now = _now();
      final last = _lastClick;
      if (last != null &&
          last.$1 == x &&
          last.$2 == y &&
          now - _lastClickAt < 400) {
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
      if (fid != null && fid is! TextField && fid is! String) {
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
      final b = fid is TextField ? null : _lookup(_keys, nm);
      if (b != null) {
        _invoke(b.$2);
        return;
      }
    }
    _F? target;
    for (final f in _focusables) {
      if (f.id is TextField && f.tryKey != null && _sameId(f.id, _focusId)) {
        target = f;
        break;
      }
    }
    target ??= _focusables
        .where((f) => f.id is TextField && f.tryKey != null)
        .firstOrNull;
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
      _suspend();
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
      final mouseable = (kind == 'click' && f.tryKey != null) ||
          (f.onMap != null && _lookup(f.onMap!, kind) != null);
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
      if (p.kind == 2) {
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

  /// Refresh the suggest popup for [field] from the word at its cursor.
  void _refreshSuggest(
      TextField field, FutureOr<List<String>> Function(String word)? fn) {
    if (fn == null) return;
    final sg = _suggests.putIfAbsent(field, () => _Suggest(field));
    final runes = field._text.runes.toList();
    final at = field._cursor.clamp(0, runes.length);
    var start = at;
    while (start > 0 && _isWordSuggestChar(runes[start - 1])) {
      start = _prevCluster(runes, start);
    }
    var end = at;
    while (end < runes.length && _isWordSuggestChar(runes[end])) {
      end = _nextCluster(runes, end);
    }
    final word = String.fromCharCodes(runes.sublist(start, end));
    if (word.isEmpty) {
      sg.open = false;
      if (identical(_activeSg, sg)) _activeSg = null;
      _dirtyAndWake();
      return;
    }
    // Same word: nothing new to ask (and an escaped popup stays closed).
    if (word == sg.word && start == sg.wordStart) return;
    sg.word = word;
    sg.wordStart = start;
    final gen = ++sg.gen;
    FutureOr<List<String>> result;
    try {
      result = fn(word);
    } catch (_) {
      if (sg.gen == gen) sg.open = false;
      if (identical(_activeSg, sg) && !sg.open) _activeSg = null;
      _dirtyAndWake();
      return;
    }
    if (result is Future<List<String>>) {
      result.then((matches) {
        if (sg.gen != gen) return; // stale async answer: drop
        sg.matches = matches.length > 10 ? matches.sublist(0, 10) : matches;
        sg.index = 0;
        sg.open = sg.matches.isNotEmpty;
        if (!sg.open && identical(_activeSg, sg)) _activeSg = null;
        _dirtyAndWake();
      }, onError: (_) {
        if (sg.gen == gen) {
          sg.open = false;
          if (identical(_activeSg, sg)) _activeSg = null;
          _dirtyAndWake();
        }
      });
    } else {
      sg.matches = result.length > 10 ? result.sublist(0, 10) : result;
      sg.index = 0;
      sg.open = sg.matches.isNotEmpty;
      if (!sg.open && identical(_activeSg, sg)) _activeSg = null;
      _dirtyAndWake();
    }
  }

  void _acceptSuggest(_Suggest sg) {
    if (sg.matches.isEmpty) {
      sg.open = false;
      if (identical(_activeSg, sg)) _activeSg = null;
      _dirtyAndWake();
      return;
    }
    final field = sg.field;
    final runes = field._text.runes.toList();
    // Replace [wordStart, cursor) with the match.
    final at = field._cursor.clamp(0, runes.length);
    runes.removeRange(sg.wordStart.clamp(0, at), at);
    final match = sg.matches[sg.index.clamp(0, sg.matches.length - 1)];
    runes.insertAll(sg.wordStart.clamp(0, runes.length), match.runes);
    field._text = String.fromCharCodes(runes);
    field._cursor = sg.wordStart + match.runes.length;
    field._wantCol = -1;
    sg.word = match;
    sg.open = false;
    if (identical(_activeSg, sg)) _activeSg = null;
    _dirtyAndWake();
  }

  /// Route a key to the open suggest popup, if any drawn field has one.
  /// Returns true when consumed.
  bool _routeSuggest(String name) {
    final sg = _activeSg;
    if (sg == null || !sg.open || sg.matches.isEmpty) return false;
    switch (name) {
      case 'up':
        sg.index =
            (sg.index - 1 + sg.matches.length) % sg.matches.length;
        _dirtyAndWake();
        return true;
      case 'down':
        sg.index = (sg.index + 1) % sg.matches.length;
        _dirtyAndWake();
        return true;
      case 'tab':
      case 'enter':
        _acceptSuggest(sg);
        return true;
      case 'escape':
        sg.open = false;
        _activeSg = null;
        _dirtyAndWake();
        return true;
    }
    return false;
  }

  /// Draw the suggest popup for [field] near its cursor (buffer coords
  /// [cpos] in [region]), if its matches are open.
  void _drawSuggestPopup(
      TextField field, Region region, (int, int)? cpos) {
    final sg = _suggests[field];
    if (sg == null || !sg.open || sg.matches.isEmpty || cpos == null) {
      if (sg != null && identical(_activeSg, sg)) _activeSg = null;
      return;
    }
    final sp = region._toScreen(cpos.$1, cpos.$2);
    if (sp == null) {
      if (identical(_activeSg, sg)) _activeSg = null;
      return;
    }
    _activeSg = sg;
    var mw = 0;
    for (final m in sg.matches) {
      mw = math.max(mw, term.displayWidth(m));
    }
    final w = (mw + 4).clamp(8, math.min<int>(40, _w));
    final h = math.min<int>(sg.matches.length + 2, math.max<int>(3, _h));
    var y = sp.$2 + 1;
    if (fullscreen) {
      // Inline positions are buffer rows; the live area grows to hold the list.
      if (y + h > _h) y = sp.$2 - h;
      y = y.clamp(0, math.max<int>(0, _h - h));
    }
    var x = sp.$1.clamp(0, math.max<int>(0, _w - w));
    final buf = <List<_Cell>>[
      for (var k = 0; k < h; k++) List.filled(w, _Cell.blank)
    ];
    final ascii = _caps.ascii;
    final (hz, vt, tl, tr, bl, br) = ascii
        ? ('-', '|', '+', '+', '+', '+')
        : ('─', '│', '┌', '┐', '└', '┘');
    void raw(int r, int c, String ch) {
      if (r >= 0 && r < h && c >= 0 && c < w) buf[r][c] = _Cell(ch, 0, 1);
    }

    for (var cx = 0; cx < w; cx++) {
      raw(0, cx, hz);
      raw(h - 1, cx, hz);
    }
    for (var ry = 0; ry < h; ry++) {
      raw(ry, 0, vt);
      raw(ry, w - 1, vt);
    }
    raw(0, 0, tl);
    raw(0, w - 1, tr);
    raw(h - 1, 0, bl);
    raw(h - 1, w - 1, br);
    final rows = h - 2;
    var start = sg.index - rows + 1;
    if (start < 0) start = 0;
    for (var r = 0; r < rows && start + r < sg.matches.length; r++) {
      final idx = start + r;
      final sel = idx == sg.index;
      final st = _pack(null, sel ? accent : null, sel ? {Style.bold} : {});
      final label = term.truncateWidth(sg.matches[idx], math.max(1, w - 4));
      var col = 2;
      if (sel) {
        for (var c = 1; c < w - 1; c++) {
          buf[r + 1][c] = _Cell(' ', st, 1);
        }
      }
      for (final rune in label.runes) {
        if (col >= w - 1) break;
        if (rune < 0x20 || rune == 0x7f) continue;
        final cw = term.isZeroWidth(rune) ? 0 : term.cellWidth(rune);
        if (cw == 0 || col + cw > w - 1) continue;
        buf[r + 1][col] = _Cell(String.fromCharCode(rune), st, cw);
        if (cw == 2 && col + 1 < w - 1) {
          buf[r + 1][col + 1] = _Cell('', st, 0);
        }
        col += cw;
      }
    }
    _popups.add(_Popup(x, y, w, h, buf, anchored: true));
  }

  /// Route a key to the topmost Console prompt. Returns true when consumed
  /// (prompts are modal: everything is consumed while one is open).
  bool _promptKey(_Prompt p, String name) {
    if (p.kind == 2) {
      final n = p.choices.length;
      switch (name) {
        case 'up':
        case 'wheelup':
          if (n > 0) {
            p.pick.select(p.pick.index() - 1);
            _dirtyAndWake();
          }
          return true;
        case 'down':
        case 'wheeldown':
          if (n > 0) {
            p.pick.select(p.pick.index() + 1);
            _dirtyAndWake();
          }
          return true;
        case 'home':
          p.pick.select(0);
          _dirtyAndWake();
          return true;
        case 'end':
          p.pick.select(n - 1);
          _dirtyAndWake();
          return true;
        case 'enter':
          _prompts.remove(p);
          if (!p.completer.isCompleted) {
            p.completer.complete(
                n == 0 ? '' : p.choices[p.pick.index().clamp(0, n - 1)]);
          }
          _dirtyAndWake();
          return true;
        case 'escape':
        case 'ctrl+c':
          _prompts.remove(p);
          if (!p.completer.isCompleted) {
            p.completer.completeError(
                const io.StdinException('stdin is closed'));
          }
          _dirtyAndWake();
          return true;
      }
      return true; // modal: swallow the rest
    }
    switch (name) {
      case 'backspace':
        _promptDrop(p, -1);
        return true;
      case 'delete':
        _promptDrop(p, 1);
        return true;
      case 'left':
        p.field._cursor = _prevCluster(
            p.field._text.runes.toList(), p.field._cursor);
        _dirtyAndWake();
        return true;
      case 'right':
        p.field._cursor = _nextCluster(
            p.field._text.runes.toList(), p.field._cursor);
        _dirtyAndWake();
        return true;
      case 'home':
      case 'ctrl+a':
        p.field._cursor = 0;
        _dirtyAndWake();
        return true;
      case 'end':
      case 'ctrl+e':
        p.field._cursor = p.field._text.runes.length;
        _dirtyAndWake();
        return true;
      case 'ctrl+u':
      case 'ctrl+k':
      case 'ctrl+w':
      case 'alt+backspace':
        p.field.setText('');
        _dirtyAndWake();
        return true;
      case 'enter':
        _submitPrompt(p);
        return true;
      case 'escape':
      case 'ctrl+c':
        _prompts.remove(p);
        if (!p.completer.isCompleted) {
          p.completer
              .completeError(const io.StdinException('stdin is closed'));
        }
        _dirtyAndWake();
        return true;
    }
    return true; // modal: swallow the rest
  }

  void _promptDrop(_Prompt p, int dir) {
    final runes = p.field._text.runes.toList();
    final at = p.field._cursor.clamp(0, runes.length);
    if (dir < 0) {
      final start = _prevCluster(runes, at);
      runes.removeRange(start, at);
      p.field._cursor = start;
    } else {
      final end = _nextCluster(runes, at);
      runes.removeRange(at, end);
    }
    p.field._text = String.fromCharCodes(runes);
    _dirtyAndWake();
  }

  void _promptText(_Prompt p, String text, bool paste) {
    final clean = paste
        ? text
            .replaceAll('\r\n', ' ')
            .replaceAll(RegExp('[\r\n\t]'), ' ')
            .replaceAll(RegExp('[\x00-\x1f\x7f]'), '')
        : text;
    final runes = p.field._text.runes.toList();
    final at = p.field._cursor.clamp(0, runes.length);
    runes.insertAll(at, clean.runes);
    p.field._text = String.fromCharCodes(runes);
    p.field._cursor = at + clean.runes.length;
    _dirtyAndWake();
  }

  void _submitPrompt(_Prompt p) {
    if (p.kind == 1) {
      final answer = p.field.text().trim().toLowerCase();
      if (answer == 'y' || answer == 'yes') {
        _prompts.remove(p);
        if (!p.completer.isCompleted) p.completer.complete(true);
      } else if (answer == 'n' ||
          answer == 'no' ||
          answer.isEmpty) {
        _prompts.remove(p);
        if (!p.completer.isCompleted) p.completer.complete(false);
      } else {
        p.error = 'please answer y or n';
      }
      _dirtyAndWake();
      return;
    }
    final text = p.field.text();
    _prompts.remove(p);
    if (!p.completer.isCompleted) p.completer.complete(text);
    _dirtyAndWake();
  }

  /// Route typed text to the topmost prompt (ask/confirm only).
  void _promptRouteText(String text, bool paste) {
    if (_prompts.isEmpty) return;
    final p = _prompts.last;
    if (p.kind == 2) return; // choose ignores typing
    _promptText(p, text, paste);
  }

  /// Route a mouse event to the topmost prompt. Always consumes (modal).
  bool _promptMouse(String kind, int x, int y) {
    if (_prompts.isEmpty) return false;
    final p = _prompts.last;
    if (p.kind == 2 && (kind == 'click' || kind == 'doubleclick')) {
      // Click a row to select it.
      final row = y - p.top;
      if (row >= 0 && row < p.shown) {
        p.pick.select(p.start + row);
        if (kind == 'doubleclick') {
          _prompts.remove(p);
          if (!p.completer.isCompleted) {
            p.completer.complete(p.choices[p.pick.index()]);
          }
        }
        _dirtyAndWake();
      }
    }
    return true;
  }

  void _drawPrompt() {
    if (_prompts.isEmpty) return;
    final p = _prompts.last;
    final lines = <(String, int)>[]; // (text, style)
    void wrapped(String text, int style, {int indent = 0}) {
      final maxW = math.max(8, _w - 8);
      var rest = text;
      var first = true;
      while (rest.isNotEmpty) {
        final lead = first ? indent : indent + 2;
        var used = lead;
        var k = 0;
        for (final r in rest.runes) {
          final w = term.isZeroWidth(r) ? 0 : term.cellWidth(r);
          if (used + w > maxW) break;
          used += w;
          k++;
        }
        if (k == 0) break;
        final runes = rest.runes.toList();
        lines.add((
          '${first ? '' : '  '}${String.fromCharCodes(runes.sublist(0, k))}',
          style
        ));
        rest = String.fromCharCodes(runes.sublist(k)).trimLeft();
        first = false;
      }
    }

    int fieldRow = -1;
    if (p.kind == 2) {
      wrapped(p.question, _pack(null, null, {Style.bold}));
      lines.add(('', 0));
      // Window the choices to the popup height, keeping the selection in view.
      final head = lines.length;
      final n = p.choices.length;
      p.shown = math.min(n, math.max(1, math.max(5, _h - 2) - 4 - head));
      final sel = p.pick.index();
      if (sel < p.start) p.start = sel;
      if (sel >= p.start + p.shown) p.start = sel - p.shown + 1;
      p.start = p.start.clamp(0, n - p.shown);
      for (var k = p.start; k < p.start + p.shown; k++) {
        lines.add(('${k == sel ? '❯ ' : '  '}${p.choices[k]}', 0));
      }
      p.top = head; // made absolute once the popup is placed
    } else {
      final q = p.kind == 1 ? '${p.question} [y/n]' : p.question;
      wrapped(q, _pack(null, null, {Style.bold}));
      lines.add(('', 0));
      final shown =
          p.secret ? '•' * p.field._text.runes.length : p.field._text;
      fieldRow = lines.length;
      lines.add(('❯ $shown', 0));
      if (p.error != null) {
        lines.add(('  ${p.error}', _pack(Color.red, null, {})));
      }
    }
    final contentW = lines.fold<int>(0,
        (m, l) => math.max(m, term.displayWidth(l.$1)));
    final w = (contentW + 6).clamp(20, math.max<int>(20, _w - 2));
    final h = (lines.length + 4).clamp(5, math.max<int>(5, _h - 2));
    final x = ((_w - w) ~/ 2).clamp(0, math.max<int>(0, _w - w));
    final y = ((_h - h) ~/ 2).clamp(0, math.max<int>(0, _h - h));
    final buf = <List<_Cell>>[
      for (var k = 0; k < h; k++) List.filled(w, _Cell.blank)
    ];
    final ascii = _caps.ascii;
    final (hz, vt, tl, tr, bl, br) = ascii
        ? ('-', '|', '+', '+', '+', '+')
        : ('─', '│', '┌', '┐', '└', '┘');
    void raw(int r, int c, String ch) {
      if (r >= 0 && r < h && c >= 0 && c < w) buf[r][c] = _Cell(ch, 0, 1);
    }

    for (var cx = 0; cx < w; cx++) {
      raw(0, cx, hz);
      raw(h - 1, cx, hz);
    }
    for (var ry = 0; ry < h; ry++) {
      raw(ry, 0, vt);
      raw(ry, w - 1, vt);
    }
    raw(0, 0, tl);
    raw(0, w - 1, tr);
    raw(h - 1, 0, bl);
    raw(h - 1, w - 1, br);
    for (var r = 0; r < lines.length && r + 2 < h - 1; r++) {
      final (text, st) = lines[r];
      var col = 3;
      for (final rune in text.runes) {
        if (col >= w - 2) break;
        if (rune < 0x20 || rune == 0x7f) continue;
        final cw = term.isZeroWidth(rune) ? 0 : term.cellWidth(rune);
        if (cw == 0 || col + cw > w - 2) continue;
        buf[r + 2][col] =
            _Cell(String.fromCharCode(rune), st, cw);
        if (cw == 2 && col + 1 < w - 2) {
          buf[r + 2][col + 1] = _Cell('', st, 0);
        }
        col += cw;
      }
    }
    _popups.add(_Popup(x, y, w, h, buf));
    if (p.kind == 2) p.top += y + 2;
    if (p.kind != 2 && fieldRow >= 0) {
      // Hardware cursor at the end of the field text.
      final text = p.secret
          ? '•' * p.field._text.runes.length
          : p.field._text;
      var col = x + 3 + 2 + term.displayWidth(text);
      col = math.min(col, x + w - 2);
      _cursorPos = (y + 2 + fieldRow, col);
    }
  }

  void _invoke(FutureOr<void> Function() action) {
    _activeH++;
    _dirtyAndWake();
    try {
      final r = _zone != null ? _zone!.run(action) : action();
      if (r is Future) {
        r.then((_) {
          _activeH--;
          _dirtyAndWake();
        }, onError: (Object e, StackTrace st) {
          _activeH--;
          _handlerError(e, st);
          _dirtyAndWake();
        });
      } else {
        _activeH--;
      }
    } catch (e, st) {
      _activeH--;
      _handlerError(e, st);
    }
  }

  void _handlerError(Object e, StackTrace st) {
    // A handler that ends in StdinException (Escape in a Console prompt)
    // shows nothing.
    if (e is io.StdinException) {
      _dirtyAndWake();
      return;
    }
    if (e is Exception) {
      _failStatus(e);
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
    _usedRows = 0;
    _spinVisible = false;
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

  void _draw() {
    if (_styles.length > 4096) {
      // Packed ids die with the table; every cell is re-packed this frame.
      _styleCache.clear();
      _styles.clear();
      _repaint = true;
    }
    _resetFrame();
    if (!_testMode) {
      var hasTerminal = false;
      try {
        hasTerminal = io.stdout.hasTerminal;
      } catch (_) {}
      _caps = term.TerminalCaps.of(io.Platform.environment,
          hasTerminal: hasTerminal);
    }
    // Fresh working grid every draw; _shown keeps last-painted state so the
    // paint still writes only changed cells.
    if (_grid.length != _h ||
        _grid.isNotEmpty && _grid.first.length != _w) {
      _grid = List.generate(_h, (_) => List.filled(_w, _Cell.blank));
      _shown = null;
      _repaint = true;
    }
    final screen = _screenFn(_state, app);
    _keys = screen._keys;
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
    if (fullscreen) {
      _measured(() {
        screen._draw(Region._(this, _grid, 0, titleH, _w, bodyH));
        if (titleH == 1) {
          Region._(this, _grid, 0, 0, _w, 1)
              .write(' ${_title ?? ''} ', color: accent);
        }
      }, _resetFrame);
      _statusY = _h - 1;
      _drawStatus();
      _compositeScrolls();
    } else {
      _drawInlineBody(screen, titleH);
      _drawStatus();
    }
    _drawPrompt();
    _compositePopups();
    if (_focusables.isNotEmpty &&
        !_focusables.any((f) => _sameId(f.id, _focusId))) {
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
          _draw();
        } finally {
          _refocused = false;
        }
        return;
      }
    }
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

  /// Inline: lay the screen out on an unbounded buffer, then keep its
  /// bottom slice above the status row (the whole height while a popup or
  /// prompt is open).
  void _drawInlineBody(Screen screen, int titleH) {
    final live = _grid;
    var buf = <List<_Cell>>[];
    _measured(() {
      _grid = buf = [];
      screen._draw(Region._(this, buf, 0, titleH, _w, _unbounded,
          grow: true, open: true));
      if (titleH == 1) {
        Region._(this, buf, 0, 0, _w, 1, grow: true)
            .write(' ${_title ?? ''} ', color: accent);
      }
    }, () {
      _grid = live;
      _resetFrame();
    });
    for (final ctx in _scrolls) {
      while (buf.length < ctx.gy + ctx.viewH) {
        buf.add(List.filled(_w, _Cell.blank));
      }
    }
    _compositeScrolls();
    var n = buf.length;
    while (n > 0 && buf[n - 1].every((c) => c == _Cell.blank)) {
      n--;
    }
    // Anchored popups (suggest lists) sit below the content and must stay
    // visible with it, so they count toward the rows kept.
    final total = _popups.fold(n, (m, p) => p.anchored ? math.max(m, p.y + p.h) : m);
    final shown = math.min(total, math.max(0, _h - 1));
    final drop = total - shown;
    for (var r = 0; r < shown && drop + r < buf.length; r++) {
      live[r].setRange(0, _w, buf[drop + r]);
    }
    _grid = live;
    if (drop > 0) {
      for (final p in _popups) {
        if (p.anchored) p.y -= drop; // centered popups are screen-placed already
      }
      final fs = [
        for (final f in _focusables)
          f.fixed
              ? f
              : _F(f.id, f.x, f.y - drop, f.w, f.h, f.order, f.tryKey,
                  onMap: f.onMap)
      ];
      _focusables
        ..clear()
        ..addAll(fs);
      if (_cursorPos case (final r, final c)) {
        _cursorPos = r - drop < 0 ? null : (r - drop, c);
      }
    }
    // A popup below the content (a suggest list) grows the live area just
    // enough; a Console prompt is centered on the whole terminal.
    final below = _popups.fold(shown, (m, p) => math.max(m, p.y + p.h));
    _statusY = _prompts.isNotEmpty ? _h - 1 : math.min(below, _h - 1);
    _usedRows = _statusY + 1;
  }

  void _drawStatus() {
    final y = _statusY;
    if (y < 0) return;
    String left;
    int leftStyle = 0;
    if (_error != null) {
      left = _error!;
      leftStyle = _pack(Color.red, null, {});
    } else if (_sayMsg != null) {
      left = _sayMsg!;
    } else if (_cSpinners.isNotEmpty || _cBars.isNotEmpty) {
      left = _consoleStatus();
    } else if (_statusLine != null) {
      left = _statusLine!;
    } else {
      left = '';
    }
    final helps = <String>[];
    for (final entry in _keys.entries) {
      if (entry.value.$1.trim().isEmpty) continue;
      final alts = keys
          .splitBinding(entry.key)
          .where((a) => !_isMouse(a) && !_isLifecycle(a))
          .toList();
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

  /// The running Console spinners and bars for the status row.
  String _consoleStatus() {
    final frames = _caps.ascii
        ? const ['-', '\\', '|', '/']
        : const ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    final parts = <String>[];
    for (final label in _cSpinners.values) {
      parts.add('${frames[_spinTick % frames.length]} $label');
    }
    for (final bar in _cBars.values) {
      final lab = bar.label == null ? '' : '${bar.label} ';
      final secs =
          DateTime.now().difference(bar.start).inMilliseconds / 1000;
      if (bar.bytes) {
        final rate = secs > 0 ? bar.done / secs : 0.0;
        final counts = bar.total != null && bar.total! > 0
            ? '${_fmtSize(bar.done)}/${_fmtSize(bar.total!)}'
            : _fmtSize(bar.done);
        parts.add(
            '$lab${_barGlyphs(bar.done, bar.total)}$counts  ${_fmtRate(rate)}');
      } else {
        final total = bar.total;
        final counts =
            total != null && total > 0 ? '${bar.done}/$total' : '${bar.done}';
        final rate = secs > 0 ? bar.done / secs : 0.0;
        parts.add('$lab${_barGlyphs(bar.done, total)}$counts  '
            '${_fmtCount(rate)}/s');
      }
    }
    return parts.join(' · ');
  }

  /// `━━━╸──── ` for a known total (like `Console.progressBar`), else nothing.
  String _barGlyphs(int done, int? total) {
    if (total == null || total <= 0) return '';
    const width = 10;
    final cells = (done / total).clamp(0.0, 1.0) * width;
    final full = cells.floor();
    final half = cells - full >= 0.5 && full < width;
    final (on, mid, off) = _caps.ascii ? ('#', '>', '-') : ('━', '╸', '─');
    return '${on * full}${half ? mid : ''}'
        '${off * (width - full - (half ? 1 : 0))} ';
  }

  void _writeRaw(int row, int from, int end, String text, int style) {
    if (row < 0 || row >= _grid.length) return;
    end = math.min(end, _w);
    var col = from;
    for (final rune in text.runes) {
      if (col >= end) break;
      if (rune < 0x20 || rune == 0x7f) continue;
      final w = term.isZeroWidth(rune) ? 0 : term.cellWidth(rune);
      if (w == 0) continue;
      if (col + w > end) break;
      _grid[row][col] = _Cell(String.fromCharCode(rune), style, w);
      if (w == 2 && col + 1 < end) {
        _grid[row][col + 1] = _Cell('', style, 0);
      }
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
          final ch = (r >= top && r < top + size)
              ? (_caps.ascii ? '#' : '█')
              : (_caps.ascii ? '|' : '│');
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
    if (!fullscreen) return _enterInline();
    try {
      final (w, h) = size();
      _w = math.max(1, w);
      _h = math.max(1, h);
    } catch (_) {}
    _grid = List.generate(_h, (_) => List.filled(_w, _Cell.blank));
    _modes = term.captureModes();
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
    });
    _resizeToken = exit.onResize(() {
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

  // Inline leaves the mouse to the terminal: no pointer reporting.
  String get _enterCodes => fullscreen
      ? '\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h\x1b[>1u'
      : '\x1b[?25l\x1b[?1004h\x1b[?2004h\x1b[>1u';

  String get _leaveCodes => fullscreen
      ? '\x1b[<u\x1b[0m\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?7h\x1b[?25h\x1b[?1049l'
      : '\x1b[<u\x1b[0m\x1b[?2004l\x1b[?1004l\x1b[?25h\n';

  void _listenStdin() => _subs.add(term.sharedStdin().listen((b) {
        _pending.addAll(b);
        _wake();
      }, onError: (_) {}));

  /// Ctrl-Z (POSIX): give the terminal back, stop this process, and take the
  /// terminal again when the shell continues it.
  void _suspend() {
    final modes = _modes;
    out(_leaveCodes);
    if (modes != null) term.restoreModes(modes);
    for (final sub in _subs) {
      sub.cancel(); // the tty reader must not outlive the stop (EINTR kills it)
    }
    _subs.clear();
    io.Process.killPid(io.pid, io.ProcessSignal.sigstop);
    term.setRawModes(modes, false);
    _listenStdin();
    out(_enterCodes);
    _repaint = true;
    _dirtyAndWake();
  }

  /// Write the leave codes and restore terminal modes. Idempotent: both the
  /// exit hook and the normal [_leave]/[_leaveInline] path call it.
  void _restoreTerminal() {
    if (!_entered) return;
    _entered = false;
    _done = true;
    try {
      out(_leaveCodes);
      final modes = _modes;
      if (modes != null) term.restoreModes(modes);
    } catch (_) {}
    if (identical(term.TuiBridge.current, this)) {
      term.TuiBridge.current = null;
    }
  }

  Future<void> _leave() async {
    if (!fullscreen) return _leaveInline();
    _done = true;
    _unwatchSignals();
    if (!_entered) return;
    _wake();
    await Future.wait(_subs.map((sub) async {
      try {
        await sub.cancel();
      } catch (_) {}
    }));
    _subs.clear();
    _restoreTerminal();
    try {
      await io.stdout.flush();
    } catch (_) {}
  }

  Future<void> _enterInline() async {
    try {
      final (w, h) = size();
      _w = math.max(1, w);
      _h = math.max(1, h);
    } catch (_) {}
    _grid = List.generate(_h, (_) => List.filled(_w, _Cell.blank));
    _modes = term.captureModes();
    term.setRawModes(_modes, false);
    _listenStdin();
    _watchSignals();
    out(_enterCodes);
    _repaint = true;
    _dirty = true;
    _entered = true;
    _liveH = 0;
    term.TuiBridge.current = this;
  }

  Future<void> _leaveInline() async {
    _done = true;
    _unwatchSignals();
    if (!_entered) return;
    _wake();
    await Future.wait(_subs.map((sub) async {
      try {
        await sub.cancel();
      } catch (_) {}
    }));
    _subs.clear();
    // The transcript stays in the scrollback; just park the cursor below.
    _restoreTerminal();
    try {
      await io.stdout.flush();
    } catch (_) {}
  }
}

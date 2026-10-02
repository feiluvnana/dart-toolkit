part of '../../tui.dart';

/// Terminal apps in the Elm shape: a state, a `view` of it, and an `update` that answers events.
///
/// ```dart
/// final n = await Tui.run(0,
///   view: (n) => Box(Label('Count: $n  (↑/↓, q quits)'), title: 'Counter'),
///   update: (n, e) => switch (e) {
///     Key.up => n + 1,
///     Key.down => n - 1,
///     Char(char: 'q') || Key.esc => Tui.quit(),
///     _ => n,
///   });
/// ```
///
/// {@category CLI}
abstract final class Tui {
  /// The terminal apps run on; `null` is the process's own (`/dev/tty`). Set a [FakeTerminal] to test.
  static Terminal? terminal;

  /// Runs an app full-screen (the alternate screen) and returns its last state.
  ///
  /// Keys go to the focused [Field], [Menu], [Grid] or [Tabs] first (Tab and Shift+Tab move the
  /// focus), then to [update]. [init] runs once the terminal is ready: where to [send] a first job.
  /// ^C, SIGTERM and a cancelled `Cancel.scope` throw a [CancelledException]; the terminal is
  /// put back on every way out. [mouse] reports clicks and the wheel.
  static Future<S> run<S>(
    S initial, {
    required Widget Function(S state) view,
    required S Function(S state, Object event) update,
    void Function()? init,
    TuiTheme theme = const TuiTheme(),
    bool mouse = false,
  }) => _Fn(initial, view, update, init, theme, mouse).run();

  /// Runs an app in the rows under the cursor instead, as tall as its view, and erases them on
  /// the way out: a picker or a prompt inside a script.
  ///
  /// ```dart
  /// final pick = Choice(filter: true);
  /// final file = await Tui.inline<String?>(null,
  ///   view: (_) => VStack([Label('Open which? ${pick.query}'), Menu(files, pick).fixed(8)]),
  ///   update: (s, e) => e == Key.enter && pick.index >= 0 ? Tui.quit(files[pick.index]) : s);
  /// ```
  static Future<S> inline<S>(
    S initial, {
    required Widget Function(S state) view,
    required S Function(S state, Object event) update,
    void Function()? init,
    TuiTheme theme = const TuiTheme(),
  }) => _Fn(initial, view, update, init, theme, false).run(inline: true);

  /// Delivers [message] to `update`: a [Future]'s value when it completes, each of a [Stream]'s,
  /// anything else on the next turn. A failure ends the app with it.
  ///
  /// ```dart
  /// init: () => Tui.send(Stream.periodic(1.s, (_) => #tick)),
  /// … if (e case Char(char: 'r')) { Tui.send(fetch().then(Loaded.new)); return s.loading(); }
  /// ```
  static void send(Object message) {
    final app = _Engine._active ?? (throw StateError('Tui.send needs a running app.'));
    switch (message) {
      case Future<Object?> f:
        f.then((v) => v == null ? null : app._event(v), onError: app._fail);
      case Stream<Object?> s:
        app._subs.add(s.listen((v) => v == null ? null : app._event(v), onError: app._fail));
      default:
        Timer.run(() => app._event(message));
    }
  }

  /// Ends the app from `update` or `view`; [state], when given, is what `run` returns.
  static Never quit([Object? state = _unset]) => throw _Quit(state);
}

const _unset = _Unset();

final class _Unset {
  const _Unset();
}

final class _Quit {
  final Object? state;

  const _Quit(this.state);
}

/// An app as a class: the same engine as [Tui.run], for one with state and tests of its own.
///
/// ```dart
/// class Todo extends TuiApp<List<String>> {
///   final input = Field(placeholder: 'New item');
///   Todo() : super([]);
///
///   @override
///   Widget view(List<String> items) => VStack([input, for (final i in items) Label('• $i')]);
///
///   @override
///   List<String> update(List<String> items, Object e) {
///     if (e == Key.esc) Tui.quit();
///     if (e != Key.enter) return items;
///     final item = input.text;
///     input.text = '';
///     return [...items, item];
///   }
/// }
/// await Todo().run();
/// ```
///
/// {@category CLI}
abstract class TuiApp<S> {
  /// The state now: the last `update`'s answer.
  S state;
  final TuiTheme theme;

  /// Whether clicks and the wheel are reported, full-screen.
  final bool mouse;

  TuiApp(this.state, {this.theme = const TuiTheme(), this.mouse = false});

  Widget view(S state);

  S update(S state, Object event);

  /// Runs once the terminal is ready.
  void init() {}

  /// Runs full-screen, or [inline] under the cursor; returns the last state.
  Future<S> run({bool inline = false}) => _Engine<S>(this, inline).run();
}

final class _Fn<S> extends TuiApp<S> {
  final Widget Function(S) _view;
  final S Function(S, Object) _update;
  final void Function()? _init;

  _Fn(super.state, this._view, this._update, this._init, TuiTheme theme, bool mouse)
    : super(theme: theme, mouse: mouse);

  @override
  Widget view(S state) => _view(state);

  @override
  S update(S state, Object event) => _update(state, event);

  @override
  void init() => _init?.call();
}

final class _Engine<S> {
  static _Engine<Object?>? _active;

  final TuiApp<S> app;
  final bool inline;
  late final Terminal term;
  final _decoder = _Decoder();
  final _done = Completer<S>();
  final _clock = Stopwatch()..start();
  final List<StreamSubscription<Object?>> _subs = [];
  _Control? _focused;
  List<(_Control, int, int, int, int)> _controls = const [];
  _Buffer? _front;
  List<String> _rows = const [];
  Timer? _escTimer, _frameTimer, _animTimer;
  void Function()? _unlinkCancel;
  bool _restored = false;

  _Engine(this.app, this.inline);

  Future<S> run() async {
    if (_active != null) throw StateError('A Tui app is already running.');
    term = Tui.terminal ?? _Tty.connect() ?? (throw StateError('Tui needs a terminal: /dev/tty cannot be opened.'));
    _active = this;
    try {
      await term.open();
      IoBridge.restores.add(_restore);
      term.write(
        inline
            ? '\x1b[?25l\x1b[?2004h'
            : '\x1b[?1049h\x1b[?25l\x1b[?2004h${app.mouse ? '\x1b[?1000h\x1b[?1002h\x1b[?1006h' : ''}',
      );
      final token = Cancel.token;
      runZonedGuarded(() {
        _subs
          ..add(term.input.listen(_bytes))
          ..add(term.resized.listen((_) => _event(Resize(term.width, term.height))));
        _unlinkCancel = token?.onCancel(
          () => _fail(CancelledException('${token.reason ?? 'Operation was cancelled.'}'), StackTrace.current),
        );
        app.init();
        _render();
      }, _fail);
      return await _done.future;
    } finally {
      _restore();
    }
  }

  void _bytes(List<int> bytes) {
    _escTimer?.cancel();
    _events(_decoder.add(bytes));
    if (_decoder.isWaiting) {
      _escTimer = Timer(const Duration(milliseconds: 30), () => _events(_decoder.flush()));
    }
  }

  /// Each event sees the frame the one before it caused: typed-ahead `ab⏎` filters before it picks.
  void _events(List<Object> events) {
    for (final e in events) {
      if (_frameTimer case final pending?) {
        pending.cancel();
        _render();
      }
      _event(e);
    }
  }

  /// A signal: the terminal first, synchronously, then the app's ending.
  void _interrupt() {
    final error = const CancelledException('Interrupted');
    _restore();
    _fail(error, StackTrace.current);
  }

  void _event(Object e) {
    if (_done.isCompleted) return;
    try {
      if (e == const Key('c', ctrl: true)) throw const CancelledException('Interrupted');
      if (e is Resize) _front = null;
      if (e is Mouse) {
        for (final (c, x, y, w, h) in _controls.reversed) {
          if (e.x >= x && e.x < x + w && e.y >= y && e.y < y + h) {
            if (e.kind == MouseKind.press) _focused = c;
            c._mouse(e, e.x - x, e.y - y);
            break;
          }
        }
      } else if ((e == Key.tab || e == Key.backTab) && _controls.length > 1) {
        final at = _controls.indexWhere((c) => identical(c.$1, _focused));
        _focused = _controls[(at + (e == Key.tab ? 1 : -1)) % _controls.length].$1;
        return _dirty();
      } else if (e is! Resize && (_focused?._handle(e) ?? false)) {
        return _dirty();
      }
      app.state = app.update(app.state, e);
      _dirty();
    } on _Quit catch (q) {
      _quit(q);
    } catch (error, st) {
      _fail(error, st);
    }
  }

  void _quit(_Quit q) {
    if (!identical(q.state, _unset)) app.state = q.state as S;
    if (!_done.isCompleted) _done.complete(app.state);
  }

  void _fail(Object error, StackTrace st) {
    if (!_done.isCompleted) _done.completeError(error, st);
  }

  void _dirty() => _frameTimer ??= Timer(Duration.zero, _render);

  void _render() {
    _frameTimer = null;
    if (_done.isCompleted || _restored) return;
    try {
      final widget = app.view(app.state);
      final frame = _Frame(_focused, _clock.elapsed);
      final depth = term.colors;
      if (inline) {
        final w = (term.width - 1).clamp(1, 1 << 16);
        final h = widget.heightAt(w).clamp(1, (term.height - 1).clamp(1, 1 << 16));
        final buf = _Buffer(w, h);
        widget.paint(Canvas._(buf, 0, 0, w, h, app.theme, frame));
        term.write(_inlineFrame(buf, depth));
      } else {
        final buf = _Buffer(term.width, term.height);
        widget.paint(Canvas._(buf, 0, 0, buf.width, buf.height, app.theme, frame));
        term.write(_diff(_front, buf, depth));
        _front = buf;
      }
      _controls = frame.controls;
      if (!_controls.any((c) => identical(c.$1, _focused))) _focused = _controls.firstOrNull?.$1;
      if (frame.animate case final every?) {
        _animTimer ??= Timer(every, () {
          _animTimer = null;
          _render();
        });
      }
    } on _Quit catch (q) {
      _quit(q);
    } catch (error, st) {
      _fail(error, st);
    }
  }

  /// The escapes that turn [old] into [now]: only the cells that changed.
  static String _diff(_Buffer? old, _Buffer now, int depth) {
    final out = StringBuffer('\x1b[?2026h');
    if (old != null && (old.width != now.width || old.height != now.height)) old = null;
    if (old == null) out.write('\x1b[0m\x1b[2J');
    Style? current;
    var (cx, cy) = (-1, -1);
    for (var y = 0; y < now.height; y++) {
      for (var x = 0; x < now.width; x++) {
        final i = y * now.width + x;
        final ch = now.chars[i], s = now.styles[i];
        if (ch.isEmpty) continue;
        if (old == null ? ch == ' ' && s == Style.none : old.chars[i] == ch && old.styles[i] == s) continue;
        if (cy != y || cx != x) out.write('\x1b[${y + 1};${x + 1}H');
        if (s != current) out.write(s._sgr(depth));
        current = s;
        out.write(ch);
        (cx, cy) = (x + (x + 1 < now.width && now.chars[i + 1].isEmpty ? 2 : 1), y);
      }
    }
    out.write('\x1b[0m\x1b[?2026l');
    return '$out';
  }

  /// Redraws the inline region: up to its first row, each changed row, and erases what it outgrew.
  String _inlineFrame(_Buffer buf, int depth) {
    final rows = [for (var y = 0; y < buf.height; y++) buf.row(y, depth)];
    final out = StringBuffer('\x1b[?2026h\r');
    if (_rows.length > 1) out.write('\x1b[${_rows.length - 1}A');
    for (final (y, row) in rows.indexed) {
      if (y > 0) out.write('\r\n');
      if (y >= _rows.length || _rows[y] != row) out.write('\x1b[2K$row');
    }
    // Erase what it outgrew: from the row below this one down (this row may have been skipped).
    if (rows.length < _rows.length) out.write('\x1b[1B\r\x1b[J\x1b[1A');
    out.write('\x1b[?2026l');
    _rows = rows;
    return '$out';
  }

  /// Puts the terminal back: once, synchronously, on every way out.
  void _restore() {
    if (_restored) return;
    _restored = true;
    IoBridge.restores.remove(_restore);
    if (identical(_active, this)) _active = null;
    for (final t in [_escTimer, _frameTimer, _animTimer]) {
      t?.cancel();
    }
    for (final s in _subs) {
      s.cancel();
    }
    _unlinkCancel?.call();
    try {
      term.write(
        inline
            ? '\r${_rows.length > 1 ? '\x1b[${_rows.length - 1}A' : ''}\x1b[J\x1b[0m\x1b[?2004l\x1b[?25h'
            : '\x1b[0m${app.mouse ? '\x1b[?1006l\x1b[?1002l\x1b[?1000l' : ''}\x1b[?2004l\x1b[?25h\x1b[?1049l',
      );
    } finally {
      term.close();
    }
  }
}

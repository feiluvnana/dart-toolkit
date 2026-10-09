part of '../../tui.dart';

/// Terminal apps in the Elm shape: a state, a `view` of it, and an `update` that answers events.
///
/// ```dart
/// final n = await Tui.run<int, Tick>(0,
///   view: (n) => Box(Label('Count: $n  (↑/↓, q quits)'), title: 'Counter'),
///   update: (n, e) => switch (e) {
///     KeyPress.up => n + 1,
///     Sent(message: Tick()) => n + 1,
///     Char(char: 'q') || KeyPress.esc => Tui.quit(n),
///     _ => n,
///   },
///   init: (app) => app.listen(Stream.periodic(1.s, (_) => const Tick())));
/// ```
///
/// {@category CLI}
abstract final class Tui {
  /// Runs an app full-screen (the alternate screen) and returns its last state; [inline] runs it
  /// in the rows under the cursor instead, as tall as its view, and erases them on the way out.
  ///
  /// Keys go to the focused control first ([Field], [Menu], [Grid], [Tabs], [Scroll], [Log],
  /// [Button], or a widget of your own `with Focusable`; Tab and Shift+Tab move the focus), then
  /// to [update]. Your own messages ([M]) arrive as [Sent]: from `app.send`, `app.listen`, a
  /// [Button] or a [Clickable]. [init] runs once the terminal is ready, with the app.
  ///
  /// [mouse] reports clicks, the wheel and the pointer's moves (for hover), inline too; it is
  /// opt-in, because it takes over the terminal's own selection and scrolling.
  ///
  /// ^C is a SIGINT (under `Cli`, the run's cleanups then 130); a signal or a cancelled
  /// `Cancel.scope` otherwise throws a [CancelledException]. The terminal is put back on every
  /// way out. It runs on the terminal of `Io.scope(terminal:)`, else the process's.
  static Future<S> run<S, M>(
    S initial, {
    required Widget Function(S state) view,
    required S Function(S state, TuiEvent<M> event) update,
    void Function(TuiApp<S, M> app)? init,
    TuiTheme theme = const TuiTheme(),
    bool inline = false,
    bool mouse = false,
  }) => _Fn<S, M>(initial, view, update, init, theme, mouse).run(inline: inline);

  /// Ends the app from `update` or `view`: [state] is what `run` returns. A state of another
  /// type than the app's is an [ArgumentError].
  static Never quit<S>(S state) => throw _Quit(state);
}

final class _Quit {
  final Object? state;

  const _Quit(this.state);
}

/// An app as a class: the same engine as [Tui.run], for one with state and tests of its own.
/// [M] is the type of its own messages; `Never` when it has none. While it runs it is also the
/// handle [send], [listen] and [focus] are called on.
///
/// ```dart
/// class Todo extends TuiApp<List<String>, Never> {
///   final input = Field(placeholder: 'New item');
///   Todo() : super([]);
///
///   @override
///   Widget view(List<String> items) => VStack([input, for (final i in items) Label('• $i')]);
///
///   @override
///   List<String> update(List<String> items, TuiEvent<Never> e) {
///     if (e == KeyPress.esc) Tui.quit(items);
///     if (e != KeyPress.enter) return items;
///     final item = input.text;
///     input.text = '';
///     return [...items, item];
///   }
/// }
/// await Todo().run();
/// ```
///
/// {@category CLI}
abstract class TuiApp<S, M> {
  /// The state now: the last `update`'s answer.
  S state;
  final TuiTheme theme;

  /// Whether clicks, the wheel and the pointer's moves are reported.
  final bool mouse;

  _Engine<S, M>? _engine;

  TuiApp(this.state, {this.theme = const TuiTheme(), this.mouse = false});

  Widget view(S state);

  S update(S state, TuiEvent<M> event);

  /// Runs once the terminal is ready: where to [listen] and [send] first.
  void init() {}

  /// Runs full-screen, or [inline] under the cursor; returns the last state.
  Future<S> run({bool inline = false}) => _Engine<S, M>(this, inline).run();

  _Engine<S, M> _running(String what) => _engine ?? (throw StateError('Cannot $what: the app is not running'));

  /// Delivers [message] to `update` as a [Sent]: on the next turn, or a [Future]'s value when it
  /// completes; a failure ends the app with it.
  void send(FutureOr<M> message) {
    final engine = _running('send');
    if (message is Future<M>) {
      message.then(engine._message, onError: engine._fail);
    } else {
      Timer.run(() => engine._message(message));
    }
  }

  /// Delivers each of [messages] to `update` as a [Sent] until the app ends or the returned
  /// function stops it; an error ends the app with it.
  void Function() listen(Stream<M> messages) {
    final engine = _running('listen');
    final subscription = messages.listen(engine._message, onError: engine._fail);
    engine._subs.add(subscription);
    return () {
      engine._subs.remove(subscription);
      subscription.cancel();
    };
  }

  /// Gives the focus to [control]; it takes it on the next frame that draws it.
  void focus(Focusable control) {
    final engine = _running('focus');
    engine._focused = control;
    engine._dirty();
  }
}

final class _Fn<S, M> extends TuiApp<S, M> {
  final Widget Function(S) _view;
  final S Function(S, TuiEvent<M>) _update;
  final void Function(TuiApp<S, M> app)? _init;

  _Fn(super.state, this._view, this._update, this._init, TuiTheme theme, bool mouse)
    : super(theme: theme, mouse: mouse);

  @override
  Widget view(S state) => _view(state);

  @override
  S update(S state, TuiEvent<M> event) => _update(state, event);

  @override
  void init() => _init?.call(this);
}

final class _Engine<S, M> {
  static _Engine<Object?, Object?>? _active;

  final TuiApp<S, M> app;
  final bool inline;
  late final Terminal term;
  late final _keys = TerminalBridge(_events, position: _position, kitty: _kittyOn);
  final _done = Completer<S>();
  final _clock = Clock.current;
  late final Duration _start = _clock.elapsed;
  final List<StreamSubscription<Object?>> _subs = [];
  final Map<Tally, StreamSubscription<Object?>> _watched = {};
  late final TuiTheme _theme = app.theme._drawable(unicode: term.unicode);
  Focusable? _focused;
  _Frame? _last;
  List<_Placed> _placed = const [];
  _Buffer? _front;
  List<String> _rows = const [];
  Timer? _frameTimer, _animTimer;
  void Function()? _unlinkCancel;
  bool _restored = false, _kitty = false;

  /// Where the pointer is and where a button went down, in the app's own rows; the screen row
  /// of an inline region's first row, once the terminal has said.
  (int, int)? _pointer, _pressed;
  int? _top;
  bool _askPosition = false;

  void Function(void Function() write)? _outer;

  /// Durable writes made while the alternate screen is up, run once it closes.
  final List<void Function()> _held = [];

  _Engine(this.app, this.inline);

  Future<S> run() async {
    if (_active != null) throw StateError('Cannot run two Tui apps at once');
    term = TerminalBridge.connect() ?? (throw StateError('Cannot run a Tui app: there is no terminal (/dev/tty)'));
    _active = this;
    app._engine = this;
    TerminalBridge.app = this;
    TerminalBridge.interrupted = _interrupt;
    try {
      _theme;
      await term.open();
      IoBridge.restores.add(_restore);
      _outer = IoBridge.above;
      IoBridge.above = _above;
      final mouse = app.mouse ? '\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h' : '';
      // `?u` asks whether the kitty keyboard protocol is spoken: one that answers is switched on.
      term.write('${inline ? '' : '\x1b[?1049h'}\x1b[?25l\x1b[?2004h$mouse\x1b[?u');
      final token = Cancel.token;
      final printing = ZoneSpecification(print: (_, _, _, line) => _above(() => Io.stdout.writeln(line)));
      runZonedGuarded(zoneSpecification: printing, () {
        _subs
          ..add(term.input.listen(_keys.add))
          ..add(term.resized.listen((_) => _event(Resize(term.width, term.height))));
        _unlinkCancel = token?.onCancel(
          () => _fail(CancelledException('${token.reason ?? 'cancelled'}'), StackTrace.current),
        );
        app.init();
        _askPosition = inline && app.mouse;
        _render();
      }, _fail);
      return await _done.future;
    } finally {
      _restore();
    }
  }

  void _kittyOn() {
    if (_kitty || _restored) return;
    _kitty = true;
    term.write('\x1b[>1u');
  }

  /// The terminal's answer to where the cursor is: the inline region's last row.
  void _position(int row, int column) {
    if (!inline) return;
    _top = row - 1 - (_rows.length - 1);
  }

  /// Each event sees the frame the one before it caused: typed-ahead `ab⏎` filters before it picks.
  void _events(List<TuiEvent<Never>> events) {
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
    _restore();
    _fail(const CancelledException('Interrupted'), StackTrace.current);
  }

  /// [message], from `send`, `listen`, a [Button] or a [Clickable], as the [Sent] it is.
  void _message(Object? message) {
    if (message is M) return _event(Sent<M>(message));
    _fail(ArgumentError.value(message, 'message', 'Invalid message, expected $M'), StackTrace.current);
  }

  /// The reachable target under [x], [y], topmost first.
  _Target? _at(int x, int y) {
    final targets = _last?.reachable.toList() ?? const <_Target>[];
    for (final t in targets.reversed) {
      if (t.contains(x, y)) return t;
    }
    return null;
  }

  void _event(TuiEvent<M> e) {
    if (_done.isCompleted) return;
    try {
      if (e == const KeyPress('c', ctrl: true)) return TerminalBridge.ctrlC(term, _interrupt);
      if (e is Resize) {
        _front = null;
        _askPosition = inline && app.mouse;
      }
      var event = e;
      if (e is Mouse) {
        final y = inline ? (_top == null ? -1 : e.y - _top!) : e.y;
        if (y < 0 || y >= (inline ? _rows.length : term.height)) return;
        event = Mouse(e.x, y, e.kind, button: e.button, ctrl: e.ctrl, alt: e.alt, shift: e.shift);
        if (_mouse(event as Mouse)) return _dirty();
      } else if ((e == KeyPress.tab || e == KeyPress.backTab) && (_last?.focusables.length ?? 0) > 1) {
        final all = _last!.focusables.toList();
        final at = all.indexWhere((c) => c == _focused);
        _focused = all[(at + (e == KeyPress.tab ? 1 : -1)) % all.length];
        return _dirty();
      } else if (e is! Resize && e is! Sent && (_focused?.handle(e) ?? false)) {
        return _dirty();
      }
      app.state = app.update(app.state, event);
      _dirty();
    } on _Quit catch (q) {
      _quit(q);
    } catch (error, st) {
      _fail(error, st);
    }
  }

  /// The pointer: hover, press and release, popups' dismissal, clicks; `true` when it is used up.
  bool _mouse(Mouse e) {
    final at = (e.x, e.y);
    switch (e.kind) {
      case MouseKind.move || MouseKind.drag:
        final moved = _pointer != at;
        _pointer = at;
        if (e.kind == MouseKind.move) {
          if (moved) _dirty();
          return true;
        }
      case MouseKind.press:
        _pointer = _pressed = at;
        final outside = _placed.where((p) => p.layer.dismissible).lastOrNull;
        final inside = _placed.any((p) => e.x >= p.x && e.x < p.x + p.w && e.y >= p.y && e.y < p.y + p.h);
        if (outside != null && !inside) {
          _message(outside.layer.dismiss);
          return true;
        }
        final target = _at(e.x, e.y);
        if (target?.control case final control?) _focused = control;
        if (target != null) target.control?.mouse(e, e.x - target.x, e.y - target.y);
      case MouseKind.release:
        final down = _pressed;
        _pressed = null;
        _pointer = at;
        final target = _at(e.x, e.y);
        if (down != null && target != null && target.clickable && target.contains(down.$1, down.$2)) {
          _message(target.message);
        }
      case MouseKind.wheelUp || MouseKind.wheelDown:
        final target = _at(e.x, e.y);
        if (target != null) target.control?.mouse(e, e.x - target.x, e.y - target.y);
    }
    return false;
  }

  void _quit(_Quit q) {
    if (q.state is! S) {
      return _fail(
        ArgumentError.value(q.state, 'state', 'Invalid state for Tui.quit, expected $S'),
        StackTrace.current,
      );
    }
    app.state = q.state as S;
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
      final frame = _Frame(_focused, _clock.elapsed - _start, pointer: _pointer, pressed: _pressed);
      final depth = term.colors;
      final _Buffer buf;
      if (inline) {
        final w = (term.width - 1).clamp(1, 1 << 16);
        final h = widget.heightAt(w).clamp(1, (term.height - 1).clamp(1, 1 << 16));
        buf = _Buffer(w, h);
        widget.paint(Canvas._(buf, 0, 0, w, h, _theme, frame));
        _placed = _paintPopups(buf, frame, _theme);
        final grew = h != _rows.length;
        term.write(_inlineFrame(buf, depth));
        if (app.mouse && (grew || _askPosition)) {
          _askPosition = false;
          term.write('\x1b[6n');
        }
      } else {
        buf = _Buffer(term.width, term.height);
        widget.paint(Canvas._(buf, 0, 0, buf.width, buf.height, _theme, frame));
        _placed = _paintPopups(buf, frame, _theme);
        term.write(_diff(_front, buf, depth));
        _front = buf;
      }
      _last = frame;
      final reachable = frame.focusables.toList();
      if (!reachable.contains(_focused)) _focused = reachable.firstOrNull;
      _watch(frame.tallies);
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

  /// Listens to the tallies a frame drew, and stops listening to the ones it no longer draws.
  void _watch(Set<Tally> drawn) {
    for (final tally in drawn) {
      _watched[tally] ??= tally.changes.listen((_) => _dirty());
    }
    for (final tally in [..._watched.keys]) {
      if (!drawn.contains(tally)) _watched.remove(tally)!.cancel();
    }
  }

  /// The escapes that turn [old] into [now]: only the cells that changed.
  static String _diff(_Buffer? old, _Buffer now, int depth) {
    final out = StringBuffer('\x1b[?2026h');
    if (old != null && (old.width != now.width || old.height != now.height)) old = null;
    if (old == null) out.write('\x1b[0m\x1b[2J');
    Style? current;
    String? link;
    var (cx, cy) = (-1, -1);
    for (var y = 0; y < now.height; y++) {
      for (var x = 0; x < now.width; x++) {
        final i = y * now.width + x;
        final ch = now.chars[i], s = now.styles[i], l = now.links[i];
        if (ch.isEmpty) continue;
        if (old == null
            ? ch == ' ' && s == Style.none && l == null
            : old.chars[i] == ch && old.styles[i] == s && old.links[i] == l) {
          continue;
        }
        if (cy != y || cx != x) out.write('\x1b[${y + 1};${x + 1}H');
        if (s != current) out.write(TerminalBridge.sgrOf(s, depth));
        if (l != link) out.write(_osc8(link = l));
        current = s;
        out.write(ch);
        (cx, cy) = (x + (x + 1 < now.width && now.chars[i + 1].isEmpty ? 2 : 1), y);
      }
    }
    if (link != null) out.write(_osc8(null));
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

  /// A `print`, a Console line, a table: above the inline region, or after the alternate screen
  /// closes, never through the frame.
  void _above(void Function() write) {
    if (_restored) return write();
    if (!inline) return _held.add(write);
    final (out, err) = IoBridge.capture(write);
    final text = '$out$err';
    if (text.isEmpty) return;
    // Raw mode: a line feed does not return the carriage.
    term.write('\r${_rows.length > 1 ? '\x1b[${_rows.length - 1}A' : ''}\x1b[J${text.replaceAll('\n', '\r\n')}');
    _rows = const [];
    _askPosition = app.mouse;
    _render();
  }

  /// Puts the terminal back: once, synchronously, on every way out.
  void _restore() {
    if (_restored) return;
    _restored = true;
    IoBridge.restores.remove(_restore);
    if (IoBridge.above == _above) IoBridge.above = _outer;
    if (identical(_active, this)) _active = null;
    if (identical(TerminalBridge.app, this)) TerminalBridge.app = null;
    app._engine = null;
    if (TerminalBridge.interrupted == _interrupt) TerminalBridge.interrupted = null;
    _keys.cancel();
    for (final t in [_frameTimer, _animTimer]) {
      t?.cancel();
    }
    for (final s in [..._subs, ..._watched.values]) {
      s.cancel();
    }
    _unlinkCancel?.call();
    final mouse = app.mouse ? '\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l' : '';
    final keys = _kitty ? '\x1b[<u' : '';
    try {
      term.write(
        inline
            ? '\r${_rows.length > 1 ? '\x1b[${_rows.length - 1}A' : ''}\x1b[J\x1b[0m$mouse$keys\x1b[?2004l\x1b[?25h'
            : '\x1b[0m$mouse$keys\x1b[?2004l\x1b[?25h\x1b[?1049l',
      );
    } finally {
      term.close();
    }
    for (final write in _held) {
      write();
    }
    _held.clear();
  }
}

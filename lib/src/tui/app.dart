part of '../../tui.dart';

/// Terminal apps in the Elm shape: a state, a `draw` of it, and an `update` that answers every
/// event. One app runs at a time, so its side effects are statics here: [post], [listen],
/// [defer], [focus] and [quit].
///
/// ```dart
/// final n = await Tui.run<int, Tick>(0,
///   draw: (n) => Box(Label('Count: $n  (↑/↓, q quits)'), title: 'Counter'),
///   update: (n, e) => switch (e) {
///     Start() => (Tui.listen(Stream.periodic(1.s, (_) => const Tick())), n).$2,
///     KeyPress.up || Post(message: Tick()) => n + 1,
///     KeyPress(name: 'q') || KeyPress.esc => Tui.quit(n),
///     _ => n,
///   });
/// ```
///
/// {@category CLI}
abstract final class Tui {
  /// Runs an app full-screen (the alternate screen) and answers its last state; [inline] runs it
  /// in the rows under the cursor instead, as tall as it draws, and erases them on the way out.
  ///
  /// `update` hears a [Start] first, then every key, paste, resize and message. Keys go to the
  /// focused control first ([Field], [Menu], [Grid], [Tabs], [Scroll], [Log], [Button], or a
  /// widget of your own `with Focusable`; Tab and Shift+Tab move the focus). `draw` runs after
  /// every update, on a resize, and while something animates.
  ///
  /// [pointer] reports clicks, the wheel and the pointer's moves (for hover); it is opt-in,
  /// because it takes over the terminal's own selection and scrolling.
  ///
  /// ^C is an [Interrupt] (see there); ^Z a [Suspend] then a [Resume]. Cancelling the task ends
  /// the app with a [CancelledException]. The terminal is put back on every way out, then each
  /// [defer]red cleanup runs, then the task completes. It runs on the terminal of
  /// `Io.scope(terminal:)`, else the process's.
  static Task<S> run<S, M>(
    S initial, {
    required Widget Function(S state) draw,
    required S Function(S state, TuiEvent<M> event) update,
    TuiTheme theme = const TuiTheme(),
    bool pointer = false,
    bool inline = false,
  }) => _Fn<S, M>(initial, draw, update, theme, pointer, inline).run();

  /// Ends the app from `update` or `draw`: [state] is what `run` answers. A state of another
  /// type than the app's is an [ArgumentError].
  static Never quit<S>(S state) => throw _Quit(state);

  /// Delivers [message] to `update` as a [Post]: on the next turn, or a [Future]'s value when it
  /// completes. A failure ends the app with it, or with [onError] becomes the message it answers.
  ///
  /// ```dart
  /// Tui.post(archive.search(query).then(Found.new), onError: SearchFailed.new);
  /// ```
  static void post<M>(FutureOr<M> message, {M Function(Object error)? onError}) {
    final engine = _running('post');
    if (message is! Future<M>) return Timer.run(() => engine._message(message));
    message.then(
      engine._message,
      onError: (Object error, StackTrace stackTrace) {
        if (onError == null) return engine._fail(error, stackTrace);
        try {
          engine._message(onError(error));
        } catch (e, st) {
          engine._fail(e, st);
        }
      },
    );
  }

  /// Delivers each of [messages] to `update` as a [Post] until the app ends or the returned
  /// function stops it; an error ends the app with it.
  static void Function() listen<M>(Stream<M> messages) {
    final engine = _running('listen');
    final subscription = messages.listen(engine._message, onError: engine._fail);
    engine._subs.add(subscription);
    return () {
      engine._subs.remove(subscription);
      subscription.cancel();
    };
  }

  /// Runs [cleanup] once the app has ended and the terminal is put back, however it ended, last
  /// deferred first; one that throws is a [Warned] of the task, as `work.defer` says.
  static void defer(FutureOr<void> Function() cleanup) => _running('defer')._work.defer(cleanup);

  /// Gives the focus to [control]; it takes it on the next frame that draws it.
  static void focus(Focusable control) {
    final engine = _running('focus');
    engine._focused = control;
    engine._dirty();
  }

  static _Engine<Object?, Object?> _running(String what) =>
      _Engine._active ?? (throw StateError('Cannot $what: no Tui app is running'));
}

final class _Quit {
  final Object? state;

  const _Quit(this.state);
}

/// An app as a class: the same engine as [Tui.run], for one with state and tests of its own.
/// [M] is the type of its own messages; `Never` when it has none.
///
/// ```dart
/// class Todo extends TuiApp<List<String>, Never> {
///   final input = Field(placeholder: 'New item');
///   Todo() : super([]);
///
///   @override
///   Widget draw(List<String> items) => VStack([input, for (final i in items) Label('• $i')]);
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
  final S _initial;
  final TuiTheme theme;

  /// Whether clicks, the wheel and the pointer's moves are reported.
  final bool pointer;

  /// Whether it runs in the rows under the cursor rather than full-screen.
  final bool inline;

  TuiApp(S initial, {this.theme = const TuiTheme(), this.pointer = false, this.inline = false}) : _initial = initial;

  Widget draw(S state);

  S update(S state, TuiEvent<M> event);

  /// Runs it from its initial state, as [Tui.run] does; answers the last state.
  Task<S> run() => Task.run('Tui', (work) => _Engine<S, M>(this, work).run());
}

final class _Fn<S, M> extends TuiApp<S, M> {
  final Widget Function(S) _draw;
  final S Function(S, TuiEvent<M>) _update;

  _Fn(super.initial, this._draw, this._update, TuiTheme theme, bool pointer, bool inline)
    : super(theme: theme, pointer: pointer, inline: inline);

  @override
  Widget draw(S state) => _draw(state);

  @override
  S update(S state, TuiEvent<M> event) => _update(state, event);
}

final class _Engine<S, M> {
  static _Engine<Object?, Object?>? _active;

  /// How soon a second ^C ends the app whatever `update` says.
  static const _again = Duration(seconds: 2);

  final TuiApp<S, M> app;
  final Work _work;
  late S _state = app._initial;
  late final bool inline = app.inline;
  late final Terminal term;
  late final _keys = KeysBridge(_events, position: _position, kitty: _kittyOn);
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
  bool _restored = false, _kitty = false, _suspended = false;
  Duration? _interrupted;

  /// Where the pointer is and where a button went down, in the app's own rows; the screen row
  /// of an inline region's first row, once the terminal has said.
  (int, int)? _pointer, _pressed;
  int? _top;
  bool _askPosition = false;

  void Function(void Function() write)? _outer;

  /// What was printed while the alternate screen is up, as text by stream (`true`: stderr) in
  /// chunks of 64 KiB, written once it closes.
  final List<(bool, String)> _held = [];
  final _holding = StringBuffer();
  bool _holdingErr = false;

  _Engine(this.app, this._work);

  Future<S> run() async {
    if (_active != null) throw StateError('Cannot run two Tui apps at once');
    term = KeysBridge.connect() ?? (throw StateError('Cannot run a Tui app: there is no terminal (/dev/tty)'));
    _active = this;
    TerminalBridge.app = this;
    KeysBridge.interrupted = _interrupt;
    try {
      _theme;
      await term.open();
      IoBridge.restores.add(_restore);
      _outer = IoBridge.above;
      IoBridge.above = _above;
      // `?u` asks whether the kitty keyboard protocol is spoken: one that answers is switched on.
      term.write('${_modes(on: true)}\x1b[?u');
      final token = Cancel.token;
      final printing = ZoneSpecification(print: (_, _, _, line) => _above(() => Io.stdout.writeln(line)));
      runZonedGuarded(zoneSpecification: printing, () {
        _subs
          ..add(term.input.listen(_keys.add))
          ..add(term.resized.listen((_) => _event(Resize(term.width, term.height))));
        _unlinkCancel = token?.onCancel(
          () => _fail(CancelledException('${token.reason ?? 'cancelled'}'), StackTrace.current),
        );
        _askPosition = inline && app.pointer;
        _event(const Start());
        _render();
      }, _fail);
      return await _done.future;
    } finally {
      _restore();
    }
  }

  /// The modes an app runs in, switched [on] or back off.
  String _modes({required bool on}) {
    final pointer = app.pointer ? '\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h' : '';
    if (on) return '${inline ? '' : '\x1b[?1049h'}\x1b[?25l\x1b[?2004h\x1b[?1004h$pointer${_kitty ? '\x1b[>1u' : ''}';
    final region = inline ? '\r${_rows.length > 1 ? '\x1b[${_rows.length - 1}A' : ''}\x1b[J' : '';
    return '$region\x1b[0m${pointer.replaceAll('h', 'l')}${_kitty ? '\x1b[<u' : ''}\x1b[?1004l\x1b[?2004l\x1b[?25h'
        '${inline ? '' : '\x1b[?1049l'}';
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
      if (_frameTimer != null) _render();
      _event(e);
    }
  }

  /// A signal from outside: the terminal first, synchronously, then the app's ending.
  void _interrupt() {
    _restore();
    _fail(const CancelledException('Interrupted'), StackTrace.current);
  }

  /// [message], from `post`, `listen`, a [Button] or a [Clickable], as the [Post] it is.
  void _message(Object? message) {
    if (message is M) return _event(Post<M>(message));
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
      if (e == const KeyPress('c', ctrl: true)) return _ctrlC();
      if (e == const KeyPress('z', ctrl: true) && !(Platform.isWindows && KeysBridge.isTty(term))) {
        _suspend().catchError(_fail);
        return;
      }
      if (e is Resize) {
        _front = null;
        _askPosition = inline && app.pointer;
      }
      var event = e;
      if (e is Pointer) {
        final y = inline ? (_top == null ? -1 : e.y - _top!) : e.y;
        if (y < 0 || y >= (inline ? _rows.length : term.height)) return;
        event = Pointer(e.x, y, e.kind, button: e.button, ctrl: e.ctrl, alt: e.alt, shift: e.shift);
        if (_pointed(event as Pointer)) return _dirty();
      } else if ((e == KeyPress.tab || e == KeyPress.backTab) && (_last?.focusables.length ?? 0) > 1) {
        final all = _last!.focusables.toList();
        final at = all.indexWhere((c) => c == _focused);
        _focused = all[(at + (e == KeyPress.tab ? 1 : -1)) % all.length];
        return _dirty();
      } else if ((e is KeyPress || e is Paste) && (_focused?.handle(e) ?? false)) {
        return _dirty();
      }
      _state = app.update(_state, event);
      _dirty();
    } on _Quit catch (q) {
      _quit(q);
    } catch (error, st) {
      _fail(error, st);
    }
  }

  /// ^C: an [Interrupt] for `update`, which keeps the app open by answering another state; the
  /// same state, or a second ^C soon after, ends it as a SIGINT would.
  void _ctrlC() {
    final now = _clock.elapsed;
    final again = _interrupted != null && now - _interrupted! < _again;
    _interrupted = now;
    if (!again) {
      final before = _state;
      _state = app.update(before, const Interrupt());
      if (!identical(_state, before)) return _dirty();
    }
    KeysBridge.ctrlC(term, _interrupt);
  }

  /// ^Z: `update` hears [Suspend], the terminal is put back and the process stops; once it runs
  /// again the terminal is taken back, drawn whole, and `update` hears [Resume].
  Future<void> _suspend() async {
    try {
      _state = app.update(_state, const Suspend());
    } on _Quit catch (q) {
      return _quit(q);
    }
    _suspended = true;
    term
      ..write(_modes(on: false))
      ..close();
    _rows = const [];
    await term.suspend();
    if (_done.isCompleted || _restored) return;
    await term.open();
    term.write(_modes(on: true));
    _suspended = false;
    _front = null;
    _askPosition = inline && app.pointer;
    _event(const Resume());
    _render();
  }

  /// The pointer: hover, press and release, popups' dismissal, clicks; `true` when it is used up.
  bool _pointed(Pointer e) {
    final at = (e.x, e.y);
    switch (e.kind) {
      case PointerKind.move || PointerKind.drag:
        final moved = _pointer != at;
        _pointer = at;
        if (e.kind == PointerKind.move) {
          if (moved) _dirty();
          return true;
        }
      case PointerKind.press:
        _pointer = _pressed = at;
        final outside = _placed.where((p) => p.layer.dismissible).lastOrNull;
        final inside = _placed.any((p) => e.x >= p.x && e.x < p.x + p.w && e.y >= p.y && e.y < p.y + p.h);
        if (outside != null && !inside) {
          _message(outside.layer.dismiss);
          return true;
        }
        final target = _at(e.x, e.y);
        if (target?.control case final control?) _focused = control;
        if (target != null) target.control?.pointer(e, e.x - target.x, e.y - target.y);
      case PointerKind.release:
        final down = _pressed;
        _pressed = null;
        _pointer = at;
        final target = _at(e.x, e.y);
        if (down != null && target != null && target.clickable && target.contains(down.$1, down.$2)) {
          _message(target.message);
        }
      case PointerKind.wheelUp || PointerKind.wheelDown:
        final target = _at(e.x, e.y);
        if (target != null) target.control?.pointer(e, e.x - target.x, e.y - target.y);
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
    _state = q.state as S;
    if (!_done.isCompleted) _done.complete(_state);
  }

  void _fail(Object error, [StackTrace? st]) {
    if (!_done.isCompleted) _done.completeError(error, st ?? StackTrace.current);
  }

  void _dirty() => _frameTimer ??= Timer(Duration.zero, _render);

  void _render() {
    _frameTimer?.cancel();
    _frameTimer = null;
    if (_done.isCompleted || _restored || _suspended) return;
    try {
      final widget = app.draw(_state);
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
        if (app.pointer && (grew || _askPosition)) {
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
    final (out, err) = IoBridge.capture(write);
    if (!inline) {
      _hold(false, out);
      _hold(true, err);
      return;
    }
    final text = '$out$err';
    if (text.isEmpty) return;
    // Raw mode: a line feed does not return the carriage.
    term.write('\r${_rows.length > 1 ? '\x1b[${_rows.length - 1}A' : ''}\x1b[J${text.replaceAll('\n', '\r\n')}');
    _rows = const [];
    _askPosition = app.pointer;
    _dirty();
  }

  /// Keeps [text] for after the alternate screen, with what was printed to the same stream.
  void _hold(bool err, String text) {
    if (text.isEmpty) return;
    if (err != _holdingErr || _holding.length > 1 << 16) _seal();
    _holdingErr = err;
    _holding.write(text);
  }

  void _seal() {
    if (_holding.isEmpty) return;
    _held.add((_holdingErr, '$_holding'));
    _holding.clear();
  }

  /// Puts the terminal back: once, synchronously, on every way out.
  void _restore() {
    if (_restored) return;
    _restored = true;
    IoBridge.restores.remove(_restore);
    if (IoBridge.above == _above) IoBridge.above = _outer;
    if (identical(_active, this)) _active = null;
    if (identical(TerminalBridge.app, this)) TerminalBridge.app = null;
    if (KeysBridge.interrupted == _interrupt) KeysBridge.interrupted = null;
    _keys.cancel();
    for (final t in [_frameTimer, _animTimer]) {
      t?.cancel();
    }
    for (final s in [..._subs, ..._watched.values]) {
      s.cancel();
    }
    _unlinkCancel?.call();
    try {
      if (!_suspended) term.write(_modes(on: false));
    } finally {
      if (!_suspended) term.close();
    }
    _seal();
    for (final (err, text) in _held) {
      (err ? Io.stderr : Io.stdout).write(text);
    }
    _held.clear();
  }
}

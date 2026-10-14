// Harness: in-memory TestSession (never exported by package:tui).
part of '../tui.dart';

/// In-memory test harness: drive a state-driven app without a terminal.
final class TestSession<S> {
  TestSession._(this._s, this._out);

  final _Session<S> _s;
  final StringBuffer _out;

  /// Feed raw input bytes for the next [pump].
  void bytes(List<int> b) => _s._pending.addAll(b);

  /// Process pending input, settle handlers, redraw if dirty.
  /// Returns true when a paint wrote output.
  Future<bool> pump() async {
    var painted = false;
    await _s._zoneRun(() async {
      _s._pollInput();
      await _s._settleForTest();
      if (_s._dirty) {
        _s._draw();
        painted = _paint();
        _s._dirty = false;
      }
    });
    return painted;
  }

  bool _paint() {
    return _s._paintTo(_out);
  }

  /// The current screen row as text (wide continuation cells skipped).
  String row(int y) {
    final grid = _s._grid;
    if (y < 0 || y >= grid.length) return '';
    final buf = StringBuffer();
    for (final c in grid[y]) {
      if (c.width == 0) continue;
      buf.write(c.ch.isEmpty ? ' ' : c.ch);
    }
    return buf.toString().trimRight();
  }

  /// Run until [quit] (or a fatal [Error], rethrown).
  Future<S> run() async {
    await _s._zoneRun(() async {
      _s._draw();
      _paint();
      _s._dirty = false;
    });
    while (!_s._quitFlag) {
      if (_s._fatal != null) {
        final e = _s._fatal!;
        final st = _s._fatalStack ?? StackTrace.empty;
        Error.throwWithStackTrace(e, st);
      }
      await _s._zoneRun(() async {
        _s._pollInput();
        await _s._settleForTest();
        if (_s._dirty) {
          _s._draw();
          _paint();
          _s._dirty = false;
        }
      });
      if (_s._pending.isEmpty && _s._activeH == 0 && !_s._dirty && !_s._quitFlag) {
        break;
      }
    }
    if (_s._fatal != null) {
      final e = _s._fatal!;
      final st = _s._fatalStack ?? StackTrace.empty;
      Error.throwWithStackTrace(e, st);
    }
    return _s._state;
  }

  /// The terminal changed size: repaint everything at [width]×[height] and
  /// fire `resize`.
  void resize(int width, int height) {
    _s._w = width;
    _s._h = height;
    _s._repaint = true;
    _s._fireLifecycle('resize');
    _s._dirty = true;
  }

  /// The id of the focused widget (the widget object itself for fields and lists).
  Object? get focus => _s._focusId;

  /// Distinct styles in the packing table.
  int get styleCount => _s._styles.length;
  bool get quitRequested => _s._quitFlag;
  S get state => _s._state;

  /// Everything written to the terminal so far (frames, OSC).
  String get output => _out.toString();

  /// Release the shared Console bridge slot.
  void close() {
    if (identical(term.TuiBridge.current, _s)) {
      term.TuiBridge.current = null;
    }
  }
}

/// Build an in-memory [TestSession] (no terminal required); everything the
/// session writes lands in [TestSession.output]. [env] sets the colour and charset capabilities as
/// `TERM`/`COLORTERM`/`NO_COLOR`/`LANG` would. Call [TestSession.close] at the end to release the
/// shared Console bridge slot.
TestSession<S> testSession<S>(
  S state,
  Screen Function(S state, App<S> app) screen, {
  int width = 80,
  int height = 24,
  Color? accent,
  Map<String, String>? env,
}) {
  final sink = StringBuffer();
  final s = _Session<S>(state, screen, out: sink.write, size: () => (width, height), accent: accent);
  s._w = width;
  s._h = height;
  s._grid = List.generate(height, (_) => List.filled(width, _Cell.blank));
  s._testMode = true;
  s._caps = env == null ? _fallbackCaps : term.TerminalCaps.of(env, hasTerminal: false);
  late Zone z;
  runZoned(() {
    z = Zone.current;
  }, zoneSpecification: s._spec());
  s._zone = z;
  term.TuiBridge.current = s;
  return TestSession<S>._(s, sink);
}

extension on _Session<dynamic> {
  Future<void> _settleForTest() async {
    for (var k = 0; k < 200; k++) {
      await Future<void>.delayed(Duration.zero);
      if (_activeH == 0) {
        await Future<void>.delayed(Duration.zero);
        if (_activeH == 0) return;
      }
    }
  }
}

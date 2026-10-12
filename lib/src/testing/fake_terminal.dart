import 'dart:collection';

import '../tui/buffer.dart';
import '../tui/events.dart';
import '../tui/term.dart';
import '../tui/width.dart';

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
  /// The recording backend this terminal drives.
  final FakeBackend backend;

  FakeTerminal({int width = 80, int height = 24, ColorLevel colorLevel = ColorLevel.truecolor})
    : this._with(FakeBackend(width, height, colorLevel));

  FakeTerminal._with(this.backend) : super.forTesting(backend);

  /// Whether [close] ran on the backend.
  bool get closed => backend.closed;

  /// Frames painted so far (cell grids).
  List<Grid> get frames => backend.frames;

  /// Changed-cell counts per frame (the diff budget tests assert on).
  List<int> get changes => backend.changes;

  /// Raw ANSI bytes written so far.
  String get bytes => backend.bytes;

  /// The latest frame as text rows.
  List<String> get snapshot => frames.isEmpty ? List.filled(h, '') : frames.last.rows;

  /// Injects a key press.
  void send(String name, {bool ctrl = false, bool alt = false, bool shift = false}) =>
      backend.inject(KeyPress(name, ctrl: ctrl, alt: alt, shift: shift));

  /// Injects typed text, one key per grapheme cluster (a surrogate pair or
  /// emoji sequence stays one key).
  void type(String text) {
    for (final cluster in clusters(text)) {
      backend.inject(KeyPress(cluster));
    }
  }

  /// Injects ^C the way the native backend delivers it: as [Interrupt], never
  /// as a key.
  void interrupt() => backend.inject(const Interrupt());

  /// Injects a bracketed paste.
  void paste(String text) => backend.inject(Paste(text));

  /// Injects a pointer press (tap).
  void tap(int x, int y, {int button = 0}) => backend.inject(Pointer(x, y, PointerKind.press, button: button));

  /// Resizes the screen: the next poll answers [Resize], the next draw is whole.
  void resize(int width, int height) => backend.resize(width, height);
}

/// The recording backend behind [FakeTerminal]: frames, diff counts and bytes
/// are kept; injected events answer polls.
final class FakeBackend implements TermBackend {
  int _width, _height;
  final ColorLevel _colorLevel;
  final Queue<TuiEvent> _injected = Queue();
  final List<Grid> frames = [];
  final List<int> changes = [];
  final StringBuffer _bytes = StringBuffer();
  bool closed = false;
  void Function()? _wake;

  FakeBackend(this._width, this._height, this._colorLevel);

  @override
  set onEvent(void Function()? wake) => _wake = wake;

  @override
  (int, int) get size => (_width, _height);

  @override
  ColorLevel get colorLevel => _colorLevel;

  @override
  void show(Grid grid, List<Change> changes, String ansi) {
    frames.add(grid);
    this.changes.add(changes.length);
    _bytes.write(ansi);
  }

  String get bytes => _bytes.toString();

  @override
  void cursor(int? col, int? row) {}

  @override
  TuiEvent? tryTake() => _injected.isEmpty ? null : _injected.removeFirst();

  /// Queues [ev] for the next poll (waking it).
  void inject(TuiEvent ev) {
    _injected.add(ev);
    _wake?.call();
  }

  /// Resizes and queues the [Resize] event (waking a waiting poll).
  void resize(int width, int height) {
    _width = width;
    _height = height;
    _injected.add(Resize(width, height));
    _wake?.call();
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

/// The terminal both UIs share: keys and the raw terminal, `Style` and the `Palette`, the
/// `Tally` that models work in progress, the builder views and the `Choice` list model. `cli`
/// and `tui` each import it, so a script that imports only `core` compiles none of it.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'core.dart';

/// What an app hears: from the terminal a [KeyPress], [Char], [Paste], [Mouse] or [Resize], and its
/// own messages ([M], from `app.send`) as a [Sent]. Sealed, so a `switch` over it is exhaustive.
///
/// {@category CLI}
sealed class TuiEvent<M> {
  const TuiEvent();
}

/// An app's own message, as `app.send` and `app.listen` deliver it.
///
/// {@category CLI}
final class Sent<M> extends TuiEvent<M> {
  final M message;

  const Sent(this.message);

  @override
  bool operator ==(Object other) => other is Sent<M> && other.message == message;

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() => 'Sent($message)';
}

/// The terminal is now [width] × [height]; the next frame is already drawn at that size.
///
/// {@category CLI}
final class Resize extends TuiEvent<Never> {
  final int width, height;

  const Resize(this.width, this.height);

  @override
  bool operator ==(Object other) => other is Resize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'Resize($width×$height)';
}

/// A key that is not text: arrows, Enter, F1–F12, and Ctrl+letter (`const KeyPress('c', ctrl: true)`).
///
/// {@category CLI}
final class KeyPress extends TuiEvent<Never> {
  /// `up`, `enter`, `f5`, … or the letter of a Ctrl combination.
  final String name;
  final bool ctrl, alt, shift;

  const KeyPress(this.name, {this.ctrl = false, this.alt = false, this.shift = false});

  static const up = KeyPress('up');
  static const down = KeyPress('down');
  static const left = KeyPress('left');
  static const right = KeyPress('right');
  static const home = KeyPress('home');
  static const end = KeyPress('end');
  static const pageUp = KeyPress('pageUp');
  static const pageDown = KeyPress('pageDown');
  static const insert = KeyPress('insert');
  static const delete = KeyPress('delete');
  static const enter = KeyPress('enter');
  static const tab = KeyPress('tab');
  static const backTab = KeyPress('tab', shift: true);
  static const backspace = KeyPress('backspace');
  static const esc = KeyPress('esc');

  /// Function key [n], 1–12; match it as `const KeyPress('f5')`.
  factory KeyPress.f(int n, {bool ctrl = false, bool alt = false, bool shift = false}) =>
      KeyPress('f$n', ctrl: ctrl, alt: alt, shift: shift);

  @override
  bool operator ==(Object other) =>
      other is KeyPress && other.name == name && other.ctrl == ctrl && other.alt == alt && other.shift == shift;

  @override
  int get hashCode => Object.hash(name, ctrl, alt, shift);

  @override
  String toString() => '${ctrl ? 'ctrl+' : ''}${alt ? 'alt+' : ''}${shift ? 'shift+' : ''}$name';
}

/// Typed text: one character (a grapheme's first code point and what joins it), maybe with Alt.
///
/// {@category CLI}
final class Char extends TuiEvent<Never> {
  final String char;
  final bool alt;

  const Char(this.char, {this.alt = false});

  @override
  bool operator ==(Object other) => other is Char && other.char == char && other.alt == alt;

  @override
  int get hashCode => Object.hash(char, alt);

  @override
  String toString() => '${alt ? 'alt+' : ''}$char';
}

/// Text pasted in one piece (bracketed paste), newlines and all.
///
/// {@category CLI}
final class Paste extends TuiEvent<Never> {
  final String text;

  const Paste(this.text);

  @override
  bool operator ==(Object other) => other is Paste && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'Paste(${text.length} chars)';
}

/// What a [Mouse] event did.
///
/// {@category CLI}
enum MouseKind { press, release, drag, move, wheelUp, wheelDown }

/// A click, drag or wheel turn at column [x], row [y] (0-based, of the screen).
///
/// Only with `mouse: true` on `Tui.run`, which is full-screen.
///
/// {@category CLI}
final class Mouse extends TuiEvent<Never> {
  final int x, y;
  final MouseKind kind;

  /// 0 left, 1 middle, 2 right.
  final int button;
  final bool ctrl, alt, shift;

  const Mouse(this.x, this.y, this.kind, {this.button = 0, this.ctrl = false, this.alt = false, this.shift = false});

  @override
  bool operator ==(Object other) =>
      other is Mouse &&
      other.x == x &&
      other.y == y &&
      other.kind == kind &&
      other.button == button &&
      other.ctrl == ctrl &&
      other.alt == alt &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(x, y, kind, button, ctrl, alt, shift);

  @override
  String toString() => 'Mouse(${kind.name} $x,$y)';
}

/// What takes the focus: keys reach it before an app's `update`, Tab moves between the ones on
/// screen, a click gives it. `Field`, `Scroll`, `Log` and [Choice] are; a custom widget mixes it
/// in and calls `canvas.focus(this)` when it paints.
///
/// ```dart
/// final class Dial extends Widget with Focusable {
///   int value = 0;
///   @override
///   bool handle(TuiEvent<Object?> event) => switch (event) {
///     KeyPress.up => (value++, true).$2,
///     _ => false,
///   };
///   @override
///   void paint(Canvas canvas) => canvas.text(0, 0, '$value', canvas.focus(this) ? canvas.palette.accent : null);
/// }
/// ```
///
/// {@category CLI}
mixin Focusable {
  /// Handles a key, character or paste; `true` when it used it, so `update` does not see it.
  bool handle(TuiEvent<Object?> event) => false;

  /// A click or a wheel turn at [x], [y] inside it.
  void mouse(Mouse event, int x, int y) {}
}

/// Not API: the key reader `cli` and `tui` share, and the terminal facts both draw by.
///
/// An instance turns a terminal's bytes into events: [add] each chunk, [cancel] at the end; a
/// lone ESC is the Esc key once nothing follows it for 30 ms.
final class TerminalBridge {
  final void Function(List<TuiEvent<Never>> events) _onEvents;
  final _Decoder _decoder;
  Timer? _esc;

  /// [position] hears a cursor position report (1-based row and column), [kitty] the answer
  /// that the kitty keyboard protocol is spoken; neither is an event.
  TerminalBridge(this._onEvents, {void Function(int row, int column)? position, void Function()? kitty})
    : _decoder = _Decoder(position, kitty);

  void add(List<int> bytes) {
    _esc?.cancel();
    _onEvents(_decoder.add(bytes));
    if (_decoder.isWaiting) _esc = Timer(const Duration(milliseconds: 30), () => _onEvents(_decoder.flush()));
  }

  void cancel() => _esc?.cancel();

  /// What a signal caught while the terminal is open runs: the reader that is in charge of it.
  static void Function()? interrupted;

  /// The `Tui` app on screen, while one runs: a console display then draws no live region.
  static Object? app;

  /// The scope's terminal (`Io.scope(terminal:)`), else the controlling one, or `null` when
  /// there is none.
  static Terminal? connect() => IoBridge.terminal ?? (Platform.isWindows ? _WinConsole.connect() : _Tty.connect());

  /// How a value is named where it is shown: an enum by its `name`, a duration humanized, a date
  /// in ISO 8601, a row (a map) by its cells; a list's default label and a prompt's hint.
  static String label(Object? value) => switch (value) {
    Enum() => value.name,
    Duration() => value.humanized,
    DateTime() => value.toIso8601String(),
    Map() => value.values.map((v) => v ?? '').join(' '),
    _ => '$value',
  };

  /// Whether [t] is the process's terminal, where ^C can be raised as the SIGINT it would be.
  static bool isTty(Terminal t) => t is _Tty || t is _WinConsole;

  /// ^C, which raw mode reads as a byte: on the process's own terminal it is raised as the SIGINT
  /// it would have been (a `Cli` then leaves through its cleanups with 130, and the terminal's
  /// watch ends the reader); elsewhere [interrupt] runs.
  static void ctrlC(Terminal term, void Function() interrupt) {
    if (isTty(term) && !Platform.isWindows && Process.killPid(pid, ProcessSignal.sigint)) return;
    interrupt();
  }

  /// Whether a picker's filter [query] (lowercased) finds [label] (lowercased): a substring, else
  /// a subsequence. Without building the ranges: it runs on every item at every key.
  static bool matches(String label, String query) {
    if (label.contains(query)) return true;
    var q = 0;
    for (var i = 0; i < label.length && q < query.length; i++) {
      if (label.codeUnitAt(i) == query.codeUnitAt(q)) q++;
    }
    return q == query.length;
  }

  /// Colours the process's terminal shows, from the environment: `NO_COLOR` or a scope's
  /// `color: false` leaves attributes only (0). A scope's terminal shows its own.
  static int depth() {
    if (IoBridge.color == false) return 0;
    if (IoBridge.terminal case final t?) return t.colors;
    if (IoBridge.color == null && Env.has('NO_COLOR')) return 0;
    final ct = Env.get<String>('COLORTERM', or: '');
    if (ct.contains('truecolor') || ct.contains('24bit')) return 1 << 24;
    final term = Env.get<String>('TERM', or: '');
    if (term == 'dumb') return 0;
    return term.contains('256') ? 256 : 16;
  }

  /// Whether the process's terminal draws Unicode: not the Linux console, a non-UTF-8 locale, or
  /// the Windows console outside Windows Terminal.
  static final bool unicode = () {
    String first(List<String> keys) {
      for (final key in keys) {
        final value = Env.get<String>(key, or: '');
        if (value.isNotEmpty) return value;
      }
      return 'UTF-8';
    }

    return Platform.isWindows
        ? Env.get<String>('WT_SESSION', or: '').isNotEmpty ||
              Env.get<String>('TERM_PROGRAM', or: '').isNotEmpty ||
              _WinConsole._isUtf8CodePage()
        : Env.get<String>('TERM', or: '') != 'linux' &&
              first(const ['LC_ALL', 'LC_CTYPE', 'LANG']).toLowerCase().replaceAll('-', '').contains('utf8');
  }();

  /// Whether what is drawn here draws Unicode: the scope's terminal's answer, else [unicode].
  static bool get drawsUnicode => IoBridge.terminal?.unicode ?? unicode;

  /// [palette] as it is drawn on a terminal that does ([unicode]) or does not draw Unicode: ASCII
  /// under its unset glyphs there.
  static Palette drawable(Palette palette, {bool? unicode}) =>
      (unicode ?? drawsUnicode) ? palette : palette._over(Palette.ascii);

  /// [palette], or an [ArgumentError] naming what cannot be drawn.
  static Palette checked(Palette palette) {
    if (palette.frames.isEmpty) throw ArgumentError.value(palette.frames, 'frames', 'Invalid frames: none');
    if (palette.interval <= Duration.zero) {
      throw ArgumentError.value(palette.interval, 'interval', 'Invalid interval, expected more than zero');
    }
    return palette;
  }

  /// [palette] laid over [base]: what a nested theme's unset tokens take.
  static Palette over(Palette palette, Palette base) => palette._over(base);

  /// Where [choice] was drawn: what a widget keeps between frames.
  static ChoiceLayout layout(Choice<Object?> choice) => choice._layout;

  /// The sequence that sets exactly [style] from a reset, at [depth] colours.
  static String sgrOf(Style style, int depth) => style._sgr(depth);

  /// Set while a line is built for a sink that drops escapes: [Style.call] then writes none.
  static bool unstyled = false;

  /// What [build] returns with styling off: for a sink that drops escapes anyway.
  static T plain<T>(T Function() build) {
    final was = unstyled;
    unstyled = true;
    try {
      return build();
    } finally {
      unstyled = was;
    }
  }

  /// [text] as runs of plain text, each in the style its SGR escapes set: what [Style.call]
  /// wrote, read back. Other escapes are dropped, a hyperlink's text kept.
  static List<(String, Style)> runs(String text) {
    if (!text.contains('\x1b')) return [(text, Style.none)];
    final out = <(String, Style)>[];
    Color? fg, bg;
    bool? bold, dim, italic, underline, reverse;
    var at = 0;
    void flush(int end) {
      if (end > at) {
        out.add((
          text.substring(at, end),
          Style(fg: fg, bg: bg, bold: bold, dim: dim, italic: italic, underline: underline, reverse: reverse),
        ));
      }
    }

    for (final m in TextBridge.escape.allMatches(text)) {
      flush(m.start);
      at = m.end;
      if (m[2] != 'm') continue;
      final codes = [for (final c in m[1]!.split(RegExp('[;:]'))) int.tryParse(c) ?? 0];
      for (var i = 0; i < codes.length; i++) {
        switch (codes[i]) {
          case 0:
            fg = bg = bold = dim = italic = underline = reverse = null;
          case 1:
            bold = true;
          case 2:
            dim = true;
          case 3:
            italic = true;
          case 4:
            underline = true;
          case 7:
            reverse = true;
          case 22:
            bold = dim = false;
          case 23:
            italic = false;
          case 24:
            underline = false;
          case 27:
            reverse = false;
          case final c && (>= 30 && <= 37):
            fg = Color(c - 30);
          case final c && (>= 90 && <= 97):
            fg = Color(c - 82);
          case final c && (>= 40 && <= 47):
            bg = Color(c - 40);
          case final c && (>= 100 && <= 107):
            bg = Color(c - 92);
          case 39:
            fg = null;
          case 49:
            bg = null;
          case final c && (38 || 48):
            final Color? colour;
            if (i + 2 < codes.length && codes[i + 1] == 5) {
              colour = Color(codes[i + 2] & 255);
              i += 2;
            } else if (i + 4 < codes.length && codes[i + 1] == 2) {
              colour = Color.rgb(codes[i + 2], codes[i + 3], codes[i + 4]);
              i += 4;
            } else {
              colour = null;
            }
            c == 38 ? fg = colour : bg = colour;
        }
      }
    }
    flush(text.length);
    return out;
  }

  /// The SGR parameters of a colour — [kind] 0 named (0–15), 1 palette (0–255), 2 RGB
  /// (0xRRGGBB) — as foreground, or background with [bg], at [depth] colours: the nearest it shows.
  static String sgr(int kind, int value, int depth, {bool bg = false}) {
    var (k, v) = (kind, value);
    if (k == 2 && depth < 1 << 24) (k, v) = (1, _rgbTo256(v));
    if (k == 1 && depth < 256) (k, v) = (0, _paletteTo16(v));
    if (k == 1 && v < 16) k = 0;
    return switch (k) {
      0 => '${(v < 8 ? 30 : 82) + v + (bg ? 10 : 0)}',
      1 => '${bg ? 48 : 38};5;$v',
      _ => '${bg ? 48 : 38};2;${v >> 16};${v >> 8 & 255};${v & 255}',
    };
  }

  static int _rgbTo256(int v) {
    final (r, g, b) = (v >> 16, v >> 8 & 255, v & 255);
    if (r == g && g == b) {
      if (r < 8) return 16;
      if (r > 248) return 231;
      return 232 + ((r - 8) * 24 / 247).round();
    }
    int c(int x) => x < 48 ? 0 : (x < 115 ? 1 : (x - 35) ~/ 40);
    return 16 + 36 * c(r) + 6 * c(g) + c(b);
  }

  static const _basic = [
    (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205), (0, 205, 205), //
    (229, 229, 229), (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0), (92, 92, 255), //
    (255, 0, 255), (0, 255, 255), (255, 255, 255),
  ];

  static int _paletteTo16(int i) {
    if (i < 16) return i;
    final (r, g, b) = i >= 232
        ? (8 + (i - 232) * 10, 8 + (i - 232) * 10, 8 + (i - 232) * 10)
        : (_cube((i - 16) ~/ 36), _cube((i - 16) ~/ 6 % 6), _cube((i - 16) % 6));
    var best = 0, bestD = 1 << 30;
    for (final (n, (br, bg, bb)) in _basic.indexed) {
      final d = (r - br) * (r - br) + (g - bg) * (g - bg) + (b - bb) * (b - bb);
      if (d < bestD) (best, bestD) = (n, d);
    }
    return best;
  }

  static int _cube(int c) => c == 0 ? 0 : 55 + c * 40;
}

/// The process's terminal, through `/dev/tty`: input still works when stdin is a pipe, and
/// nothing reaches stdout, so `app | next` and `app > out` carry only what the app prints.
final class _Tty implements Terminal {
  final RandomAccessFile _out;
  String? _saved;

  /// The keys, read by a `cat` of the terminal: a read in this process cannot be stopped once
  /// the modes are restored, and would hold the exit until Enter; a child is killed mid-read.
  Process? _reader;
  int _readerPid = -1;
  StreamController<List<int>> _input = StreamController.broadcast();
  final StreamController<void> _resized = StreamController.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];
  (int, int)? _size;

  _Tty._(this._out);

  /// The controlling terminal, or `null` when there is none (or on Windows).
  static _Tty? connect() {
    if (Platform.isWindows) return null;
    try {
      return _Tty._(File('/dev/tty').openSync(mode: FileMode.writeOnly));
    } catch (_) {
      return null;
    }
  }

  static String _stty(List<String> args) {
    final r = Process.runSync('stty', [Platform.isMacOS ? '-f' : '-F', '/dev/tty', ...args]);
    if (r.exitCode != 0) throw StateError('stty ${args.join(' ')}: ${r.stderr}'.trim());
    return '${r.stdout}'.trim();
  }

  (int, int) get _dims => _size ??=
      _terminalSize() ??
      () {
        try {
          final rc = _stty(['size']).split(' ').map(int.parse).toList();
          return (rc[1], rc[0]);
        } catch (_) {
          return (80, 24);
        }
      }();

  /// The size stdout or stderr reports, when either is the terminal: no process to ask.
  static (int, int)? _terminalSize() {
    for (final s in [stdout, stderr]) {
      try {
        if (s.hasTerminal) return (s.terminalColumns, s.terminalLines);
      } catch (_) {} // no size from this terminal: the defaults stand
    }
    return null;
  }

  @override
  int get width => _dims.$1;

  @override
  int get height => _dims.$2;

  @override
  int get colors => TerminalBridge.depth();

  @override
  bool get unicode => TerminalBridge.unicode;

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Stream<void> get resized => _resized.stream;

  /// One process from open to close: it prints the saved modes, sets raw mode, prints the
  /// reader's pid, then reads the keys — a `cat` it kills when our end of its stdin closes, so
  /// the reader dies with this process even after `kill -9` and never reads the shell's input.
  /// `-isig`: ^C and ^Z arrive as keys; `min 1 time 0`: each key is read as it comes, and cat
  /// would take a read of nothing for the end of input.
  static const _session = r'''
stty -g < /dev/tty >&2 || exit 1
stty -icanon -echo -isig -ixon -iexten min 1 time 0 < /dev/tty || exit 1
cat /dev/tty & echo $! >&2
cat >/dev/null
kill $!
''';

  @override
  Future<void> open() async {
    if (_input.isClosed) _input = StreamController.broadcast();
    final reader = _reader = await Process.start('/bin/sh', ['-c', _session]);
    final lines = <String>[];
    final ready = Completer<void>();
    reader.stdout.listen(_input.add);
    reader.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (lines.length < 2) lines.add(line);
      if (lines.length == 2 && !ready.isCompleted) ready.complete();
    }, onDone: () => ready.isCompleted ? null : ready.complete());
    await ready.future;
    if (lines.length < 2 || int.tryParse(lines[1]) == null) {
      _reader = null;
      throw StateError('stty cannot set up /dev/tty: ${lines.join(' ')}'.trim());
    }
    _saved = lines[0];
    _readerPid = int.parse(lines[1]);
    void interrupt(ProcessSignal _) => TerminalBridge.interrupted?.call();
    _subs.addAll([
      ProcessSignal.sigwinch.watch().listen((_) {
        _size = null;
        _resized.add(null);
      }),
      ProcessSignal.sigint.watch().listen(interrupt),
      ProcessSignal.sigterm.watch().listen(interrupt),
    ]);
  }

  @override
  void close() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    // Before the modes are restored, so it never reads a line meant for what runs next.
    if (_readerPid > 0) Process.killPid(_readerPid, ProcessSignal.sigkill);
    _reader?.stdin.close().ignore();
    _reader = null;
    _readerPid = -1;
    if (_saved case final saved?) {
      _saved = null;
      try {
        _stty([saved]);
      } catch (_) {} // best-effort: the tty may be gone already
    }
    try {
      _out.closeSync();
    } catch (_) {} // best-effort: the tty may be gone already
  }

  @override
  void write(String data) {
    try {
      _out.writeFromSync(utf8.encode(data));
    } catch (_) {} // best-effort: the tty may be gone already
  }
}

/// The Windows console, using SetConsoleMode and raw VT sequences.
final class _WinConsole implements Terminal {
  static final _k32 = DynamicLibrary.open('kernel32.dll');
  static final _getStdHandle = _k32.lookupFunction<Pointer<Void> Function(Int32), Pointer<Void> Function(int)>(
    'GetStdHandle',
  );
  static final _getConsoleMode = _k32
      .lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint32>), int Function(Pointer<Void>, Pointer<Uint32>)>(
        'GetConsoleMode',
      );
  static final _setConsoleMode = _k32
      .lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>('SetConsoleMode');
  static final _getConsoleOutputCP = _k32.lookupFunction<Uint32 Function(), int Function()>('GetConsoleOutputCP');
  static final _localAlloc = _k32
      .lookupFunction<Pointer<Void> Function(Uint32, IntPtr), Pointer<Void> Function(int, int)>('LocalAlloc');
  static final _localFree = _k32
      .lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');

  static bool _isUtf8CodePage() {
    try {
      return _getConsoleOutputCP() == 65001;
    } catch (_) {
      // best-effort code page check
      return false;
    }
  }

  int _savedInMode = 0;
  int _savedErrMode = 0;
  bool _isOpen = false;
  Isolate? _readerIsolate;
  ReceivePort? _receivePort;
  StreamController<List<int>> _input = StreamController.broadcast();
  final StreamController<void> _resized = StreamController.broadcast();
  Timer? _resizeTimer;
  (int, int)? _lastDims;

  _WinConsole._();

  static _WinConsole? connect() {
    if (!Platform.isWindows) return null;
    final hIn = _getStdHandle(-10);
    final hErr = _getStdHandle(-12);
    if (hIn.address == 0 || hErr.address == 0) return null;
    final mode = _localAlloc(0x0040, 4).cast<Uint32>();
    try {
      if (_getConsoleMode(hIn, mode) == 0) return null;
      if (_getConsoleMode(hErr, mode) == 0) return null;
      return _WinConsole._();
    } catch (_) {
      // not a console
      return null;
    } finally {
      _localFree(mode.cast());
    }
  }

  (int, int) get _dims {
    final size = _Tty._terminalSize();
    if (size != null) return size;
    return (80, 24);
  }

  @override
  int get width => _dims.$1;

  @override
  int get height => _dims.$2;

  @override
  int get colors => TerminalBridge.depth();

  @override
  bool get unicode => TerminalBridge.unicode;

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Stream<void> get resized => _resized.stream;

  @override
  Future<void> open() async {
    if (_isOpen) return;
    if (_input.isClosed) _input = StreamController.broadcast();
    final hIn = _getStdHandle(-10);
    final hErr = _getStdHandle(-12);
    final modeIn = _localAlloc(0x0040, 4).cast<Uint32>();
    final modeErr = _localAlloc(0x0040, 4).cast<Uint32>();
    try {
      if (_getConsoleMode(hIn, modeIn) != 0) {
        _savedInMode = modeIn.value;
        // ENABLE_VIRTUAL_TERMINAL_INPUT (0x0200) | ENABLE_WINDOW_INPUT (0x0008)
        // Disable ENABLE_PROCESSED_INPUT (0x0001) | ENABLE_LINE_INPUT (0x0002) | ENABLE_ECHO_INPUT (0x0004)
        final rawIn = (_savedInMode | 0x0200 | 0x0008) & ~(0x0001 | 0x0002 | 0x0004);
        _setConsoleMode(hIn, rawIn);
      }
      if (_getConsoleMode(hErr, modeErr) != 0) {
        _savedErrMode = modeErr.value;
        // ENABLE_PROCESSED_OUTPUT (0x0001) | ENABLE_WRAP_AT_EOL_OUTPUT (0x0002) | ENABLE_VIRTUAL_TERMINAL_PROCESSING (0x0004)
        final rawErr = _savedErrMode | 0x0001 | 0x0002 | 0x0004;
        _setConsoleMode(hErr, rawErr);
      }
    } finally {
      _localFree(modeIn.cast());
      _localFree(modeErr.cast());
    }
    _isOpen = true;

    final port = _receivePort = ReceivePort();
    _readerIsolate = await Isolate.spawn(_readConsoleStdin, port.sendPort, debugName: 'WinConsole.reader');
    port.listen((message) {
      if (message is! List<int>) return;
      // ^C is the interrupt where something is in charge of it, and then not a key as well.
      final interrupt = TerminalBridge.interrupted;
      final keys = interrupt != null && message.contains(3)
          ? [
              for (final b in message)
                if (b != 3) b,
            ]
          : message;
      if (!identical(keys, message)) interrupt!();
      if (keys.isNotEmpty && !_input.isClosed) _input.add(keys);
    });

    _lastDims = _dims;
    _resizeTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final current = _dims;
      if (current != _lastDims) {
        _lastDims = current;
        if (!_resized.isClosed) _resized.add(null);
      }
    });
  }

  @override
  void close() {
    _resizeTimer?.cancel();
    _resizeTimer = null;
    if (_readerIsolate != null) {
      _readerIsolate!.kill(priority: Isolate.immediate);
      _readerIsolate = null;
    }
    _receivePort?.close();
    _receivePort = null;
    if (_isOpen) {
      _isOpen = false;
      final hIn = _getStdHandle(-10);
      final hErr = _getStdHandle(-12);
      if (_savedInMode != 0) {
        _setConsoleMode(hIn, _savedInMode);
        _savedInMode = 0;
      }
      if (_savedErrMode != 0) {
        _setConsoleMode(hErr, _savedErrMode);
        _savedErrMode = 0;
      }
    }
  }

  @override
  void write(String data) {
    try {
      stderr.write(data);
    } catch (_) {} // best-effort console write
  }
}

void _readConsoleStdin(SendPort send) {
  final k32 = DynamicLibrary.open('kernel32.dll');
  final getStdHandle = k32.lookupFunction<Pointer<Void> Function(Int32), Pointer<Void> Function(int)>('GetStdHandle');
  final readFile = k32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
      >('ReadFile');
  final localAlloc = k32.lookupFunction<Pointer<Void> Function(Uint32, IntPtr), Pointer<Void> Function(int, int)>(
    'LocalAlloc',
  );
  final localFree = k32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>(
    'LocalFree',
  );

  final hIn = getStdHandle(-10);
  final buf = localAlloc(0x0040, 1024).cast<Uint8>();
  final read = localAlloc(0x0040, 4).cast<Uint32>();
  try {
    while (true) {
      if (readFile(hIn, buf, 1024, read, nullptr) == 0) break;
      final count = read.value;
      if (count > 0) {
        send.send(Uint8List.fromList(buf.asTypedList(count)));
      }
    }
  } finally {
    localFree(buf.cast());
    localFree(read.cast());
  }
}

/// Bytes in, events out. Holds a partial sequence until the next chunk, or until [flush] — the
/// ESC timeout — says a lone ESC was the key.
final class _Decoder {
  final void Function(int row, int column)? _position;
  final void Function()? _kitty;
  final List<int> _pending = [];
  final List<int> _paste = [];
  bool _inPaste = false;

  _Decoder([this._position, this._kitty]);

  /// Whether a lone ESC (or a sequence it starts, cut off) waits on more bytes.
  bool get isWaiting => _pending.isNotEmpty && _pending.first == 0x1b && !_inPaste;

  List<TuiEvent<Never>> add(List<int> bytes) {
    _pending.addAll(bytes);
    final out = <TuiEvent<Never>>[];
    var i = 0;
    while (i < _pending.length) {
      final n = _inPaste ? _pasteStep(i, out) : _step(i, out);
      if (n == 0) break;
      i += n;
    }
    _pending.removeRange(0, i);
    return out;
  }

  /// What waits, read as typed: a lone ESC is Esc, a cut-off sequence is its bytes. Only an ESC
  /// times out: a character cut mid-way, or the end of a paste, waits for the rest.
  List<TuiEvent<Never>> flush() {
    if (_pending.isEmpty || _inPaste || _pending.first != 0x1b) return const [];
    final bytes = List.of(_pending);
    _pending.clear();
    if (bytes.length == 1) return const [KeyPress.esc];
    final rest = _Decoder().add(bytes.sublist(1));
    return [if (rest.isEmpty) KeyPress.esc, for (final e in rest) _alt(e)];
  }

  static TuiEvent<Never> _alt(TuiEvent<Never> e) => switch (e) {
    Char(:final char) => Char(char, alt: true),
    KeyPress(:final name, :final ctrl, :final shift) => KeyPress(name, ctrl: ctrl, alt: true, shift: shift),
    _ => e,
  };

  int _pasteStep(int i, List<TuiEvent<Never>> out) {
    const end = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]; // ESC [ 2 0 1 ~
    final b = _pending[i];
    if (b == 0x1b) {
      for (var k = 0; k < end.length; k++) {
        if (i + k >= _pending.length) return 0;
        if (_pending[i + k] != end[k]) {
          _paste.add(b);
          return 1;
        }
      }
      _inPaste = false;
      out.add(Paste(utf8.decode(_paste, allowMalformed: true).replaceAll('\r\n', '\n').replaceAll('\r', '\n')));
      _paste.clear();
      return end.length;
    }
    _paste.add(b);
    return 1;
  }

  /// Decodes one event at [i]; returns the bytes it used, or 0 when it needs more.
  int _step(int i, List<TuiEvent<Never>> out) {
    final b = _pending[i];
    if (b == 0x1b) return _escape(i, out);
    if (b < 0x80) {
      out.add(_byte(b));
      return 1;
    }
    final len = b >= 0xf0 ? 4 : (b >= 0xe0 ? 3 : (b >= 0xc0 ? 2 : 1));
    // A byte that does not continue the character ends it, malformed; the end of a read waits.
    var n = 1;
    while (n < len && i + n < _pending.length && _pending[i + n] & 0xc0 == 0x80) {
      n++;
    }
    if (n < len && i + n == _pending.length) return 0;
    final text = utf8.decode(_pending.sublist(i, i + n), allowMalformed: true);
    // A combining mark or joiner belongs to the character before it.
    if (out.isNotEmpty && out.last is Char && IoBridge.runeWidth(text.runes.first) == 0) {
      final last = out.removeLast() as Char;
      out.add(Char(last.char + text, alt: last.alt));
    } else {
      out.add(Char(text));
    }
    return n;
  }

  static TuiEvent<Never> _byte(int b) => switch (b) {
    0x0d || 0x0a => KeyPress.enter,
    0x09 => KeyPress.tab,
    0x7f || 0x08 => KeyPress.backspace,
    0x00 => const KeyPress(' ', ctrl: true),
    < 0x1b => KeyPress(String.fromCharCode(b + 0x60), ctrl: true),
    < 0x20 => KeyPress(String.fromCharCode(b + 0x40), ctrl: true),
    _ => Char(String.fromCharCode(b)),
  };

  /// The keys an SS3 (`ESC O x`) or CSI (`ESC [ … x`) sequence names by its final byte.
  static const _finals = {
    0x41: 'up', 0x42: 'down', 0x43: 'right', 0x44: 'left', 0x48: 'home', 0x46: 'end', //
    0x50: 'f1', 0x51: 'f2', 0x52: 'f3', 0x53: 'f4',
  };

  int _escape(int i, List<TuiEvent<Never>> out) {
    if (i + 1 >= _pending.length) return 0;
    final next = _pending[i + 1];
    if (next == 0x5b) return _csi(i, out);
    if (next == 0x4f) {
      // SS3: ESC O x
      if (i + 2 >= _pending.length) return 0;
      if (_finals[_pending[i + 2]] case final name?) out.add(KeyPress(name));
      return 3;
    }
    if (next == 0x1b) {
      out.add(KeyPress.esc);
      return 1;
    }
    // ESC then a key: Alt+key.
    final inner = <TuiEvent<Never>>[];
    final used = _step(i + 1, inner);
    if (used == 0) return 0;
    out.addAll(inner.map(_alt));
    return 1 + used;
  }

  int _csi(int i, List<TuiEvent<Never>> out) {
    var j = i + 2;
    if (j < _pending.length && _pending[j] == 0x3c) return _mouse(i, out);
    while (j < _pending.length && (_pending[j] < 0x40 || _pending[j] > 0x7e)) {
      j++;
    }
    if (j >= _pending.length) return 0;
    final raw = String.fromCharCodes(_pending.sublist(i + 2, j));
    final params = raw.split(';');
    final last = _pending[j];
    final used = j - i + 1;
    // Answers to queries: the kitty protocol's `?flags u`, a cursor position `row;col R`.
    if (raw.startsWith('?') && last == 0x75) {
      _kitty?.call();
      return used;
    }
    if (last == 0x52 && params.length == 2 && _position != null && (int.tryParse(params[0]) ?? 0) > 1) {
      _position(int.parse(params[0]), int.tryParse(params[1]) ?? 1);
      return used;
    }
    if (last == 0x75) {
      _kittyKey(params, out);
      return used;
    }
    final first = int.tryParse(params[0]) ?? 1;
    final mod = params.length > 1 ? (int.tryParse(params[1]) ?? 1) - 1 : 0;
    final (shift, alt, ctrl) = (mod & 1 != 0, mod & 2 != 0, mod & 4 != 0);
    final name = switch (last) {
      0x5a => 'tab', // ESC [ Z: Shift+Tab
      0x7e => switch (first) {
        1 || 7 => 'home',
        2 => 'insert',
        3 => 'delete',
        4 || 8 => 'end',
        5 => 'pageUp',
        6 => 'pageDown',
        11 || 12 || 13 || 14 || 15 => 'f${first - 10}',
        17 || 18 || 19 || 20 || 21 => 'f${first - 11}',
        23 || 24 => 'f${first - 12}',
        _ => null,
      },
      _ => _finals[last],
    };
    if (last == 0x7e && first == 200) {
      _inPaste = true;
      return used;
    }
    if (name != null) out.add(KeyPress(name, ctrl: ctrl, alt: alt, shift: shift || last == 0x5a));
    return used;
  }

  /// A key in the kitty keyboard protocol: ESC [ code ; mods u.
  void _kittyKey(List<String> params, List<TuiEvent<Never>> out) {
    final code = int.tryParse(params[0].split(':').first) ?? 0;
    final mod = params.length > 1 ? (int.tryParse(params[1].split(':').first) ?? 1) - 1 : 0;
    final (shift, alt, ctrl) = (mod & 1 != 0, mod & 2 != 0, mod & 4 != 0);
    final name = switch (code) {
      13 => 'enter',
      9 => 'tab',
      127 || 8 => 'backspace',
      27 => 'esc',
      _ => null,
    };
    if (name != null) return out.add(KeyPress(name, ctrl: ctrl, alt: alt, shift: shift));
    if (code < 0x20) return;
    final char = String.fromCharCode(code);
    out.add(
      ctrl ? KeyPress(char, ctrl: true, alt: alt, shift: shift) : Char(shift ? char.toUpperCase() : char, alt: alt),
    );
  }

  /// SGR mouse: ESC [ < b ; x ; y (M | m).
  int _mouse(int i, List<TuiEvent<Never>> out) {
    var j = i + 3;
    while (j < _pending.length && _pending[j] != 0x4d && _pending[j] != 0x6d) {
      j++;
    }
    if (j >= _pending.length) return 0;
    final p = String.fromCharCodes(_pending.sublist(i + 3, j)).split(';').map(int.tryParse).toList();
    if (p.length == 3 && p.every((v) => v != null)) {
      final (b, x, y) = (p[0]!, p[1]! - 1, p[2]! - 1);
      final kind = b & 64 != 0
          ? (b & 1 == 0 ? MouseKind.wheelUp : MouseKind.wheelDown)
          : b & 32 != 0 && b & 3 == 3
          ? MouseKind.move
          : b & 32 != 0
          ? MouseKind.drag
          : _pending[j] == 0x6d
          ? MouseKind.release
          : MouseKind.press;
      out.add(Mouse(x, y, kind, button: b & 3, shift: b & 4 != 0, alt: b & 8 != 0, ctrl: b & 16 != 0));
    }
    return j - i + 1;
  }
}

/// A terminal colour: one of the sixteen named ones, a 256-palette index, or 24-bit RGB.
///
/// A terminal that cannot show it gets the nearest it can: RGB → 256 → 16 → none (`NO_COLOR`).
///
/// {@category CLI}
final class Color {
  /// 0: named (0–15), 1: palette (0–255), 2: RGB (0xRRGGBB).
  final int _kind;
  final int _value;

  const Color._(this._kind, this._value);

  /// Entry [index] of the 256-colour palette; 0–15 are the named colours.
  const Color(int index) : this._(index < 16 ? 0 : 1, index);

  /// A 24-bit colour.
  const Color.rgb(int r, int g, int b) : this._(2, (r & 255) << 16 | (g & 255) << 8 | (b & 255));

  /// `'#ff8800'` or `'ff8800'`.
  factory Color.hex(String hex) {
    final v = int.parse(hex.startsWith('#') ? hex.substring(1) : hex, radix: 16);
    return Color._(2, v & 0xffffff);
  }

  static const black = Color._(0, 0);
  static const red = Color._(0, 1);
  static const green = Color._(0, 2);
  static const yellow = Color._(0, 3);
  static const blue = Color._(0, 4);
  static const magenta = Color._(0, 5);
  static const cyan = Color._(0, 6);
  static const white = Color._(0, 7);
  static const gray = Color._(0, 8);
  static const brightRed = Color._(0, 9);
  static const brightGreen = Color._(0, 10);
  static const brightYellow = Color._(0, 11);
  static const brightBlue = Color._(0, 12);
  static const brightMagenta = Color._(0, 13);
  static const brightCyan = Color._(0, 14);
  static const brightWhite = Color._(0, 15);

  /// The SGR parameters for this colour as foreground (or background, [bg]) at [depth] colours.
  String _sgr(int depth, {bool bg = false}) => TerminalBridge.sgr(_kind, _value, depth, bg: bg);

  @override
  bool operator ==(Object other) => other is Color && other._kind == _kind && other._value == _value;

  @override
  int get hashCode => _kind << 24 ^ _value;
}

/// How text looks, in a console line and a Tui cell alike. Unset fields inherit: `base + over`
/// takes [over]'s set fields. Called on text, it styles it for a console line.
///
/// The statics are terminal text, measured in cells and aware of escapes: [width], [plain],
/// [truncate], [pad] and [wrap]; `'docs'.link(url)` makes a hyperlink.
///
/// ```dart
/// const title = Style(fg: Color.cyan, bold: true);
/// Console.line(title('Ready') + ' docs'.link(Uri.parse('https://x.dev')));
/// Style.truncate(name, 20); Style.pad(size, 8, align: Align.right);
/// ```
///
/// {@category CLI}
final class Style {
  final Color? fg;
  final Color? bg;
  final bool? bold;
  final bool? dim;
  final bool? italic;
  final bool? underline;
  final bool? reverse;

  const Style({this.fg, this.bg, this.bold, this.dim, this.italic, this.underline, this.reverse});

  static const none = Style();

  /// [text] in this style, at the colours the terminal shows, closing what it opens and reopening
  /// it after a reset inside [text], so styles nest. Plain where colour is off.
  String call(String text) {
    if (TerminalBridge.unstyled || IoBridge.color == false || identical(this, none)) return text;
    final open = _sgr(TerminalBridge.depth());
    return '$open${text.replaceAll('\x1B[0m', '\x1B[0m$open')}\x1B[0m';
  }

  /// The columns [text] takes on a terminal: escapes none, East Asian wide characters two.
  static int width(String text) => TextBridge.width(text);

  /// [text] without its escapes: styles, cursor moves, hyperlinks (their text kept).
  static String plain(String text) => TextBridge.stripAnsi(text);

  /// [text] cut to [width] columns, ending in [ellipsis] when cut, between graphemes and with its
  /// styles still closed.
  static String truncate(String text, int width, {String ellipsis = '…'}) {
    if (ellipsis == '…' || TextBridge.width(text) <= width) return TextBridge.truncate(text, width);
    final room = width - TextBridge.width(ellipsis) + 1;
    if (room < 1) return TextBridge.truncate(ellipsis, width);
    final cut = TextBridge.truncate(text, room);
    final at = cut.lastIndexOf('…');
    return at < 0 ? cut : cut.replaceRange(at, at + 1, ellipsis);
  }

  /// [text] filled with spaces to [width] columns, placed by [align]; wider text is kept whole.
  static String pad(String text, int width, {Align align = Align.left}) => TextBridge.pad(text, width, align: align);

  /// [text] in lines of at most [width] columns, broken at spaces and at its own newlines.
  static List<String> wrap(String text, int width) => TextBridge.wrap(text, width);

  /// The last sum and its terms: a run of text lays one style over one background, cell by cell.
  static Style? _base, _over, _sum;

  /// This style with [other]'s set fields on top.
  Style operator +(Style? other) {
    if (other == null || identical(other, none)) return this;
    if (identical(this, none)) return other;
    if (identical(this, _base) && identical(other, _over)) return _sum!;
    _base = this;
    _over = other;
    return _sum = Style(
      fg: other.fg ?? fg,
      bg: other.bg ?? bg,
      bold: other.bold ?? bold,
      dim: other.dim ?? dim,
      italic: other.italic ?? italic,
      underline: other.underline ?? underline,
      reverse: other.reverse ?? reverse,
    );
  }

  /// The sequences built so far, at the depth [_sgrDepth]: a screen has a handful of styles.
  static final Map<Style, String> _sgrs = {};
  static int _sgrDepth = -1;

  /// The SGR sequence that sets exactly this style from a reset, at [depth] colours (0: none).
  String _sgr(int depth) {
    if (depth != _sgrDepth || _sgrs.length > 256) {
      _sgrs.clear();
      _sgrDepth = depth;
    }
    return _sgrs[this] ??= _build(depth);
  }

  String _build(int depth) {
    final p = <String>[
      '0',
      if (bold == true) '1',
      if (dim == true) '2',
      if (italic == true) '3',
      if (underline == true) '4',
      if (reverse == true) '7',
      if (depth > 0 && fg != null) fg!._sgr(depth),
      if (depth > 0 && bg != null) bg!._sgr(depth, bg: true),
    ];
    return '\x1b[${p.join(';')}m';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Style &&
          other.fg == fg &&
          other.bg == bg &&
          other.bold == bold &&
          other.dim == dim &&
          other.italic == italic &&
          other.underline == underline &&
          other.reverse == reverse;

  @override
  int get hashCode => Object.hash(fg, bg, bold, dim, italic, underline, reverse);
}

/// Colour and emphasis on text, for a console line: `'failed'.red.bold`. Each is a [Style]
/// called on the text, so styles nest and drop away where colour is off.
///
/// {@category CLI}
extension StringStyles on String {
  String get red => const Style(fg: Color.red)(this);
  String get green => const Style(fg: Color.green)(this);
  String get yellow => const Style(fg: Color.yellow)(this);
  String get blue => const Style(fg: Color.blue)(this);
  String get magenta => const Style(fg: Color.magenta)(this);
  String get cyan => const Style(fg: Color.cyan)(this);
  String get gray => const Style(fg: Color.gray)(this);
  String get bold => const Style(bold: true)(this);
  String get dim => const Style(dim: true)(this);
  String get italic => const Style(italic: true)(this);
  String get underline => const Style(underline: true)(this);

  /// On a background of that colour: `' FAIL '.onRed.bold`.
  String get onRed => const Style(bg: Color.red)(this);
  String get onGreen => const Style(bg: Color.green)(this);
  String get onYellow => const Style(bg: Color.yellow)(this);
  String get onBlue => const Style(bg: Color.blue)(this);
  String get onMagenta => const Style(bg: Color.magenta)(this);
  String get onCyan => const Style(bg: Color.cyan)(this);
  String get onGray => const Style(bg: Color.gray)(this);

  /// In 24-bit colour, or the nearest of the 256 or 16 the terminal shows; plain under `NO_COLOR`.
  String rgb(int r, int g, int b) => Style(fg: Color.rgb(r, g, b))(this);

  /// On a 24-bit background, falling back as [rgb] does.
  String onRgb(int r, int g, int b) => Style(bg: Color.rgb(r, g, b))(this);

  /// A hyperlink to [url] (OSC 8): a click opens it where the terminal supports links; where
  /// colour is off (a log, a pipe, `NO_COLOR`) it is the text alone.
  ///
  /// ```dart
  /// Console.line('the docs'.link(Uri.parse('https://dart.dev')));
  /// ```
  String link(Uri url) {
    if (TerminalBridge.unstyled || IoBridge.color == false || TerminalBridge.depth() == 0) return this;
    return '\x1B]8;;$url\x1B\\$this\x1B]8;;\x1B\\';
  }
}

// ---- the palette -----------------------------------------------------------------------------

/// The marks a log line starts with, and that an indicator ends with.
///
/// {@category CLI}
final class Marks {
  final String ok, info, warn, error, debug;

  const Marks({this.ok = '✓', this.info = 'ℹ', this.warn = '⚠', this.error = '✖', this.debug = '·'});

  /// Only ASCII.
  static const ascii = Marks(ok: '+', info: 'i', warn: '!', error: 'x', debug: '.');

  /// The mark of [level].
  String of(LogLevel level) => switch (level) {
    LogLevel.debug => debug,
    LogLevel.info => info,
    LogLevel.ok => ok,
    LogLevel.warn => warn,
    LogLevel.error || LogLevel.silent => error,
  };
}

/// A bar's glyphs: [fill] for the part done, [head] after it (`''` for none), [empty] for the rest.
///
/// {@category CLI}
final class BarGlyphs {
  final String fill, empty, head;

  const BarGlyphs(this.fill, this.empty, [this.head = '']);

  /// Only ASCII.
  static const ascii = BarGlyphs('#', '-');

  /// A bar [width] columns wide, [fraction] of it done.
  String draw(double fraction, int width) {
    if (width <= 0) return '';
    final done = (fraction * width + 1e-9).floor().clamp(0, width);
    final tip = head.isNotEmpty && done < width ? 1 : 0;
    return fill * done + head * tip + empty * (width - done - tip);
  }
}

/// The tokens both UIs draw with: colours, marks, bar glyphs, the border, a spinner's frames and
/// its interval, a list's pointer and check boxes, a scrollbar and the ellipsis. One palette is
/// shared by `ConsoleTheme` and `TuiTheme`, which hold only their builders.
///
/// A palette names only what it changes; unset tokens are the defaults, or [ascii]'s where the
/// terminal cannot draw Unicode (the Linux console, a non-UTF-8 locale, the old Windows console).
///
/// ```dart
/// const palette = Palette(accent: Style(fg: Color.magenta), bar: BarGlyphs('=', ' ', '>'));
/// await Console.scope(() => work(), theme: const ConsoleTheme(palette: palette));
/// ```
///
/// {@category CLI}
final class Palette {
  final Style? _text, _muted, _accent, _success, _warning, _danger, _selected, _focused, _borderStyle;
  final Marks? _marks;
  final BarGlyphs? _bar;
  final Border? _border;
  final List<String>? _frames;
  final Duration? _interval;
  final String? _pointer, _checked, _unchecked, _scrollTrack, _scrollThumb, _ellipsis;

  const Palette({
    Style? text,
    Style? muted,
    Style? accent,
    Style? success,
    Style? warning,
    Style? danger,
    Style? selected,
    Style? focused,
    Style? borderStyle,
    Marks? marks,
    BarGlyphs? bar,
    Border? border,
    List<String>? frames,
    Duration? interval,
    String? pointer,
    String? checked,
    String? unchecked,
    String? scrollTrack,
    String? scrollThumb,
    String? ellipsis,
  }) : _text = text,
       _muted = muted,
       _accent = accent,
       _success = success,
       _warning = warning,
       _danger = danger,
       _selected = selected,
       _focused = focused,
       _borderStyle = borderStyle,
       _marks = marks,
       _bar = bar,
       _border = border,
       _frames = frames,
       _interval = interval,
       _pointer = pointer,
       _checked = checked,
       _unchecked = unchecked,
       _scrollTrack = scrollTrack,
       _scrollThumb = scrollThumb,
       _ellipsis = ellipsis;

  /// Only ASCII glyphs: what is drawn under a palette's unset glyphs where Unicode would not draw.
  static const ascii = Palette(
    marks: Marks.ascii,
    bar: BarGlyphs.ascii,
    border: Border.ascii,
    frames: [r'-', r'\', r'|', r'/'],
    pointer: '>',
    checked: '*',
    unchecked: 'o',
    scrollTrack: '|',
    scrollThumb: '#',
    ellipsis: '...',
  );

  /// Plain text.
  Style get text => _text ?? Style.none;

  /// Secondary text: debug lines, hints, live indicators, placeholders.
  Style get muted => _muted ?? const Style(dim: true);

  /// What should catch the eye: info lines, frames, titles, a list's cursor, filter matches.
  Style get accent => _accent ?? const Style(fg: Color.cyan);

  Style get success => _success ?? const Style(fg: Color.green);
  Style get warning => _warning ?? const Style(fg: Color.yellow);
  Style get danger => _danger ?? const Style(fg: Color.red);

  /// The cursor row of a focused list or table.
  Style get selected => _selected ?? const Style(reverse: true);

  /// The border and title of a box holding the focus.
  Style get focused => _focused ?? const Style(fg: Color.cyan);

  /// Borders.
  Style get borderStyle => _borderStyle ?? Style.none;

  /// The marks of the log levels: `✓ ℹ ⚠ ✖ ·`.
  Marks get marks => _marks ?? const Marks();

  /// A bar's glyphs: `█` and `░`.
  BarGlyphs get bar => _bar ?? const BarGlyphs('█', '░');

  /// A box's, a table's and a rule's border.
  Border get border => _border ?? Border.rounded;

  /// A spinner's frames, one cell each, [interval] apart.
  List<String> get frames => _frames ?? const ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  /// How often live work is redrawn, and a spinner's frame changes.
  Duration get interval => _interval ?? const Duration(milliseconds: 80);

  /// A list's cursor, and its checked and unchecked boxes.
  String get pointer => _pointer ?? '›';
  String get checked => _checked ?? '◉';
  String get unchecked => _unchecked ?? '○';

  /// A scrollbar's track and thumb.
  String get scrollTrack => _scrollTrack ?? '│';
  String get scrollThumb => _scrollThumb ?? '┃';

  /// What ends text cut to fit.
  String get ellipsis => _ellipsis ?? '…';

  /// The frame of [frames] at [elapsed].
  String frameAt(Duration elapsed) => frames[elapsed.inMicroseconds ~/ interval.inMicroseconds % frames.length];

  Palette _over(Palette base) => Palette(
    text: _text ?? base._text,
    muted: _muted ?? base._muted,
    accent: _accent ?? base._accent,
    success: _success ?? base._success,
    warning: _warning ?? base._warning,
    danger: _danger ?? base._danger,
    selected: _selected ?? base._selected,
    focused: _focused ?? base._focused,
    borderStyle: _borderStyle ?? base._borderStyle,
    marks: _marks ?? base._marks,
    bar: _bar ?? base._bar,
    border: _border ?? base._border,
    frames: _frames ?? base._frames,
    interval: _interval ?? base._interval,
    pointer: _pointer ?? base._pointer,
    checked: _checked ?? base._checked,
    unchecked: _unchecked ?? base._unchecked,
    scrollTrack: _scrollTrack ?? base._scrollTrack,
    scrollThumb: _scrollThumb ?? base._scrollThumb,
    ellipsis: _ellipsis ?? base._ellipsis,
  );
}

/// Severity levels for the console's log verbs, from most to least verbose.
///
/// {@category CLI}
enum LogLevel {
  /// Everything, `Console.debug` included (`-v`).
  debug,

  /// Information and above: the default.
  info,

  /// Successes (`Console.ok`, how drawn work ends) and above.
  ok,

  /// Warnings and errors only (`-q`).
  warn,

  /// Errors only.
  error,

  /// Nothing.
  silent;

  /// The palette's colour for this level.
  Style styleIn(Palette palette) => switch (this) {
    debug => palette.muted,
    info => palette.accent,
    ok => palette.success,
    warn => palette.warning,
    error || silent => palette.danger,
  };
}

// ---- the tally -------------------------------------------------------------------------------

/// A rate over a sliding window of one second, from samples of a count that only grows: a
/// stall decays to nothing as its samples slide out.
final class _Meter {
  static const _window = Duration(seconds: 1);

  /// The span below which there is no rate yet.
  static const _least = Duration(milliseconds: 250);

  final _samples = ListQueue<(Duration, int)>();

  void add(Duration at, int count) {
    if (_samples.isNotEmpty) {
      final (last, _) = _samples.last;
      if (at < last) return;
      // Reports in a burst are one sample: the window stays a few dozen long.
      if (_samples.length > 1 && at - last < const Duration(milliseconds: 20)) _samples.removeLast();
    }
    _samples.add((at, count));
    // One sample at or before the window's start stays, so the whole window is measured.
    while (_samples.length > 2 && at - _samples.elementAt(1).$1 >= _window) {
      _samples.removeFirst();
    }
  }

  /// Per second, or `null` until the samples span a quarter of a second.
  double? get rate {
    if (_samples.length < 2) return null;
    final (t0, c0) = _samples.first;
    final (t1, c1) = _samples.last;
    final span = t1 - t0;
    return span < _least ? null : (c1 - c0) * 1e6 / span.inMicroseconds;
  }

  void reset() => _samples.clear();
}

Duration _span(num seconds) => Duration(microseconds: (seconds * 1e6).round().clamp(0, 1 << 52));

/// One item a [Tally] has heard of: its latest status and amounts, and its own rate.
///
/// {@category CLI}
final class TallyItem {
  final Tally _tally;

  /// What the work is about: the batch's input, or the task's item.
  final Object? item;

  String _label;
  Status<Object?, Object?> _status;
  int _received = 0;
  int? _total;
  Unit _unit = Unit.none;
  String? _step;
  final Duration _started;
  Duration? _ended;
  bool _ran = false;
  final _meter = _Meter();

  TallyItem._(this._tally, this.item, this._label, this._status, this._started);

  /// How a row names it: its status's label.
  String get label => _label;

  /// What it last reported, [Warned] notes aside.
  Status<Object?, Object?> get status => _status;

  /// Amounts as the last [Running] said, in [unit].
  int get received => _received;
  int? get total => _total;
  Unit get unit => _unit;

  /// The phase it is on: `'verifying'`.
  String? get step => _step;

  /// Whether it has ended: [Done], [Skipped], [Failed] or [Stopped].
  bool get isOver => _status.isFinal;

  /// Since it was first heard of, until it ended.
  Duration get elapsed => (_ended ?? _tally._now) - _started;

  /// [unit]s per second over the last second; `null` until known.
  double? get rate => isOver ? null : _meter.rate;

  /// Time left at [rate], or `null` while either is unknown.
  Duration? get eta => switch ((_total, rate)) {
    (final all?, final r?) when r > 0 && !isOver => _span((all - _received).clamp(0, all) / r),
    _ => null,
  };

  /// Its size once known: the total it said, or what it received by the end.
  int? get _size => _total ?? (isOver ? _received : null);
}

/// The one model of work in progress, with no renderer: it hears [Status]es (from a [Task], a
/// [Batch], or [add] by hand) and keeps the items, the counts, the amounts, a windowed rate, the
/// time left and the failures. The console and the TUI both draw a tally: `show()`,
/// `Console.bar` and `Board(tally)`.
///
/// Producers report amounts; the tally measures rates over a sliding second, sampled on every
/// [sample] (a display's tick), so a stall decays. Time is [Clock.current]'s.
///
/// ```dart
/// final tally = Tally.batch(urls.parallelize((u) => u.download(into: 'out')));
/// await tally.over;
/// print('${tally.done} of ${tally.count}, ${tally.failed} failed');
/// ```
///
/// {@category CLI}
final class Tally {
  final Clock _clock = Clock.current;
  late final Duration _start = _clock.elapsed;
  final int? _given;
  final int? Function()? _known;

  /// Whether this is one task's: its statuses are about one item, drawn as one line.
  final bool isTask;

  final _items = <Object?, TallyItem>{};
  final _order = <TallyItem>[];
  final _live = <TallyItem>{};
  final _failures = <Failed<Object?, Object?>>[];
  final _notes = <Status<Object?, Object?>>[];
  final _values = <Object?>[];
  final _changes = StreamController<Status<Object?, Object?>>.broadcast(sync: true);
  final _over = Completer<void>();
  final _amounts = _Meter(), _ends = _Meter();
  final List<TallyItem> _shown = [];
  TallyItem? _latest;
  Duration? _endedAt;
  int _done = 0, _failed = 0, _skipped = 0, _stopped = 0;

  /// Bytes received now, as the latest reports say; and moved in all, a restart not taking any back.
  int _received = 0, _moved = 0;
  bool _bytes = false;

  /// A tally fed by hand with [add], of [count] items when that is known; [close] ends it.
  Tally({int? count}) : _given = count, _known = null, isTask = false {
    if (count != null && count < 0) throw ArgumentError.value(count, 'count', 'Invalid count, expected at least 0');
    _start;
  }

  /// [task]'s statuses, as one item. The same task gives the same tally, so a view can ask for
  /// it on every frame (a job run again after it ended gets a fresh one).
  factory Tally.task(Task<Object?> task) {
    final kept = _ofTask[task];
    if (kept != null && !(kept.isOver && !task.status.isFinal)) return kept;
    return _ofTask[task] = Tally._task(task);
  }

  Tally._task(Task<Object?> task) : _given = 1, _known = null, isTask = true {
    _start;
    // The tally holds how it ended: a failure is in it, not an unhandled error.
    task.settled.ignore();
    task.statuses.listen(_apply, onDone: _end);
  }

  /// [batch]'s statuses, one item each; the count is the batch's once it knows it. The same
  /// batch gives the same tally.
  factory Tally.batch(Batch<Object?, Object?> batch) => _ofBatch[batch] ??= Tally._batch(batch);

  Tally._batch(Batch<Object?, Object?> batch) : _given = null, _known = (() => batch.count), isTask = false {
    _start;
    batch.settled.ignore();
    batch.statuses.listen(_apply, onDone: _end);
  }

  static final _ofTask = Expando<Tally>('tally');
  static final _ofBatch = Expando<Tally>('tally');

  Duration get _now => _clock.elapsed;

  /// Items in all: as given, as the batch knows it, or once it is over, as many as were heard.
  int? get count => _given ?? _known?.call() ?? (isOver ? _order.length : null);

  /// Every item heard of, in the order first heard.
  List<TallyItem> get items => UnmodifiableListView(_order);

  /// The item heard of last.
  TallyItem? get latest => _latest;

  /// Items ended, and of them done, failed, skipped and stopped.
  int get ended => _done + _failed + _skipped + _stopped;
  int get done => _done;
  int get failed => _failed;
  int get skipped => _skipped;
  int get stopped => _stopped;

  /// Items under way.
  int get running => _live.length;

  /// Bytes received in all, as the items' latest reports say.
  int get received => _received;

  /// Bytes in all, once every item is known and sized; `null` before.
  int? get total {
    final n = count;
    if (!_bytes || n == null || _order.length < n) return null;
    var sum = 0;
    for (final item in _order) {
      if (item._size case final size?) {
        sum += size;
      } else {
        return null;
      }
    }
    return sum;
  }

  /// Bytes per second over the last second; `null` until known, or without bytes.
  double? get rate => _bytes && !isOver ? _amounts.rate : null;

  /// Items ended per second over the last second; `null` until known.
  double? get itemRate => isOver ? null : _ends.rate;

  /// Time left: by bytes when every size is known, else by items; `null` while unknown.
  Duration? get eta {
    if (isOver) return null;
    if (isTask) return _order.firstOrNull?.eta;
    if ((total, rate) case (final all?, final r?) when r > 0) return _span((all - _received).clamp(0, all) / r);
    if ((count, itemRate) case (final n?, final r?) when r > 0) return _span((n - ended).clamp(0, n) / r);
    return null;
  }

  /// Since the tally was made, until the work ended.
  Duration get elapsed => (_endedAt ?? _now) - _start;

  /// Whether the work has ended (a hand-fed tally: whether it is [close]d).
  bool get isOver => _over.isCompleted;

  /// Completes when the work ends.
  Future<void> get over => _over.future;

  /// Every [Failed], in the order they came.
  List<Failed<Object?, Object?>> get failures => UnmodifiableListView(_failures);

  /// The latest hundred [Warned] notes and [Failed] items, in the order they came: what a
  /// display prints above or under what it draws.
  List<Status<Object?, Object?>> get notes => UnmodifiableListView(_notes);

  void _note(Status<Object?, Object?> status) {
    if (_notes.length >= 100) _notes.removeAt(0);
    _notes.add(status);
  }

  /// Every [Done]'s value, in the order they came.
  List<Object?> get values => UnmodifiableListView(_values);

  /// Each status as it is taken in, [Warned] notes included: what a display redraws on.
  Stream<Status<Object?, Object?>> get changes => _changes.stream;

  /// Takes in [status], by hand. A tally that is over is a [StateError].
  void add(Status<Object?, Object?> status) {
    if (isOver) throw StateError('Cannot add $status: the tally is closed');
    if (_known != null || isTask) throw StateError('Cannot add $status: the tally hears its own work');
    _apply(status);
  }

  /// Ends a tally fed by hand.
  void close() {
    if (_known != null || isTask) throw StateError('Cannot close a tally that hears its own work');
    _end();
  }

  /// Records the time now for the rates: a display calls it on every tick, so a stall decays.
  void sample() {
    final now = _now;
    _amounts.add(now, _moved);
    _ends.add(now, ended);
    for (final item in _live) {
      item._meter.add(now, item._received);
    }
  }

  /// At most [max] items to draw as rows, and how many running ones are left out. A running row
  /// keeps its place; a new item takes a free row, else the one that ended longest ago.
  ({List<TallyItem> rows, int more}) rows(int max) {
    if (max < 1) throw ArgumentError.value(max, 'max', 'Invalid rows, expected at least 1');
    final shown = _shown;
    final placed = shown.toSet();
    for (final item in _live) {
      if (placed.contains(item)) continue;
      if (shown.length < max) {
        shown.add(item);
        placed.add(item);
        continue;
      }
      var oldest = -1;
      for (var i = 0; i < shown.length; i++) {
        final ended = shown[i]._ended;
        if (ended != null && (oldest < 0 || ended < shown[oldest]._ended!)) oldest = i;
      }
      if (oldest < 0) break;
      placed.remove(shown[oldest]);
      shown[oldest] = item;
      placed.add(item);
    }
    while (shown.length > max) {
      final ended = shown.indexWhere((i) => i.isOver);
      shown.removeAt(ended >= 0 ? ended : shown.length - 1);
    }
    var more = 0;
    for (final item in _live) {
      if (!shown.contains(item)) more++;
    }
    return (rows: List.unmodifiable(shown), more: more);
  }

  void _apply(Status<Object?, Object?> status) {
    if (status is Warned) {
      _note(status);
      _changes.add(status);
      return;
    }
    final now = _now;
    final key = isTask ? null : status.item;
    final entry = _items[key] ??= () {
      final made = TallyItem._(this, status.item, status.label, Waiting(status.item, label: status.label), now);
      _order.add(made);
      return made;
    }();
    if (entry.isOver) return;
    entry._label = status.label;
    switch (status) {
      case Running(:final received, :final total, :final unit, :final step):
        if (!entry._ran) _live.add(entry);
        entry._ran = true;
        if (entry._unit == Unit.bytes) _received -= entry._received;
        if (unit == Unit.bytes) {
          _bytes = true;
          _received += received;
          if (entry._unit == Unit.bytes && received > entry._received) _moved += received - entry._received;
          if (entry._unit != Unit.bytes) _moved += received;
        }
        // A restart (a retry from zero) measures again from where it is.
        if (received < entry._received || unit != entry._unit) entry._meter.reset();
        entry
          .._received = received
          .._total = total
          .._unit = unit
          .._step = step;
        entry._meter.add(now, received);
      case Done(:final value):
        _done++;
        _values.add(value);
        // Done is all of it: the last report may have come a chunk before the end.
        if ((entry._unit, entry._total) case (Unit.bytes, final all?) when entry._received < all) {
          _received += all - entry._received;
          _moved += all - entry._received;
          entry._received = all;
        }
      case Skipped():
        _skipped++;
      case final Failed<Object?, Object?> failed:
        _failed++;
        _failures.add(failed);
        if (!isTask) _note(failed);
      case Stopped():
        _stopped++;
      case Waiting() || Paused() || Warned():
    }
    entry._status = status;
    if (status.isFinal) {
      entry._ended = now;
      _live.remove(entry);
      _ends.add(now, ended);
    }
    _amounts.add(now, _moved);
    _latest = entry;
    _changes.add(status);
  }

  void _end() {
    if (_over.isCompleted) return;
    _endedAt = _now;
    _live.clear();
    _over.complete();
    _changes.close();
  }
}

// ---- the views builders are handed -----------------------------------------------------------

/// `1.2 MB/2.0 GB`, `12/50`, `12.0 KB` while the size is unknown, or `''`.
String _amounts(int received, int? total, Unit unit) => switch (unit) {
  Unit.bytes when total != null && total > 0 => '${received.humanBytes}/${total.humanBytes}',
  Unit.bytes when received > 0 => received.humanBytes,
  Unit.items when total != null => '$received/$total',
  Unit.items when received > 0 => '$received',
  _ => '',
};

/// `3.1 MB/s`, `12/s`, or `''` while unknown.
String _pace(double? rate, Unit unit) => switch (rate) {
  final r? when r > 0 && unit == Unit.bytes => '${r.humanBytes}/s',
  final r? when r > 0 => '${r >= 10 ? r.round() : r.toStringAsFixed(1)}/s',
  _ => '',
};

/// One task's progress, for a `task:` builder: a single task's line, or a row of a batch.
///
/// {@category CLI}
final class TaskView {
  /// The line's title for a single task, the item's label for a row.
  final String label;

  /// What it last reported: `switch` on it.
  final Status<Object?, Object?> status;

  /// Amounts in [unit].
  final int received;
  final int? total;
  final Unit unit;
  final String? step;

  /// [unit]s per second over the last second, and the time left; `null` while unknown.
  final double? rate;
  final Duration? eta;
  final Duration elapsed;

  /// Whether this is a row under a batch's header.
  final bool isRow;

  /// Whether it is redrawn in place, or a line a log keeps (no terminal).
  final bool isLive;

  /// Columns the line may use.
  final int columns;
  final Palette palette;

  const TaskView({
    required this.label,
    required this.status,
    this.received = 0,
    this.total,
    this.unit = Unit.none,
    this.step,
    this.rate,
    this.eta,
    this.elapsed = Duration.zero,
    this.isRow = false,
    this.isLive = true,
    this.columns = 80,
    this.palette = const Palette(),
  });

  /// [item] as it stands, under [label] when given.
  TaskView.of(
    TallyItem item, {
    String? label,
    this.isRow = false,
    this.isLive = true,
    this.columns = 80,
    this.palette = const Palette(),
  }) : label = label ?? item.label,
       status = item.status,
       received = item.received,
       total = item.total,
       unit = item.unit,
       step = item.step,
       rate = item.rate,
       eta = item.eta,
       elapsed = item.elapsed;

  /// From 0.0 to 1.0, or `null` while the size is unknown.
  double? get fraction => switch (status) {
    Done() || Skipped() => 1.0,
    _ => switch (total) {
      final all? when all > 0 => (received / all).clamp(0.0, 1.0),
      _ => null,
    },
  };

  /// [fraction] in whole percent.
  int? get percent => switch (fraction) {
    final f? => (f * 100 + 1e-9).floor(),
    _ => null,
  };

  /// The spinner's frame now.
  String get frame => palette.frameAt(elapsed);

  /// A bar [width] columns wide, in the palette's glyphs.
  String bar(int width) => palette.bar.draw(fraction ?? 0, width);

  /// `1.2 MB/2.0 GB`, `3/8`, or `''`.
  String get amounts => _amounts(received, total, unit);

  /// `3.1 MB/s`, or `''`.
  String get pace => _pace(rate, unit);
}

/// A batch as it stands, for a `batch:` builder: its header.
///
/// {@category CLI}
final class BatchView {
  final String title;

  /// Items in all, or `null` while unknown.
  final int? count;

  /// Items ended, and of them done, failed, skipped and stopped; items under way.
  final int ended, done, failed, skipped, stopped, running;

  /// Running items without a row: `+N more`.
  final int more;

  /// Bytes so far, and in all once every item is sized.
  final int received;
  final int? total;

  /// Bytes and items per second over the last second, and the time left; `null` while unknown.
  final double? rate, itemRate;
  final Duration? eta;
  final Duration elapsed;

  /// The label of the item heard of last: a hand-fed bar's latest tick.
  final String? latest;

  final bool isLive;
  final int columns;
  final Palette palette;

  const BatchView({
    required this.title,
    this.count,
    this.ended = 0,
    this.done = 0,
    this.failed = 0,
    this.skipped = 0,
    this.stopped = 0,
    this.running = 0,
    this.more = 0,
    this.received = 0,
    this.total,
    this.rate,
    this.itemRate,
    this.eta,
    this.elapsed = Duration.zero,
    this.latest,
    this.isLive = true,
    this.columns = 80,
    this.palette = const Palette(),
  });

  /// [tally] as it stands, under [title].
  BatchView.of(
    Tally tally, {
    required this.title,
    this.more = 0,
    this.isLive = true,
    this.columns = 80,
    this.palette = const Palette(),
  }) : count = tally.count,
       ended = tally.ended,
       done = tally.done,
       failed = tally.failed,
       skipped = tally.skipped,
       stopped = tally.stopped,
       running = tally.running,
       received = tally.received,
       total = tally.total,
       rate = tally.rate,
       itemRate = tally.itemRate,
       eta = tally.eta,
       elapsed = tally.elapsed,
       latest = tally.latest?.label;

  /// Items ended of [count], from 0.0 to 1.0; `null` while the count is unknown.
  double? get fraction => switch (count) {
    null => null,
    0 => 1.0,
    final n => (ended / n).clamp(0.0, 1.0),
  };

  int? get percent => switch (fraction) {
    final f? => (f * 100 + 1e-9).floor(),
    _ => null,
  };

  String get frame => palette.frameAt(elapsed);

  String bar(int width) => palette.bar.draw(fraction ?? 0, width);

  /// `120.0 MB/400.0 MB` once sized, `120.0 MB` before, or `''` without bytes.
  String get amounts => _amounts(received, total, Unit.bytes);

  /// Bytes per second when bytes move, else items per second, or `''`.
  String get pace => received > 0 && rate != null ? _pace(rate, Unit.bytes) : _pace(itemRate, Unit.items);
}

/// A row of a list to pick from: `Console.pick`'s, a `Menu`'s, a `Tabs` title.
///
/// {@category CLI}
final class ItemView<T> {
  /// Its index in the full list.
  final int index;
  final T value;

  /// Its text: what the filter matched against.
  final String label;

  /// Whether the cursor is on it.
  final bool isSelected;

  /// Whether it is checked; `null` unless several are picked.
  final bool? isChecked;

  /// Whether the list has the focus, and whether the pointer is over this row.
  final bool isFocused, isHovered;

  /// Where the filter matched [label], as `[start, end)` ranges.
  final List<(int, int)> matches;
  final Palette palette;

  const ItemView({
    required this.index,
    required this.value,
    required this.label,
    this.isSelected = false,
    this.isChecked,
    this.isFocused = true,
    this.isHovered = false,
    this.matches = const [],
    this.palette = const Palette(),
  });

  /// [label] in parts, each with whether the filter matched it.
  List<(String, bool)> get parts {
    if (matches.isEmpty) return [(label, false)];
    final out = <(String, bool)>[];
    var at = 0;
    for (final (s, e) in matches) {
      if (s > at) out.add((label.substring(at, s), false));
      out.add((label.substring(s, e), true));
      at = e;
    }
    if (at < label.length) out.add((label.substring(at), false));
    return out;
  }
}

/// A line that stays, for a `log:` builder: a log verb's, how drawn work ends, a warning or a
/// failure printed above live work.
///
/// {@category CLI}
final class LogView {
  final LogLevel level;
  final String message;

  /// How long the work this line ends took; `null` on a line that ends nothing.
  final Duration? elapsed;
  final Palette palette;

  const LogView(this.level, this.message, {this.elapsed, this.palette = const Palette()});

  /// The palette's mark for [level].
  String get mark => palette.marks.of(level);

  /// The palette's colour for [level].
  Style get style => level.styleIn(palette);
}

// ---- the list model --------------------------------------------------------------------------

/// What a widget keeps of where a [Choice] was drawn, between frames. Not API.
final class ChoiceLayout {
  int offset = 0, page = 1;
  bool horizontal = false;

  /// Where each tab was drawn, and which shown item each row is: for clicks.
  List<(int, int)> tabs = const [];
  List<int> rows = const [];
}

/// A list of [items] to pick from, and where the picking stands: the cursor, the filter, the
/// checked items. `Console.pick` and a `Menu`, `Grid` or `Tabs` all run on it.
///
/// Hold one per list; a widget is rebuilt each frame around it. With [filter], typed text
/// narrows the list; with [multi], Space checks the cursor's item. [label] names an item (by
/// default its `toString()`, an enum's `name`).
///
/// ```dart
/// final pick = Choice(files, label: (f) => f.name, filter: true);
/// … Menu(pick) …
/// KeyPress.enter when pick.value != null => Tui.quit(pick.value),
/// ```
///
/// {@category CLI}
final class Choice<T> with Focusable {
  final String Function(T item)? _label;
  final bool filter, multi;
  final Set<int> _checked;
  final _layout = ChoiceLayout();
  List<T> _items;
  String _query = '';

  /// The cursor's item, as an index into the full list; `-1` when the filter matches nothing.
  int index;

  /// The labels lowercased once a filter needs them, and the query [_shown] was filtered by.
  List<String>? _lowered;
  String? _filtered;
  List<int> _shown = const [];

  Choice(
    List<T> items, {
    String Function(T item)? label,
    this.filter = false,
    this.multi = false,
    this.index = 0,
    Iterable<int> checked = const [],
  }) : _items = items,
       _label = label,
       _checked = {...checked} {
    if (!multi && _checked.isNotEmpty) throw ArgumentError.value(checked, 'checked', 'Invalid checked: not multi');
    if (_checked.any((i) => i < 0 || i >= items.length)) {
      throw ArgumentError.value(checked, 'checked', 'Invalid checked: not an index of items');
    }
  }

  /// The list to pick from. Assigning another shows it, filtered as [query] says.
  List<T> get items => _items;

  set items(List<T> next) {
    _items = next;
    _lowered = _filtered = null;
    _checked.removeWhere((i) => i >= next.length);
  }

  /// Item [i]'s text.
  String label(int i) => _label?.call(_items[i]) ?? TerminalBridge.label(_items[i]);

  /// What has been typed into the filter.
  String get query => _query;

  set query(String value) {
    if (!filter) throw StateError('Cannot filter a Choice made without filter: true');
    _query = value;
  }

  /// The checked items' indexes.
  Set<int> get checked => UnmodifiableSetView(_checked);

  /// The cursor's item, or `null` when the filter matches nothing.
  T? get value => index >= 0 && index < _items.length ? _items[index] : null;

  /// The checked items, in list order.
  List<T> get picked => [for (final i in _checked.toList()..sort()) _items[i]];

  /// The items the filter leaves, as indexes into the full list.
  List<int> get shown {
    _settle();
    return _shown;
  }

  /// Where the filter matches item [i]'s label, as `[start, end)` ranges.
  List<(int, int)> matchesOf(int i) =>
      _query.isEmpty ? const [] : _match(label(i).toLowerCase(), _query.toLowerCase()) ?? const [];

  /// Checks or unchecks item [i] (by default the cursor's).
  void toggle([int? i]) {
    if (!multi) throw StateError('Cannot check an item of a Choice made without multi: true');
    final at = i ?? index;
    if (at < 0 || at >= _items.length) return;
    if (!_checked.remove(at)) _checked.add(at);
  }

  /// Moves the cursor [by] items among those shown.
  void move(int by) {
    _settle();
    if (_shown.isEmpty) return;
    index = _shown[(_shown.indexOf(index) + by).clamp(0, _shown.length - 1)];
  }

  /// Settles the cursor and the filter on [items]: the labels are read once per list and
  /// filtered once per query.
  void _settle() {
    final q = _query.toLowerCase();
    final count = _items.length;
    if (q != _filtered || _shown.length > count) {
      final lowered = q.isEmpty ? null : _lowered ??= [for (var i = 0; i < count; i++) label(i).toLowerCase()];
      _shown = lowered == null
          ? List.generate(count, (i) => i)
          : [
              for (var i = 0; i < count; i++)
                if (TerminalBridge.matches(lowered[i], q)) i,
            ];
      _filtered = q;
    }
    if (_shown.isEmpty) {
      index = -1;
    } else if (!_shown.contains(index)) {
      index = _shown.firstWhere((i) => i >= index, orElse: () => _shown.last);
    }
  }

  @override
  bool handle(TuiEvent<Object?> event) {
    final horizontal = _layout.horizontal;
    final (back, forward) = horizontal ? (KeyPress.left, KeyPress.right) : (KeyPress.up, KeyPress.down);
    switch (event) {
      case _ when event == back:
        move(-1);
      case _ when event == forward:
        move(1);
      case KeyPress.home when !horizontal:
        move(-_items.length);
      case KeyPress.end when !horizontal:
        move(_items.length);
      case KeyPress.pageUp when !horizontal:
        move(-_layout.page);
      case KeyPress.pageDown when !horizontal:
        move(_layout.page);
      case Char(char: ' ', alt: false) when multi && index >= 0:
        toggle();
      case Char(:final char, alt: false) when filter:
        _query += char;
      case Paste(:final text) when filter:
        _query += text.replaceAll('\n', ' ');
      case KeyPress.backspace when filter && _query.isNotEmpty:
        _query = String.fromCharCodes(_query.runes.toList()..removeLast());
      default:
        return false;
    }
    _settle();
    return true;
  }

  @override
  void mouse(Mouse event, int x, int y) {
    switch (event.kind) {
      case MouseKind.wheelUp:
        move(-1);
      case MouseKind.wheelDown:
        move(1);
      case MouseKind.press when _layout.horizontal:
        for (final (i, (s, e)) in _layout.tabs.indexed) {
          if (x >= s && x < e) index = i;
        }
      case MouseKind.press:
        // The rows drawn last may outlive a filter that now matches nothing.
        final rows = _layout.rows;
        if (y < rows.length && rows[y] < _shown.length) index = _shown[rows[y]];
      default:
    }
  }
}

/// The filter's match in [label]: a substring, else a subsequence, as ranges; `null` for none.
List<(int, int)>? _match(String label, String query) {
  if (query.isEmpty) return const [];
  final at = label.indexOf(query);
  if (at >= 0) return [(at, at + query.length)];
  final ranges = <(int, int)>[];
  var q = 0;
  for (var i = 0; i < label.length && q < query.length; i++) {
    if (label[i] != query[q]) continue;
    q++;
    if (ranges.isNotEmpty && ranges.last.$2 == i) {
      ranges.last = (ranges.last.$1, i + 1);
    } else {
      ranges.add((i, i + 1));
    }
  }
  return q == query.length ? ranges : null;
}

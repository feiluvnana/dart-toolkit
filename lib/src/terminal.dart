/// Shared private terminal layer for `tui` and `console`.
///
/// Not exported by either module: both import it by relative path and keep
/// their own public surface. It holds what the two must agree on: one
/// broadcast stdin, one key decoder (keys_decode.dart), cell widths
/// (width.dart), and saving/restoring terminal modes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'format.dart';

export 'bridge.dart';
import 'winconsole.dart' as win;

import 'sanitize.dart';
export 'sanitize.dart';
import 'width.dart';
export 'width.dart';
export 'keys_decode.dart';

/// Terminal input for `Tui.run` and the prompts, as a broadcast stream that
/// can be listened to again after every listener has cancelled — and that
/// lets the process exit once nobody listens.
///
/// `dart:io` allows one listener on stdin per process, and that listener
/// keeps the process alive even when paused. So on a POSIX terminal the
/// bytes come from a child `cat -u /dev/tty`, started on the first listen
/// and stopped on the last cancel. The child ignores SIGINT, so Ctrl-C still
/// reaches us (as a key, or as the prompt's exit). Piped stdin, Windows, or
/// a missing `cat` fall back to stdin itself, which ends at EOF.
///
/// The child must never outlive us: an orphaned `cat` keeps reading the
/// terminal and eats the shell's keystrokes. Its wrapper shell watches the
/// pipe we hold open on its stdin and kills `cat` when that pipe closes,
/// which the kernel does on any exit: `exit()`, a crash, a signal, even
/// SIGKILL. A cancel closes the pipe too.
Stream<List<int>> sharedStdin() {
  if (_input.isClosed) _input = _makeInput();
  return _input.stream;
}

StreamController<List<int>> _makeInput() =>
    StreamController<List<int>>.broadcast(onListen: _startInput, onCancel: () => _stopping = _stopInput());

/// The last stop of the tty child, so a suspend can wait until nothing
/// reads the terminal any more.
Future<void>? _stopping;

/// Completes once the input the last listener cancelled has stopped: the
/// tty child has exited, so it reads no keystroke meant for the shell.
Future<void> inputStopped() => _stopping ?? Future<void>.value();

var _input = _makeInput();
io.Process? _tty;
StreamSubscription<List<int>>? _ttySub;
Stream<List<int>>? _stdinFallback;

/// Piped stdin's bytes (`Console.input()`), shared with the prompts that
/// read it after: one subscription per process is all `dart:io` allows.
Stream<List<int>> stdinBytes() => _stdinFallback ??= io.stdin.asBroadcastStream();

/// True while no listener has taken stdin itself (the piped fallback), so a
/// synchronous `readLineSync` is still allowed and loses nothing.
bool get stdinUnclaimed => _stdinFallback == null;

/// One line of piped stdin (null at EOF) without blocking the event loop:
/// a helper isolate does the blocking `readLineSync`. It reads byte by
/// byte, so nothing past the line is consumed, and unlike a subscription it
/// neither drops lines that arrive between prompts nor keeps the script
/// alive until the writer closes the pipe. Only while [stdinUnclaimed].
/// Whether stdin is a terminal. `stdin.hasTerminal` also says yes for any
/// character device (`< /dev/null`); a terminal is one whose modes can be
/// read.
final bool stdinTty = () {
  if (!io.stdin.hasTerminal) return false;
  try {
    io.stdin.echoMode;
    return true;
  } on io.StdinException {
    return false;
  }
}();

Future<String?> pipedLine({Duration? timeout}) {
  if (timeout == null || io.Platform.isWindows) {
    final line = Isolate.run(_readLineSync);
    return timeout == null ? line : line.timeout(timeout, onTimeout: () => throw TimeoutException('no answer', timeout));
  }
  return _pipedLineChild(timeout);
}

/// A piped line that can be given up on: an isolate blocked in
/// `readLineSync` cannot be stopped and keeps the VM alive until a line
/// arrives, but a child shell's `read` (which, on a pipe, takes nothing
/// past the newline) can be killed. Its answer comes back through a temp
/// file, since the child shares our stdin and so all three streams.
Future<String?> _pipedLineChild(Duration timeout) async {
  final dir = await io.Directory.systemTemp.createTemp('dart_toolkit_ask');
  final out = '${dir.path}/line';
  try {
    final p = await io.Process.start('/bin/sh', [
      '-c',
      r'IFS= read -r l; r=$?; printf %s "$l" > "$0"; exit $r',
      out,
    ], mode: io.ProcessStartMode.inheritStdio);
    final code = await p.exitCode.timeout(
      timeout,
      onTimeout: () {
        p.kill(); // only this child: its `read` is ours to stop
        throw TimeoutException('no answer', timeout);
      },
    );
    final file = io.File(out);
    final bytes = await file.exists() ? await file.readAsBytes() : const <int>[];
    if (code != 0 && bytes.isEmpty) return null; // EOF
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    unawaited(dir.delete(recursive: true).then((_) {}, onError: (_) {}));
  }
}

String? _readLineSync() => io.stdin.readLineSync(encoding: const Utf8Codec(allowMalformed: true));
var _session = 0;

/// Set by the Tui while it runs: keys come from the terminal even when
/// stdin is a pipe (`ls | app`); Console prompts keep reading the pipe.
var ttyInput = false;

/// True when stdin is a pipe but the Tui can still reach the terminal
/// through /dev/tty (stdout is one).
bool get _pipedWithTty => !io.Platform.isWindows && !stdinTty && io.stdout.hasTerminal;

Future<void> _startInput() async {
  final session = ++_session;
  if (!io.Platform.isWindows && (stdinTty || ttyInput && _pipedWithTty)) {
    try {
      final tty = await io.Process.start('/bin/sh', ['-c', _ttyScript]);
      unawaited(tty.stderr.drain<void>());
      if (session != _session) {
        _endTty(tty); // cancelled (and maybe restarted) while starting
        return;
      }
      _tty = tty;
      _ttySub = tty.stdout.listen(
        _input.add,
        onError: _input.addError,
        onDone: () {
          if (!_input.isClosed) _input.close();
        },
      );
      return;
    } catch (_) {
      // No sh/cat or no /dev/tty: fall through to stdin itself.
    }
  }
  if (session != _session) return;
  _ttySub = (_stdinFallback ??= io.stdin.asBroadcastStream()).listen(
    _input.add,
    onError: _input.addError,
    onDone: () {
      if (!_input.isClosed) _input.close();
    },
  );
}

/// `cat` reads the terminal in the background; the foreground `cat` waits
/// for EOF on our pipe, then the reader is killed. Only that child.
const _ttyScript = 'trap "" INT; cat -u /dev/tty & c=\$!; cat >/dev/null; kill \$c 2>/dev/null';

/// Stop a tty child by closing its stdin pipe (its script then kills `cat`).
void _endTty(io.Process tty) {
  unawaited(tty.stdin.close().catchError((_) {}));
}

Future<void> _stopInput() async {
  _session++;
  final sub = _ttySub;
  _ttySub = null;
  final tty = _tty;
  _tty = null;
  // Bounded: a tty child that never closes its stdout must not keep the
  // process alive after the TUI is gone; its stdin pipe is still closed
  // below so the child can exit on its own.
  try {
    await sub?.cancel().timeout(const Duration(seconds: 2));
  } catch (_) {
    // Give up waiting: the stdin pipe below still lets the child exit.
  }
  if (tty == null) return;
  _endTty(tty);
  try {
    await tty.exitCode.timeout(const Duration(seconds: 1));
  } catch (_) {}
}

/// Saved stdin terminal modes, best-effort (a non-terminal stdin throws on
/// access, in which case there is nothing to save or restore).
final class TermModes {
  TermModes(this.echo, this.line, [this.win]);

  final bool? echo;
  final bool? line;

  /// Windows console input mode, restored as a whole.
  final int? win;

  /// True once [setRawModes] cleared `ISIG`; [restoreModes] sets it back.
  bool isigCleared = false;

  /// `stty -g` of /dev/tty when stdin is a pipe: modes go through stty.
  String? stty;
}

/// Capture the current echo/line modes.
TermModes captureModes() {
  if (ttyInput && _pipedWithTty) {
    // stdin is a pipe: save and set the terminal's own modes via /dev/tty.
    final saved = _stty('-g');
    if (saved != null) return TermModes(null, null, null)..stty = saved.trim();
  }
  bool? echo, line;
  try {
    echo = io.stdin.echoMode;
  } catch (_) {}
  try {
    line = io.stdin.lineMode;
  } catch (_) {}
  return TermModes(echo, line, win.inputMode());
}

/// `stty [args] </dev/tty`: its stdout, or null when it failed.
String? _stty(String args) {
  try {
    final r = io.Process.runSync('/bin/sh', ['-c', 'stty $args </dev/tty']);
    return r.exitCode == 0 ? '${r.stdout}' : null;
  } catch (_) {
    return null;
  }
}

bool _isig(bool on) {
  if (io.Platform.isWindows || !stdinTty) return false;
  try {
    return io.Process.runSync('/bin/sh', ['-c', 'stty ${on ? '' : '-'}isig </dev/tty']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Raw-ish mode for apps: no echo, no line buffering. Clearing `ICANON`
/// does not clear `ISIG`, so Ctrl-C still arrives as SIGINT. With
/// [signals] false (POSIX) `ISIG` is cleared too: Ctrl-C and Ctrl-Z then
/// arrive as the bytes `0x03` and `0x1a`, recorded in [modes] for
/// [restoreModes].
void setRawModes([TermModes? modes, bool signals = true]) {
  if (modes?.stty != null) {
    final ok = _stty('-icanon -echo min 1 time 0${signals ? '' : ' -isig'}') != null;
    modes!.isigCleared = !signals && ok;
    return;
  }
  try {
    io.stdin.echoMode = false;
  } catch (_) {}
  try {
    io.stdin.lineMode = false;
  } catch (_) {}
  win.enableVtInput();
  if (!signals && modes != null) modes.isigCleared = _isig(false);
}

/// True when single keypresses (arrows included) will actually arrive:
/// raw mode engages and sticks. Restores the terminal modes either way.
/// A half-applied raw mode (echo off, line buffering still on) is the
/// worst case (invisible typing that only arrives on Enter), so that
/// counts as unavailable too.
bool rawModeSticks() {
  final modes = captureModes();
  setRawModes();
  try {
    if (io.stdin.lineMode) return false;
  } catch (_) {
    return false;
  } finally {
    restoreModes(modes);
  }
  return true;
}

/// Cooked input, line by line, echoed unless [echo] is false (a secret).
/// Best-effort: a stdin that is not a terminal keeps its modes.
void setLineModes({bool echo = true}) {
  try {
    io.stdin.echoMode = echo;
  } catch (_) {}
  try {
    io.stdin.lineMode = true;
  } catch (_) {}
}

/// Restore modes captured by [captureModes].
void restoreModes(TermModes modes) {
  final saved = modes.stty;
  if (saved != null) {
    modes.isigCleared = false;
    _stty("'$saved'");
    return;
  }
  if (modes.isigCleared) {
    modes.isigCleared = false;
    _isig(true);
  }
  if (modes.echo != null) {
    try {
      io.stdin.echoMode = modes.echo!;
    } catch (_) {}
  }
  if (modes.line != null) {
    try {
      io.stdin.lineMode = modes.line!;
    } catch (_) {}
  }
  if (modes.win != null) win.setInputMode(modes.win!);
}

/// One progress line, `label bar counts rate`, fitted to [cols] cells, as
/// `Console.bar` and `Region.bar` draw it. The bar takes what the rest
/// leaves (at most 20 cells); when that is nothing, the label is cut with
/// `…`, then dropped, then the line is cut. An unknown [total] draws no
/// bar. Counts and [rate] read in [unit] (sizes, items, media time); a
/// null [rate] shows none.
String barLine(
  int cols, {
  String? label,
  required int done,
  int? total,
  Unit unit = Unit.items,
  double? rate,
  required bool ascii,
}) {
  if (cols <= 0) return '';
  final known = total != null && total > 0;
  final counts = fmtCounts(done, total, unit);
  final tail = rate == null ? counts : '$counts  ${fmtPace(rate, unit)}';
  final lab = label ?? '';
  final labW = lab.isEmpty ? 0 : displayWidth(lab) + 1;
  final tailW = displayWidth(tail);
  final barW = known ? (cols - labW - tailW - 2).clamp(0, 20) : 0;
  final body = barW > 0 ? '${barGlyphs(done, total, barW, ascii: ascii)}  $tail' : tail;
  final bodyW = barW > 0 ? barW + 2 + tailW : tailW;
  if (lab.isEmpty) return truncateWidth(body, cols);
  if (labW + bodyW <= cols) return '$lab $body';
  final room = cols - bodyW - 1;
  return room >= 2 ? '${truncateWidth(lab, room)} $body' : truncateWidth(body, cols);
}

/// Terminal capabilities for one run, shared by `console` and `tui`.
///
/// One detector for both. `FORCE_COLOR`/`NO_COLOR` follow
/// the env conventions: `NO_COLOR` (any value) drops styling, `FORCE_COLOR`
/// (`1`/`true`, case-insensitive) forces it even piped. Motion (live
/// spinners/bars, menu repaints) still needs a real terminal.
final class TerminalCaps {
  const TerminalCaps({
    required this.truecolor,
    required this.color256,
    required this.noColor,
    required this.ascii,
    required this.styled,
    required this.animated,
  });

  /// `TERM=dumb`: a terminal that takes no escape sequences.
  static bool isDumb(Map<String, String> env) => (env['TERM'] ?? '').toLowerCase() == 'dumb';

  /// Detect from [env] plus whether stderr/stdout are terminals.
  /// [hasTerminal] is stderr's (console) or stdout's (tui) terminal check;
  /// pass the stream the facade draws on.
  static TerminalCaps of(Map<String, String> env, {required bool hasTerminal}) {
    // no-color.org: set and not empty. FORCE_COLOR: any level (1-3, true)
    // but empty, 0 or false.
    final noColor = (env['NO_COLOR'] ?? '').isNotEmpty;
    final force = env['FORCE_COLOR']?.toLowerCase();
    final forced = force != null && force != '' && force != '0' && force != 'false';
    final colorterm = (env['COLORTERM'] ?? '').toLowerCase();
    final tm = (env['TERM'] ?? '').toLowerCase();
    final locale = [
      env['LC_ALL'],
      env['LC_CTYPE'],
      env['LANG'],
    ].firstWhere((v) => v != null && v.isNotEmpty, orElse: () => '')!.toLowerCase();
    final truecolor = colorterm.contains('truecolor') || colorterm.contains('24bit');
    final color256 = truecolor || tm.contains('256color');
    final ascii = !locale.contains('utf');
    // TERM=dumb (Emacs shell, some CI viewers) takes no escapes: no styling
    // unless forced, and no \r/erase animation.
    final dumb = tm == 'dumb';
    final styled = !noColor && (forced || hasTerminal && !dumb);
    // NO_COLOR is about colour only (no-color.org): motion stays.
    final animated = hasTerminal && !dumb;
    return TerminalCaps(
      truecolor: truecolor,
      color256: color256,
      noColor: noColor,
      ascii: ascii,
      styled: styled,
      animated: animated,
    );
  }

  /// Detect from the process environment and [io.stderr] (console default).
  /// Computed once per run (the environment and the terminal-ness of a
  /// stream do not change); [invalidate] drops it.
  static TerminalCaps get current => _stderr ??= of(io.Platform.environment, hasTerminal: _isTerminal(io.stderr));

  /// As [current], for [io.stdout] (what the Tui draws on).
  static TerminalCaps get forStdout => _stdout ??= of(io.Platform.environment, hasTerminal: _isTerminal(io.stdout));

  static TerminalCaps? _stderr;
  static TerminalCaps? _stdout;

  /// Drop the cached [current]/[forStdout] (the Tui calls this on resize).
  static void invalidate() => _stderr = _stdout = null;

  static bool _isTerminal(io.Stdout s) {
    try {
      return s.hasTerminal;
    } catch (_) {
      return false;
    }
  }

  final bool truecolor;
  final bool color256;
  final bool noColor;
  final bool ascii;

  /// Colour codes may be emitted.
  final bool styled;

  /// Live redraw may animate: a terminal that takes escapes. Independent
  /// of [styled]: `NO_COLOR` drops colour, not motion.
  final bool animated;
}

/// A terminal colour: a 256-palette index or an RGB triple.
/// Downgraded to the terminal's level at paint time (truecolor → 256 → 16;
/// `NO_COLOR` drops colours and keeps styles).
final class Color {
  /// The eight basic terminal colours and gray (the palette's 0–8): they
  /// follow the user's terminal theme.
  static const black = Color._(0, null);
  static const red = Color._(1, null);
  static const green = Color._(2, null);
  static const yellow = Color._(3, null);
  static const blue = Color._(4, null);
  static const magenta = Color._(5, null);
  static const cyan = Color._(6, null);
  static const white = Color._(7, null);
  static const gray = Color._(8, null);

  /// The shared live accent (xterm 173, a muted orange):
  /// a ready-made value for `Tui.run(accent:)`.
  static const orange = Color._(173, null);

  /// 0–255, else [ArgumentError].
  factory Color.index(int index) {
    if (index < 0 || index > 255) {
      throw ArgumentError.value(index, 'index', 'must be 0..255');
    }
    return Color._(index, null);
  }

  /// True colour where the terminal has it, else the nearest of the 256;
  /// each channel 0–255, else [ArgumentError].
  factory Color.rgb(int r, int g, int b) {
    for (final (n, v) in [('r', r), ('g', g), ('b', b)]) {
      if (v < 0 || v > 255) {
        throw ArgumentError.value(v, n, 'must be 0..255');
      }
    }
    return Color._(rgbTo256(r, g, b), (r, g, b));
  }

  const Color._(this._code, this._rgb);

  final int _code;
  final (int, int, int)? _rgb;

  @override
  bool operator ==(Object other) => other is Color && other._code == _code && other._rgb == _rgb;

  @override
  int get hashCode => Object.hash(_code, _rgb);
}

/// [c]'s xterm-256 index (the painters' read; not exported).
int colorCode(Color c) => c._code;

/// [c]'s 24-bit value when it was made with [Color.rgb] (not exported).
(int, int, int)? colorRgb(Color c) => c._rgb;

int rgbTo256(int r, int g, int b) {
  if (r == g && g == b) {
    if (r < 8) return 16;
    if (r > 248) return 231;
    return 232 + ((r - 8) * 24 ~/ 247).clamp(0, 23);
  }
  int c(int v) => (v / 51).round().clamp(0, 5);
  return 16 + 36 * c(r) + 6 * c(g) + c(b);
}

/// A desktop notification as escape codes: OSC 9 (iTerm2, WezTerm,
/// Windows Terminal), OSC 777 (rxvt-likes, kitty, foot) and a bell for the
/// rest. Controls in [message] are dropped (an OSC payload cannot show `�`).
String notifyCodes(String message) {
  final m = plainLabel(message).replaceAll('\uFFFD', '');
  // OSC 777 takes a title and a body; `;` would end the title early.
  final title = _scriptName().replaceAll(';', ' ');
  return '\x1b]9;$m\x07\x1b]777;notify;$title;$m\x07\x07';
}

/// The running script's name (`medialoader` for `medialoader.dart`), the
/// notification title.
String _scriptName() {
  final path = io.Platform.script.pathSegments.lastOrNull ?? '';
  final dot = path.indexOf('.');
  final name = dot < 0 ? path : path.substring(0, dot); // `x.dart`, a snapshot's `x.dart_2.dill`
  return name.isEmpty ? 'dart' : plainLabel(name);
}

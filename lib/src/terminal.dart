/// Shared private terminal layer for `tui` and `console`.
///
/// Not exported by either module: both import it by relative path and keep
/// their own public surface. It holds what the two must agree on: one
/// broadcast stdin, one key decoder, and saving/restoring terminal modes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'winconsole.dart' as win;

import 'sanitize.dart';
export 'sanitize.dart';

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
    StreamController<List<int>>.broadcast(onListen: _startInput, onCancel: _stopInput);

var _input = _makeInput();
io.Process? _tty;
StreamSubscription<List<int>>? _ttySub;
Stream<List<int>>? _stdinFallback;

/// True while no listener has taken stdin itself (the piped fallback), so a
/// synchronous `readLineSync` is still allowed and loses nothing.
bool get stdinUnclaimed => _stdinFallback == null;

/// One line of piped stdin (null at EOF) without blocking the event loop:
/// a helper isolate does the blocking `readLineSync`. It reads byte by
/// byte, so nothing past the line is consumed, and unlike a subscription it
/// neither drops lines that arrive between prompts nor keeps the script
/// alive until the writer closes the pipe. Only while [stdinUnclaimed].
Future<String?> pipedLine() => Isolate.run(_readLineSync);

String? _readLineSync() => io.stdin.readLineSync(encoding: const Utf8Codec(allowMalformed: true));
var _session = 0;

/// Set by the Tui while it runs: keys come from the terminal even when
/// stdin is a pipe (`ls | app`); Console prompts keep reading the pipe.
var ttyInput = false;

/// True when stdin is a pipe but the Tui can still reach the terminal
/// through /dev/tty (stdout is one).
bool get _pipedWithTty => !io.Platform.isWindows && !io.stdin.hasTerminal && io.stdout.hasTerminal;

Future<void> _startInput() async {
  final session = ++_session;
  if (!io.Platform.isWindows && (io.stdin.hasTerminal || ttyInput && _pipedWithTty)) {
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
  await sub?.cancel();
  if (tty != null) _endTty(tty);
}

/// A decoded input event.
sealed class TermEvent {}

/// A named key (`'a'`, `'enter'`, `'ctrl+c'`, `'shift+tab'`, …).
final class TermKey extends TermEvent {
  TermKey(this.name);

  final String name;
}

/// Printable text. When [paste] is true the text came from a bracketed paste
/// and must go to `typed()` only, never to `pressed`/`enter`/buttons.
final class TermType extends TermEvent {
  TermType(this.text, {this.paste = false});

  final String text;
  final bool paste;
}

/// A button press at cell (x, y), zero-based: [kind] is `click` (left),
/// `middleclick` or `rightclick`.
final class TermClick extends TermEvent {
  TermClick(this.x, this.y, [this.kind = 'click']);

  final int x;
  final int y;
  final String kind;
}

/// Pointer motion with no buttons pressed, at cell (x, y), zero-based.
/// Only sent when the terminal reports mouse motion (`?1003h`); plain clicks
/// (`?1000h`) never produce these, so engines that don't track hover can
/// ignore them.
final class TermHover extends TermEvent {
  TermHover(this.x, this.y);

  final int x;
  final int y;
}

/// Terminal window focus change (`?1004h` reports). Engines that don't track
/// focus can ignore these.
final class TermFocus extends TermEvent {
  TermFocus(this.gained);

  final bool gained;
}

/// Console-in-Tui routing: while a state-driven [Tui.run] is active,
/// `Console.spin`/`bar` draw in the status row (several at once) and
/// `ask`/`confirm`/`choose` open modal popups. The active session publishes
/// itself here; `console.dart` delegates when it is non-null.
abstract class TuiBridge {
  static TuiBridge? current;

  Object spinStarted(String label);
  void spinEnded(Object id, bool ok);
  Object barStarted(int? total, String? label);
  void barMode(Object id, bool bytes);
  void barTick(Object id, int count);
  void barEnded(Object id, bool ok);
  void barTotal(Object id, int? total);
  void log(String line);
  void notify(String message);
  void copy(String text);

  /// Prompts resolve null when the popup is cancelled (Escape, Ctrl-C).
  Future<String?> promptAsk(String question, {required bool secret});
  Future<bool?> promptConfirm(String question, bool or);
  Future<String?> promptChoose(String question, List<String> choices, int initial);
}

/// Decode raw stdin [bytes] into events. Returns the events plus how many
/// bytes were consumed; a trailing incomplete sequence (split ESC/CSI/SS3,
/// split UTF-8, an unterminated paste) is left unconsumed so the caller can
/// hold it for the next read instead of emitting mojibake.
({List<TermEvent> events, int consumed}) decodeKeys(List<int> bytes) {
  final out = <TermEvent>[];
  var i = 0;
  final text = StringBuffer();
  void flush() {
    if (text.isNotEmpty) {
      out.add(TermType(text.toString()));
      text.clear();
    }
  }

  while (i < bytes.length) {
    final b = bytes[i];
    if (b == 0x1b) {
      // Bracketed paste end is handled by the paste scanner below; a stray
      // `ESC [ 201 ~` outside a paste is ignored like any unknown CSI.
      if (i + 2 < bytes.length && bytes[i + 1] == 0x5b && bytes[i + 2] == 0x3c) {
        // Mouse SGR: ESC [ < btn ; x ; y M/m.
        var j = i + 3;
        while (j < bytes.length && bytes[j] != 0x4d && bytes[j] != 0x6d) {
          j++;
        }
        if (j >= bytes.length) break; // split across reads: hold.
        flush();
        List<String> parts;
        try {
          parts = ascii.decode(bytes.sublist(i + 3, j)).split(';');
        } catch (_) {
          // Non-ASCII params: unknown sequence, ignore.
          i = j + 1;
          continue;
        }
        if (parts.length >= 3) {
          final btn = int.tryParse(parts[0]) ?? -1;
          final x = (int.tryParse(parts[1]) ?? 1) - 1;
          final y = (int.tryParse(parts[2]) ?? 1) - 1;
          if (bytes[j] != 0x6d) _mouse(out, btn, x, y); // 'm' is a release
        }
        i = j + 1;
        continue;
      }
      if (i + 1 >= bytes.length) break; // lone trailing ESC: hold.
      final n1 = bytes[i + 1];
      if (n1 == 0x5b) {
        // CSI sequence: params in 0x30-0x3F, intermediates 0x20-0x2F.
        var j = i + 2;
        while (j < bytes.length && (bytes[j] < 0x40 || bytes[j] > 0x7e)) {
          j++;
        }
        if (j >= bytes.length) break; // split CSI: hold.
        // Bracketed paste: ESC [ 200 ~ … ESC [ 201 ~.
        if (_isPasteStart(bytes, i, j)) {
          final end = _pasteEnd(bytes, j + 1);
          if (end < 0) break; // unterminated: hold for the next read.
          flush();
          out.add(TermType(utf8.decode(bytes.sublist(j + 1, end), allowMalformed: true), paste: true));
          i = end + 6; // skip ESC [ 2 0 1 ~
          continue;
        }
        flush();
        String params;
        try {
          params = ascii.decode(bytes.sublist(i + 2, j));
        } catch (_) {
          // Non-ASCII CSI params: unknown sequence, ignore.
          i = j + 1;
          continue;
        }
        if (params.isEmpty && bytes[j] == 0x4d) {
          // Legacy X10 mouse (no SGR 1006, e.g. GNU screen): CSI M then
          // three raw bytes, button and 1-based x/y, each plus 32.
          if (j + 3 >= bytes.length) break; // split report: hold.
          final btn = bytes[j + 1] - 32;
          final valid = bytes[j + 1] >= 32 && bytes[j + 2] > 32 && bytes[j + 3] > 32;
          if (valid && btn & 3 != 3) _mouse(out, btn, bytes[j + 2] - 33, bytes[j + 3] - 33); // 3 is a release
          i = j + 4;
          continue;
        }
        final key = csiName(params, bytes[j]);
        if (key == 'focus') {
          out.add(TermFocus(true));
        } else if (key == 'blur') {
          out.add(TermFocus(false));
        } else if (key != null) {
          out.add(TermKey(key));
        }
        i = j + 1;
        continue;
      }
      if (n1 == 0x4f) {
        // SS3: F1-F4 on some terminals, arrows/home/end on others.
        if (i + 2 >= bytes.length) break;
        flush();
        final key = switch (bytes[i + 2]) {
          0x50 => 'f1',
          0x51 => 'f2',
          0x52 => 'f3',
          0x53 => 'f4',
          0x41 => 'up',
          0x42 => 'down',
          0x43 => 'right',
          0x44 => 'left',
          0x48 => 'home',
          0x46 => 'end',
          _ => null, // unknown SS3: ignore, never 'escape'.
        };
        if (key != null) out.add(TermKey(key));
        i += 3;
        continue;
      }
      if (n1 == 0x1b) {
        // ESC ESC: the escape key (also what some terminals send for it).
        flush();
        out.add(TermKey('escape'));
        i += 2;
        continue;
      }
      // Alt+<char>: decode one full UTF-8 char so Alt+é etc. are not mojibake.
      // Alt+Enter arrives as ESC CR (or ESC LF): name it directly.
      if ((n1 == 0x0d || n1 == 0x0a) && i + 1 < bytes.length) {
        flush();
        out.add(TermKey('alt+enter'));
        i += 2;
        continue;
      }
      if (n1 == 0x7f || n1 == 0x08) {
        flush();
        out.add(TermKey('alt+backspace'));
        i += 2;
        continue;
      }
      final width = _utf8Width(bytes, i + 1);
      if (width < 0) break; // split char: hold.
      flush();
      out.add(TermKey('alt+${utf8.decode(bytes.sublist(i + 1, i + 1 + width), allowMalformed: true)}'));
      i += 1 + width;
      continue;
    }
    if (b == 0xe0) {
      // Windows console extended keys: 0xE0 plus a scan code (< 0x80, so
      // never UTF-8 text) for arrows, home/end, page up/down, insert/delete.
      // A bare 0xE0 is also a UTF-8 lead byte; text falls through below.
      if (i + 1 >= bytes.length) break; // split across reads: hold.
      final String? win = windowsKey(bytes[i + 1]);
      if (win != null) {
        flush();
        out.add(TermKey(win));
        i += 2;
        continue;
      }
    }
    if (b == 0x09) {
      flush();
      out.add(TermKey('tab'));
      i++;
      continue;
    }
    if (b == 0x0d || b == 0x0a) {
      flush();
      out.add(TermKey('enter'));
      // Swallow a paired LF after CR.
      if (b == 0x0d && i + 1 < bytes.length && bytes[i + 1] == 0x0a) {
        i += 2;
      } else {
        i++;
      }
      continue;
    }
    if (b == 0x7f || b == 0x08) {
      flush();
      out.add(TermKey('backspace'));
      i++;
      continue;
    }
    if (b == 0x00) {
      flush();
      out.add(TermKey('ctrl+space'));
      i++;
      continue;
    }
    if (b == 0x1c) {
      flush();
      out.add(TermKey(r'ctrl+\'));
      i++;
      continue;
    }
    if (b == 0x1d) {
      flush();
      out.add(TermKey('ctrl+]'));
      i++;
      continue;
    }
    if (b == 0x1e) {
      flush();
      out.add(TermKey('ctrl+^'));
      i++;
      continue;
    }
    if (b == 0x1f) {
      flush();
      out.add(TermKey('ctrl+_'));
      i++;
      continue;
    }
    if (b < 0x20) {
      flush();
      // Ctrl+letter: 0x01..0x1A → a..z.
      out.add(TermKey('ctrl+${String.fromCharCode(b + 0x60)}'));
      i++;
      continue;
    }
    // Printable run: decode UTF-8 up to the next control/ESC.
    var j = i;
    while (j < bytes.length && bytes[j] >= 0x20 && bytes[j] != 0x1b && bytes[j] != 0x7f) {
      j++;
    }
    if (j > i && j == bytes.length) {
      // The run hits the buffer end: hold back a trailing UTF-8 char split
      // across reads instead of emitting mojibake.
      j = utf8Split(bytes, i, j);
      if (j == i) break;
    }
    flush();
    out.add(TermType(utf8.decode(bytes.sublist(i, j), allowMalformed: true)));
    i = j;
  }
  flush();
  return (events: out, consumed: i);
}

/// Name a CSI sequence, or null when it should be ignored (unknown
/// sequences are never reported as `escape`). [params] is the raw text
/// between `[` and the final byte [fin]. Modifiers (`;2` shift, `;3` alt,
/// `;5` ctrl and combinations) become `ctrl+`/`alt+`/`shift+` prefixes.
/// Focus reports (`CSI I`/`CSI O`, from `?1004h`) are returned as the
/// sentinel names `focus`/`blur` for [decodeKeys] to wrap.
/// One mouse press, wheel or motion report (SGR or X10) as events.
void _mouse(List<TermEvent> out, int btn, int x, int y) {
  if (btn & 64 != 0) {
    // Wheel: 64 = up, 65 = down; 66/67 are horizontal (trackpad swipes) and
    // scroll nothing. The pointer position comes first as a hover, so the
    // wheel goes to what is under it.
    if (btn & 3 > 1) return;
    out.add(TermHover(x, y));
    out.add(TermKey(btn & 3 == 1 ? 'wheeldown' : 'wheelup'));
  } else if (btn == 35) {
    // Motion with no buttons: hover position, not a click.
    out.add(TermHover(x, y));
  } else if (btn & 32 != 0) {
    // Drag (32): not a click, ignore.
  } else {
    // Press: left, middle or right.
    switch (btn & 3) {
      case 0:
        out.add(TermClick(x, y));
      case 1:
        out.add(TermClick(x, y, 'middleclick'));
      case 2:
        out.add(TermClick(x, y, 'rightclick'));
    }
  }
}

String? csiName(String params, int fin) {
  // Focus in/out reports.
  if (fin == 0x49 && params.isEmpty) return 'focus';
  if (fin == 0x4f && params.isEmpty) return 'blur';
  var prefix = '';
  var code = params;
  final semi = params.indexOf(';');
  if (semi != -1) {
    code = params.substring(0, semi);
    final modPart = params.substring(semi + 1).split(';').first.split(':').first;
    final mod = int.tryParse(modPart);
    if (mod != null && mod >= 2) {
      // Bits: 1 shift, 2 alt, 4 ctrl, 8 super; Caps Lock (64) and Num Lock
      // (128) ride along in the kitty protocol and must not drop the rest.
      final m = (mod - 1) & ~(64 | 128);
      if (m & 4 != 0) prefix += 'ctrl+';
      if (m & 2 != 0) prefix += 'alt+';
      if (m & 1 != 0) prefix += 'shift+';
    }
  }
  code = code.split(':').first;
  String? base;
  switch (fin) {
    case 0x41:
      base = 'up';
    case 0x42:
      base = 'down';
    case 0x43:
      base = 'right';
    case 0x44:
      base = 'left';
    case 0x48:
      base = 'home';
    case 0x46:
      base = 'end';
    case 0x5a:
      // Shift+Tab (CSI Z, no params on most terminals).
      return 'shift+tab';
    case 0x75:
      // Kitty keyboard protocol: CSI unicode-number [; modifiers] u.
      base = switch (code) {
        '9' || '57346' => 'tab',
        '13' || '57345' => 'enter',
        '27' || '57344' => 'escape',
        '32' => 'space',
        '127' || '57347' => 'backspace',
        '57348' => 'insert',
        '57349' => 'delete',
        '57350' => 'left',
        '57351' => 'right',
        '57352' => 'up',
        '57353' => 'down',
        '57354' => 'pageup',
        '57355' => 'pagedown',
        '57356' => 'home',
        '57357' => 'end',
        '57364' => 'f1',
        '57365' => 'f2',
        '57366' => 'f3',
        '57367' => 'f4',
        '57368' => 'f5',
        '57369' => 'f6',
        '57370' => 'f7',
        '57371' => 'f8',
        '57372' => 'f9',
        '57373' => 'f10',
        '57374' => 'f11',
        '57375' => 'f12',
        // Keypad keys (kitty reports them apart from the main keys).
        '57414' => 'enter',
        '57417' => 'left',
        '57418' => 'right',
        '57419' => 'up',
        '57420' => 'down',
        '57421' => 'pageup',
        '57422' => 'pagedown',
        '57423' => 'home',
        '57424' => 'end',
        '57425' => 'insert',
        '57426' => 'delete',
        // Other keys the protocol disambiguates (ctrl+c as `99;5u`).
        _ => switch (int.tryParse(code)) {
          final n? when n >= 57399 && n <= 57413 => '0123456789./*-+'[n - 57399],
          final n? when n > 0x20 && n < 0x7f || n >= 0xa0 && n < 57344 => String.fromCharCode(n),
          _ => null,
        },
      };
    case 0x7e:
      if (code == '27') {
        // xterm modifyOtherKeys: CSI 27 ; modifier ; charcode ~
        final parts = params.split(';');
        if (parts.length >= 3) {
          final charCode = int.tryParse(parts[2].split(':').first);
          if (charCode != null) {
            base = switch (charCode) {
              9 => 'tab',
              13 => 'enter',
              27 => 'escape',
              32 => 'space',
              127 => 'backspace',
              _ when charCode > 0x20 && charCode < 0x7f => String.fromCharCode(charCode).toLowerCase(),
              _ => null,
            };
          }
        }
        break;
      }
      base = switch (code) {
        '1' || '7' => 'home',
        '2' => 'insert',
        '3' => 'delete',
        '4' || '8' => 'end',
        '5' => 'pageup',
        '6' => 'pagedown',
        '11' || '12' || '13' || '14' || '15' => 'f${int.parse(code) - 10}',
        '17' || '18' || '19' || '20' || '21' => 'f${int.parse(code) - 11}',
        '23' || '24' => 'f${int.parse(code) - 12}',
        _ => null,
      };
    default:
      return null;
  }
  if (base == null) return null;
  if (prefix.isEmpty) return base;
  // A bare modifier on tab/arrows is the point (ctrl+up); shift+letter is
  // just the letter, which arrives as typed text, so keep the prefix only
  // for non-printable bases.
  return '$prefix$base';
}

/// Name a Windows console extended key (`0xE0` + [code]), or null when
/// [code] is not a known navigation scan code.
String? windowsKey(int code) {
  switch (code) {
    case 0x48:
      return 'up';
    case 0x50:
      return 'down';
    case 0x4b:
      return 'left';
    case 0x4d:
      return 'right';
    case 0x47:
      return 'home';
    case 0x4f:
      return 'end';
    case 0x49:
      return 'pageup';
    case 0x51:
      return 'pagedown';
    case 0x52:
      return 'insert';
    case 0x53:
      return 'delete';
    default:
      return null;
  }
}

/// Pull [end] back past a trailing UTF-8 sequence split across reads.
int utf8Split(List<int> bytes, int start, int end) {
  var k = end - 1;
  while (k >= start && bytes[k] & 0xc0 == 0x80) {
    k--;
  }
  if (k < start) return end; // orphaned continuation bytes cannot be completed; consume them
  final lead = bytes[k];
  final want = lead < 0x80
      ? 1
      : lead < 0xe0
      ? 2
      : lead < 0xf0
      ? 3
      : 4;
  if (end - k < want) return k; // incomplete: hold from the lead byte
  return end;
}

/// Width of the UTF-8 char starting at [at], or -1 when split across reads.
int _utf8Width(List<int> bytes, int at) {
  if (at >= bytes.length) return -1;
  final lead = bytes[at];
  if (lead < 0x80) return 1;
  if (lead < 0xc2) return 1; // stray continuation: one mojibake char.
  final want = lead < 0xe0
      ? 2
      : lead < 0xf0
      ? 3
      : 4;
  if (at + want > bytes.length) {
    // Might be split — or truncated; hold only when the bytes present so
    // far are well-formed so a truncated tail is held, not dropped.
    for (var k = at + 1; k < bytes.length; k++) {
      if (bytes[k] & 0xc0 != 0x80) return 1;
    }
    return -1;
  }
  return want;
}

bool _isPasteStart(List<int> bytes, int i, int j) =>
    j == i + 5 && bytes[i + 2] == 0x32 && bytes[i + 3] == 0x30 && bytes[i + 4] == 0x30 && bytes[j] == 0x7e;

/// Offset of the ESC starting `ESC [ 201 ~` at/after [from], or -1 when the
/// paste is unterminated so far.
int _pasteEnd(List<int> bytes, int from) {
  for (var k = from; k + 5 < bytes.length; k++) {
    if (bytes[k] == 0x1b &&
        bytes[k + 1] == 0x5b &&
        bytes[k + 2] == 0x32 &&
        bytes[k + 3] == 0x30 &&
        bytes[k + 4] == 0x31 &&
        bytes[k + 5] == 0x7e) {
      return k;
    }
  }
  return -1;
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
  if (io.Platform.isWindows || !io.stdin.hasTerminal) return false;
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

/// True for runes that take no cell and attach to the previous cell's
/// string: combining marks, ZWJ/ZWNJ, variation selectors, emoji
/// modifiers, tags.
bool isZeroWidth(int rune) {
  if (rune < 0x300) return false;
  // Emoji skin-tone modifiers join the emoji before them.
  if (rune >= 0x1f3fb && rune <= 0x1f3ff) return true;
  // Binary search over [_zeroWidth]'s inclusive (first, last) pairs.
  var lo = 0, hi = _zeroWidth.length ~/ 2 - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (rune < _zeroWidth[mid * 2]) {
      hi = mid - 1;
    } else if (rune > _zeroWidth[mid * 2 + 1]) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

/// Zero-width code points as inclusive (first, last) pairs, from Unicode
/// 16.0 like `wcwidth`: nonspacing and enclosing marks (Mn, Me), format
/// characters (Cf) except the soft hyphen, Hangul medial and final jamo, and
/// U+200B. Generated with Python's `unicodedata`; regenerate on a Unicode bump.
const _zeroWidth = <int>[
  0x300,
  0x36f,
  0x483,
  0x489,
  0x591,
  0x5bd,
  0x5bf,
  0x5bf,
  0x5c1,
  0x5c2,
  0x5c4,
  0x5c5,
  0x5c7,
  0x5c7,
  0x600,
  0x605,
  0x610,
  0x61a,
  0x61c,
  0x61c,
  0x64b,
  0x65f,
  0x670,
  0x670,
  0x6d6,
  0x6dd,
  0x6df,
  0x6e4,
  0x6e7,
  0x6e8,
  0x6ea,
  0x6ed,
  0x70f,
  0x70f,
  0x711,
  0x711,
  0x730,
  0x74a,
  0x7a6,
  0x7b0,
  0x7eb,
  0x7f3,
  0x7fd,
  0x7fd,
  0x816,
  0x819,
  0x81b,
  0x823,
  0x825,
  0x827,
  0x829,
  0x82d,
  0x859,
  0x85b,
  0x890,
  0x891,
  0x897,
  0x89f,
  0x8ca,
  0x902,
  0x93a,
  0x93a,
  0x93c,
  0x93c,
  0x941,
  0x948,
  0x94d,
  0x94d,
  0x951,
  0x957,
  0x962,
  0x963,
  0x981,
  0x981,
  0x9bc,
  0x9bc,
  0x9c1,
  0x9c4,
  0x9cd,
  0x9cd,
  0x9e2,
  0x9e3,
  0x9fe,
  0x9fe,
  0xa01,
  0xa02,
  0xa3c,
  0xa3c,
  0xa41,
  0xa42,
  0xa47,
  0xa48,
  0xa4b,
  0xa4d,
  0xa51,
  0xa51,
  0xa70,
  0xa71,
  0xa75,
  0xa75,
  0xa81,
  0xa82,
  0xabc,
  0xabc,
  0xac1,
  0xac5,
  0xac7,
  0xac8,
  0xacd,
  0xacd,
  0xae2,
  0xae3,
  0xafa,
  0xaff,
  0xb01,
  0xb01,
  0xb3c,
  0xb3c,
  0xb3f,
  0xb3f,
  0xb41,
  0xb44,
  0xb4d,
  0xb4d,
  0xb55,
  0xb56,
  0xb62,
  0xb63,
  0xb82,
  0xb82,
  0xbc0,
  0xbc0,
  0xbcd,
  0xbcd,
  0xc00,
  0xc00,
  0xc04,
  0xc04,
  0xc3c,
  0xc3c,
  0xc3e,
  0xc40,
  0xc46,
  0xc48,
  0xc4a,
  0xc4d,
  0xc55,
  0xc56,
  0xc62,
  0xc63,
  0xc81,
  0xc81,
  0xcbc,
  0xcbc,
  0xcbf,
  0xcbf,
  0xcc6,
  0xcc6,
  0xccc,
  0xccd,
  0xce2,
  0xce3,
  0xd00,
  0xd01,
  0xd3b,
  0xd3c,
  0xd41,
  0xd44,
  0xd4d,
  0xd4d,
  0xd62,
  0xd63,
  0xd81,
  0xd81,
  0xdca,
  0xdca,
  0xdd2,
  0xdd4,
  0xdd6,
  0xdd6,
  0xe31,
  0xe31,
  0xe34,
  0xe3a,
  0xe47,
  0xe4e,
  0xeb1,
  0xeb1,
  0xeb4,
  0xebc,
  0xec8,
  0xece,
  0xf18,
  0xf19,
  0xf35,
  0xf35,
  0xf37,
  0xf37,
  0xf39,
  0xf39,
  0xf71,
  0xf7e,
  0xf80,
  0xf84,
  0xf86,
  0xf87,
  0xf8d,
  0xf97,
  0xf99,
  0xfbc,
  0xfc6,
  0xfc6,
  0x102d,
  0x1030,
  0x1032,
  0x1037,
  0x1039,
  0x103a,
  0x103d,
  0x103e,
  0x1058,
  0x1059,
  0x105e,
  0x1060,
  0x1071,
  0x1074,
  0x1082,
  0x1082,
  0x1085,
  0x1086,
  0x108d,
  0x108d,
  0x109d,
  0x109d,
  0x1160,
  0x11ff,
  0x135d,
  0x135f,
  0x1712,
  0x1714,
  0x1732,
  0x1733,
  0x1752,
  0x1753,
  0x1772,
  0x1773,
  0x17b4,
  0x17b5,
  0x17b7,
  0x17bd,
  0x17c6,
  0x17c6,
  0x17c9,
  0x17d3,
  0x17dd,
  0x17dd,
  0x180b,
  0x180f,
  0x1885,
  0x1886,
  0x18a9,
  0x18a9,
  0x1920,
  0x1922,
  0x1927,
  0x1928,
  0x1932,
  0x1932,
  0x1939,
  0x193b,
  0x1a17,
  0x1a18,
  0x1a1b,
  0x1a1b,
  0x1a56,
  0x1a56,
  0x1a58,
  0x1a5e,
  0x1a60,
  0x1a60,
  0x1a62,
  0x1a62,
  0x1a65,
  0x1a6c,
  0x1a73,
  0x1a7c,
  0x1a7f,
  0x1a7f,
  0x1ab0,
  0x1ace,
  0x1b00,
  0x1b03,
  0x1b34,
  0x1b34,
  0x1b36,
  0x1b3a,
  0x1b3c,
  0x1b3c,
  0x1b42,
  0x1b42,
  0x1b6b,
  0x1b73,
  0x1b80,
  0x1b81,
  0x1ba2,
  0x1ba5,
  0x1ba8,
  0x1ba9,
  0x1bab,
  0x1bad,
  0x1be6,
  0x1be6,
  0x1be8,
  0x1be9,
  0x1bed,
  0x1bed,
  0x1bef,
  0x1bf1,
  0x1c2c,
  0x1c33,
  0x1c36,
  0x1c37,
  0x1cd0,
  0x1cd2,
  0x1cd4,
  0x1ce0,
  0x1ce2,
  0x1ce8,
  0x1ced,
  0x1ced,
  0x1cf4,
  0x1cf4,
  0x1cf8,
  0x1cf9,
  0x1dc0,
  0x1dff,
  0x200b,
  0x200f,
  0x202a,
  0x202e,
  0x2060,
  0x2064,
  0x2066,
  0x206f,
  0x20d0,
  0x20f0,
  0x2cef,
  0x2cf1,
  0x2d7f,
  0x2d7f,
  0x2de0,
  0x2dff,
  0x302a,
  0x302d,
  0x3099,
  0x309a,
  0xa66f,
  0xa672,
  0xa674,
  0xa67d,
  0xa69e,
  0xa69f,
  0xa6f0,
  0xa6f1,
  0xa802,
  0xa802,
  0xa806,
  0xa806,
  0xa80b,
  0xa80b,
  0xa825,
  0xa826,
  0xa82c,
  0xa82c,
  0xa8c4,
  0xa8c5,
  0xa8e0,
  0xa8f1,
  0xa8ff,
  0xa8ff,
  0xa926,
  0xa92d,
  0xa947,
  0xa951,
  0xa980,
  0xa982,
  0xa9b3,
  0xa9b3,
  0xa9b6,
  0xa9b9,
  0xa9bc,
  0xa9bd,
  0xa9e5,
  0xa9e5,
  0xaa29,
  0xaa2e,
  0xaa31,
  0xaa32,
  0xaa35,
  0xaa36,
  0xaa43,
  0xaa43,
  0xaa4c,
  0xaa4c,
  0xaa7c,
  0xaa7c,
  0xaab0,
  0xaab0,
  0xaab2,
  0xaab4,
  0xaab7,
  0xaab8,
  0xaabe,
  0xaabf,
  0xaac1,
  0xaac1,
  0xaaec,
  0xaaed,
  0xaaf6,
  0xaaf6,
  0xabe5,
  0xabe5,
  0xabe8,
  0xabe8,
  0xabed,
  0xabed,
  0xd7b0,
  0xd7ff,
  0xfb1e,
  0xfb1e,
  0xfe00,
  0xfe0f,
  0xfe20,
  0xfe2f,
  0xfeff,
  0xfeff,
  0xfff9,
  0xfffb,
  0x101fd,
  0x101fd,
  0x102e0,
  0x102e0,
  0x10376,
  0x1037a,
  0x10a01,
  0x10a03,
  0x10a05,
  0x10a06,
  0x10a0c,
  0x10a0f,
  0x10a38,
  0x10a3a,
  0x10a3f,
  0x10a3f,
  0x10ae5,
  0x10ae6,
  0x10d24,
  0x10d27,
  0x10d69,
  0x10d6d,
  0x10eab,
  0x10eac,
  0x10efc,
  0x10eff,
  0x10f46,
  0x10f50,
  0x10f82,
  0x10f85,
  0x11001,
  0x11001,
  0x11038,
  0x11046,
  0x11070,
  0x11070,
  0x11073,
  0x11074,
  0x1107f,
  0x11081,
  0x110b3,
  0x110b6,
  0x110b9,
  0x110ba,
  0x110bd,
  0x110bd,
  0x110c2,
  0x110c2,
  0x110cd,
  0x110cd,
  0x11100,
  0x11102,
  0x11127,
  0x1112b,
  0x1112d,
  0x11134,
  0x11173,
  0x11173,
  0x11180,
  0x11181,
  0x111b6,
  0x111be,
  0x111c9,
  0x111cc,
  0x111cf,
  0x111cf,
  0x1122f,
  0x11231,
  0x11234,
  0x11234,
  0x11236,
  0x11237,
  0x1123e,
  0x1123e,
  0x11241,
  0x11241,
  0x112df,
  0x112df,
  0x112e3,
  0x112ea,
  0x11300,
  0x11301,
  0x1133b,
  0x1133c,
  0x11340,
  0x11340,
  0x11366,
  0x1136c,
  0x11370,
  0x11374,
  0x113bb,
  0x113c0,
  0x113ce,
  0x113ce,
  0x113d0,
  0x113d0,
  0x113d2,
  0x113d2,
  0x113e1,
  0x113e2,
  0x11438,
  0x1143f,
  0x11442,
  0x11444,
  0x11446,
  0x11446,
  0x1145e,
  0x1145e,
  0x114b3,
  0x114b8,
  0x114ba,
  0x114ba,
  0x114bf,
  0x114c0,
  0x114c2,
  0x114c3,
  0x115b2,
  0x115b5,
  0x115bc,
  0x115bd,
  0x115bf,
  0x115c0,
  0x115dc,
  0x115dd,
  0x11633,
  0x1163a,
  0x1163d,
  0x1163d,
  0x1163f,
  0x11640,
  0x116ab,
  0x116ab,
  0x116ad,
  0x116ad,
  0x116b0,
  0x116b5,
  0x116b7,
  0x116b7,
  0x1171d,
  0x1171d,
  0x1171f,
  0x1171f,
  0x11722,
  0x11725,
  0x11727,
  0x1172b,
  0x1182f,
  0x11837,
  0x11839,
  0x1183a,
  0x1193b,
  0x1193c,
  0x1193e,
  0x1193e,
  0x11943,
  0x11943,
  0x119d4,
  0x119d7,
  0x119da,
  0x119db,
  0x119e0,
  0x119e0,
  0x11a01,
  0x11a0a,
  0x11a33,
  0x11a38,
  0x11a3b,
  0x11a3e,
  0x11a47,
  0x11a47,
  0x11a51,
  0x11a56,
  0x11a59,
  0x11a5b,
  0x11a8a,
  0x11a96,
  0x11a98,
  0x11a99,
  0x11c30,
  0x11c36,
  0x11c38,
  0x11c3d,
  0x11c3f,
  0x11c3f,
  0x11c92,
  0x11ca7,
  0x11caa,
  0x11cb0,
  0x11cb2,
  0x11cb3,
  0x11cb5,
  0x11cb6,
  0x11d31,
  0x11d36,
  0x11d3a,
  0x11d3a,
  0x11d3c,
  0x11d3d,
  0x11d3f,
  0x11d45,
  0x11d47,
  0x11d47,
  0x11d90,
  0x11d91,
  0x11d95,
  0x11d95,
  0x11d97,
  0x11d97,
  0x11ef3,
  0x11ef4,
  0x11f00,
  0x11f01,
  0x11f36,
  0x11f3a,
  0x11f40,
  0x11f40,
  0x11f42,
  0x11f42,
  0x11f5a,
  0x11f5a,
  0x13430,
  0x13440,
  0x13447,
  0x13455,
  0x1611e,
  0x16129,
  0x1612d,
  0x1612f,
  0x16af0,
  0x16af4,
  0x16b30,
  0x16b36,
  0x16f4f,
  0x16f4f,
  0x16f8f,
  0x16f92,
  0x16fe4,
  0x16fe4,
  0x1bc9d,
  0x1bc9e,
  0x1bca0,
  0x1bca3,
  0x1cf00,
  0x1cf2d,
  0x1cf30,
  0x1cf46,
  0x1d167,
  0x1d169,
  0x1d173,
  0x1d182,
  0x1d185,
  0x1d18b,
  0x1d1aa,
  0x1d1ad,
  0x1d242,
  0x1d244,
  0x1da00,
  0x1da36,
  0x1da3b,
  0x1da6c,
  0x1da75,
  0x1da75,
  0x1da84,
  0x1da84,
  0x1da9b,
  0x1da9f,
  0x1daa1,
  0x1daaf,
  0x1e000,
  0x1e006,
  0x1e008,
  0x1e018,
  0x1e01b,
  0x1e021,
  0x1e023,
  0x1e024,
  0x1e026,
  0x1e02a,
  0x1e08f,
  0x1e08f,
  0x1e130,
  0x1e136,
  0x1e2ae,
  0x1e2ae,
  0x1e2ec,
  0x1e2ef,
  0x1e4ec,
  0x1e4ef,
  0x1e5ee,
  0x1e5ef,
  0x1e8d0,
  0x1e8d6,
  0x1e944,
  0x1e94a,
  0xe0001,
  0xe0001,
  0xe0020,
  0xe007f,
  0xe0100,
  0xe01ef,
];

/// Cells taken by [rune] on screen: 2 for wide CJK and emoji, else 1
/// (zero-width runes are answered by [isZeroWidth], not here).
int cellWidth(int rune) {
  if (rune < 0x1100) return 1;
  // Symbols (U+2000–2BFF) are narrow — `✓ ✗ ✻ ❯ ★ ⚠ ←` — except the ones
  // with emoji presentation, which terminals draw two cells wide.
  if (rune >= 0x2000 && rune <= 0x2bff) {
    return _wideSymbols.contains(rune) ? 2 : 1;
  }
  if (rune <= 0x115f) return 2;
  if (rune == 0x2329 || rune == 0x232a) return 2;
  if (rune >= 0x2e80 && rune <= 0xa4cf && rune != 0x303f) return 2;
  if (rune >= 0xac00 && rune <= 0xd7a3) return 2;
  if (rune >= 0xf900 && rune <= 0xfaff) return 2;
  if (rune >= 0xfe10 && rune <= 0xfe19) return 2;
  if (rune >= 0xfe30 && rune <= 0xfe4f) return 2;
  if (rune >= 0xff00 && rune <= 0xff60) return 2;
  if (rune >= 0xffe0 && rune <= 0xffe6) return 2;
  if (rune >= 0x1f000 && rune <= 0x1faff) return _wideEmoji(rune) ? 2 : 1;
  if (rune >= 0x20000 && rune <= 0x3fffd) return 2;
  return 1;
}

/// Display width of [text] in cells (zero-width runes attach for free).
int displayWidth(String text) {
  var w = 0;
  for (final rune in text.runes) {
    if (!isZeroWidth(rune)) w += cellWidth(rune);
  }
  return w;
}

/// Cut [text] to at most [width] cells, ending with `…` when cut. Wide
/// chars that don't fit are dropped whole.
String truncateWidth(String text, int width) {
  if (width <= 0) return '';
  if (displayWidth(text) <= width) return text;
  if (width == 1) return '…';
  final buf = StringBuffer();
  var w = 0;
  for (final rune in text.runes) {
    if (isZeroWidth(rune)) {
      buf.writeCharCode(rune);
      continue;
    }
    final cw = cellWidth(rune);
    if (w + cw + 1 > width) break;
    buf.writeCharCode(rune);
    w += cw;
  }
  buf.write('…');
  return buf.toString();
}

/// BMP symbols with Emoji_Presentation (Unicode 15): drawn two cells wide.
const _wideSymbols = {
  0x231a, 0x231b, 0x2329, 0x232a, 0x23e9, 0x23ea, 0x23eb, 0x23ec, 0x23f0, 0x23f3, //
  0x25fd, 0x25fe, 0x2614, 0x2615, 0x2648, 0x2649, 0x264a, 0x264b,
  0x264c, 0x264d, 0x264e, 0x264f, 0x2650, 0x2651, 0x2652, 0x2653,
  0x267f, 0x2693, 0x26a1, 0x26aa, 0x26ab, 0x26bd, 0x26be, 0x26c4,
  0x26c5, 0x26ce, 0x26d4, 0x26ea, 0x26f2, 0x26f3, 0x26f5, 0x26fa,
  0x26fd, 0x2705, 0x270a, 0x270b, 0x2728, 0x274c, 0x274e, 0x2753,
  0x2754, 0x2755, 0x2757, 0x2795, 0x2796, 0x2797, 0x27b0, 0x27bf,
  0x2b1b, 0x2b1c, 0x2b50, 0x2b55,
};

/// U+1F000–1FAFF: the emoji blocks are wide; enclosed alphanumerics,
/// ornaments, alchemy and arrows are narrow.
bool _wideEmoji(int rune) =>
    rune == 0x1f004 ||
    rune == 0x1f0cf ||
    rune == 0x1f18e ||
    (rune >= 0x1f191 && rune <= 0x1f19a) ||
    (rune >= 0x1f200 && rune <= 0x1f64f) ||
    (rune >= 0x1f680 && rune <= 0x1f6ff) ||
    (rune >= 0x1f7e0 && rune <= 0x1f7eb) ||
    (rune >= 0x1f90c && rune <= 0x1f9ff) ||
    (rune >= 0x1fa70 && rune <= 0x1faff);

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
    final noColor = env['NO_COLOR'] != null;
    final force = env['FORCE_COLOR']?.toLowerCase();
    final forced = force == '1' || force == 'true' || force == 'always';
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
  /// a ready-made value for `Tui.run(accent:)` and `Console.accent`.
  static const orange = Color._(173, null);

  /// 0–255, else [ArgumentError].
  factory Color.index(int index) {
    if (index < 0 || index > 255) {
      throw ArgumentError.value(index, 'index', 'must be 0..255');
    }
    return Color._(index, null);
  }

  factory Color.rgb(int r, int g, int b) {
    for (final (n, v) in [('r', r), ('g', g), ('b', b)]) {
      if (v < 0 || v > 255) {
        throw ArgumentError.value(v, n, 'must be 0..255');
      }
    }
    return Color._(rgbTo256(r, g, b), (r, g, b));
  }

  const Color._(this.code, this.rgb);

  final int code;
  final (int, int, int)? rgb;

  @override
  bool operator ==(Object other) => other is Color && other.code == code && other.rgb == rgb;

  @override
  int get hashCode => Object.hash(code, rgb);
}

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
  return '\x1b]9;$m\x07\x1b]777;notify;$m\x07\x07';
}

/// Clipboard copy as OSC 52 (base64, so [text] cannot break out).
String copyCodes(String text) => '\x1b]52;c;${base64.encode(utf8.encode(text))}\x1b\\';

/// Shared private terminal layer for `tui` and `console`.
///
/// Not exported by either module: both import it by relative path and keep
/// their own public surface. It holds what the two must agree on: one
/// broadcast stdin, one key decoder (the key names of VISION §4.12), and
/// saving/restoring the terminal modes.
library;

// ignore_for_file: avoid_dynamic_calls

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

/// Terminal input for `Tui.run` and the prompts, as a broadcast stream that
/// can be listened to again after every listener has cancelled — and that
/// lets the process exit once nobody listens.
///
/// `dart:io` allows one listener on stdin per process, and that listener
/// keeps the process alive even when paused. So on a POSIX terminal the
/// bytes come from a child `cat -u /dev/tty`, started on the first listen
/// and killed on the last cancel. The child ignores SIGINT, so Ctrl-C still
/// reaches us (as a key, or as the prompt's exit). Piped stdin, Windows, or
/// a missing `cat` fall back to stdin itself, which ends at EOF.
Stream<List<int>> sharedStdin() {
  if (_input.isClosed) _input = _makeInput();
  return _input.stream;
}

StreamController<List<int>> _makeInput() => StreamController<List<int>>.broadcast(
      onListen: _startInput,
      onCancel: _stopInput,
    );

var _input = _makeInput();
io.Process? _tty;
StreamSubscription<List<int>>? _ttySub;
Stream<List<int>>? _stdinFallback;
var _session = 0;

Future<void> _startInput() async {
  final session = ++_session;
  if (!io.Platform.isWindows && io.stdin.hasTerminal) {
    try {
      final tty = await io.Process.start(
          '/bin/sh', ['-c', 'trap "" INT; exec cat -u /dev/tty']);
      unawaited(tty.stderr.drain<void>());
      if (session != _session) {
        tty.kill(); // cancelled (and maybe restarted) while starting
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

Future<void> _stopInput() async {
  _session++;
  final sub = _ttySub;
  _ttySub = null;
  _tty?.kill();
  _tty = null;
  await sub?.cancel();
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
  Future<String> promptAsk(String question, {required bool secret});
  Future<bool> promptConfirm(String question);
  Future<String> promptChoose(String question, List<String> choices);
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
      if (i + 2 < bytes.length &&
          bytes[i + 1] == 0x5b &&
          bytes[i + 2] == 0x3c) {
        // Mouse SGR: ESC [ < btn ; x ; y M/m.
        var j = i + 3;
        while (j < bytes.length &&
            bytes[j] != 0x4d &&
            bytes[j] != 0x6d) {
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
          final isRelease = bytes[j] == 0x6d;
          if (!isRelease) {
            if (btn & 64 != 0) {
              // Wheel: 64 = up, 65 = down. The pointer position comes
              // first as a hover, so the wheel goes to what is under it.
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
        }
        i = j + 1;
        continue;
      }
      if (i + 1 >= bytes.length) break; // lone trailing ESC: hold.
      final n1 = bytes[i + 1];
      if (n1 == 0x5b) {
        // CSI sequence: params in 0x30-0x3F, intermediates 0x20-0x2F.
        var j = i + 2;
        while (j < bytes.length &&
            (bytes[j] < 0x40 || bytes[j] > 0x7e)) {
          j++;
        }
        if (j >= bytes.length) break; // split CSI: hold.
        // Bracketed paste: ESC [ 200 ~ … ESC [ 201 ~.
        if (_isPasteStart(bytes, i, j)) {
          final end = _pasteEnd(bytes, j + 1);
          if (end < 0) break; // unterminated: hold for the next read.
          flush();
          out.add(TermType(
            utf8.decode(bytes.sublist(j + 1, end), allowMalformed: true),
            paste: true,
          ));
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
      out.add(TermKey(
        'alt+${utf8.decode(bytes.sublist(i + 1, i + 1 + width), allowMalformed: true)}',
      ));
      i += 1 + width;
      continue;
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
    while (j < bytes.length &&
        bytes[j] >= 0x20 &&
        bytes[j] != 0x1b &&
        bytes[j] != 0x7f) {
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
String? csiName(String params, int fin) {
  // Focus in/out reports.
  if (fin == 0x49 && params.isEmpty) return 'focus';
  if (fin == 0x4f && params.isEmpty) return 'blur';
  var prefix = '';
  var code = params;
  final semi = params.indexOf(';');
  if (semi != -1) {
    code = params.substring(0, semi);
    final modPart =
        params.substring(semi + 1).split(';').first.split(':').first;
    final mod = int.tryParse(modPart);
    if (mod != null && mod >= 2 && mod <= 8) {
      final m = mod - 1;
      if (m & 4 != 0) prefix += 'ctrl+';
      if (m & 2 != 0) prefix += 'alt+';
      if (m & 1 != 0) prefix += 'shift+';
    }
  }
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
        '9' => 'tab',
        '13' => 'enter',
        '27' => 'escape',
        '32' => 'space',
        '127' => 'backspace',
        // Other keys the protocol disambiguates (ctrl+c as `99;5u`).
        _ => switch (int.tryParse(code)) {
            final n? when n > 0x20 && n < 0x7f => String.fromCharCode(n),
            _ => null,
          },
      };
    case 0x7e:
      base = switch (code) {
        '1' || '7' => 'home',
        '2' => 'insert',
        '3' => 'delete',
        '4' || '8' => 'end',
        '5' => 'pageup',
        '6' => 'pagedown',
        '11' || '12' || '13' || '14' || '15' =>
          'f${int.parse(code) - 10}',
        '17' || '18' || '19' || '20' || '21' =>
          'f${int.parse(code) - 11}',
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
  final want = lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
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
    j == i + 5 &&
    bytes[i + 2] == 0x32 &&
    bytes[i + 3] == 0x30 &&
    bytes[i + 4] == 0x30 &&
    bytes[j] == 0x7e;

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
final class TermModes {  TermModes(this.echo, this.line);

  final bool? echo;
  final bool? line;
}

/// Capture the current echo/line modes.
TermModes captureModes() {
  bool? echo, line;
  try {
    echo = io.stdin.echoMode;
  } catch (_) {}
  try {
    line = io.stdin.lineMode;
  } catch (_) {}
  return TermModes(echo, line);
}

/// Raw-ish mode for apps: no echo, no line buffering. (Clearing `ICANON`
/// does not clear `ISIG`, so Ctrl-C still arrives as SIGINT — which we
/// trap and report as `pressed('ctrl+c')`.)
void setRawModes() {
  try {
    io.stdin.echoMode = false;
  } catch (_) {}
  try {
    io.stdin.lineMode = false;
  } catch (_) {}
}

/// Restore modes captured by [captureModes].
void restoreModes(TermModes modes) {
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
}

/// True for runes that take no cell and attach to the previous cell's
/// string: combining marks, ZWJ/ZWNJ, variation selectors, emoji
/// modifiers, tags.
bool isZeroWidth(int rune) =>
    (rune >= 0x0300 && rune <= 0x036f) ||
    (rune >= 0x0483 && rune <= 0x0489) ||
    (rune >= 0x1ab0 && rune <= 0x1aff) ||
    (rune >= 0x1dc0 && rune <= 0x1dff) ||
    (rune >= 0x20d0 && rune <= 0x20ff) ||
    (rune >= 0xfe00 && rune <= 0xfe0f) ||
    rune == 0x200c ||
    rune == 0x200d ||
    (rune >= 0x1f3fb && rune <= 0x1f3ff) ||
    (rune >= 0xe0020 && rune <= 0xe007f);

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

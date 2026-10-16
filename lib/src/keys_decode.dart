/// Terminal key decoding: raw stdin bytes to [TermEvent]s, shared by
/// `tui` and `console` through `terminal.dart`.
library;

import 'dart:convert';

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

/// Pointer motion with the left button held, at cell (x, y), zero-based:
/// a drag, as of a scrollbar. Only sent with `?1003h` (or `?1002h`).
final class TermDrag extends TermEvent {
  TermDrag(this.x, this.y);

  final int x;
  final int y;
}

/// The left button let go at cell (x, y), zero-based: the end of a drag.
final class TermRelease extends TermEvent {
  TermRelease();
}

/// Terminal window focus change (`?1004h` reports). Engines that don't track
/// focus can ignore these.
final class TermFocus extends TermEvent {
  TermFocus(this.gained);

  final bool gained;
}

/// How long a lone ESC waits for the rest of a sequence before it counts
/// as Escape. One value for the Tui and the Console prompts.
const escapeWait = Duration(milliseconds: 50);

/// How long any other held run (a split sequence or character) waits for
/// its sequel before it is dropped.
const heldWait = Duration(seconds: 1);

/// What [held] (the bytes [decodeKeys] left unconsumed) means after
/// [waited] with no new byte: null keeps holding, `''` drops it, anything
/// else is the key it was. A lone ESC is Escape after [escapeWait]; a
/// split character (a UTF-8 lead byte over a slow link, never Escape) or
/// sequence (`ESC [` …) waits [heldWait] and is dropped; an
/// unterminated paste waits for its end however long it takes.
String? resolveHeld(List<int> held, Duration waited) {
  if (held.isEmpty) return '';
  if (held.length >= 2 && held[0] == 0x1b && held[1] == 0x5b && _isPasteStart(held, 0, held.indexOf(0x7e))) {
    return null;
  }
  if (held.length == 1 && held[0] == 0x1b && waited >= escapeWait) return 'escape';
  return waited >= heldWait ? '' : null;
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
          if (bytes[j] != 0x6d) {
            _mouse(out, btn, x, y);
          } else if (btn & 3 == 0 && btn & 64 == 0) {
            out.add(TermRelease()); // 'm' is a release
          }
        }
        i = j + 1;
        continue;
      }
      if (i + 1 >= bytes.length) break; // lone trailing ESC: hold.
      final n1 = bytes[i + 1];
      if (n1 == 0x5b && i + 2 < bytes.length && bytes[i + 2] == 0x5b) {
        // The Linux console's F1-F5: ESC [ [ A … E.
        if (i + 3 >= bytes.length) break; // split: hold.
        final k = bytes[i + 3];
        flush();
        if (k >= 0x41 && k <= 0x45) out.add(TermKey('f${k - 0x40}'));
        i += 4;
        continue;
      }
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
          if (valid && btn & 3 != 3) _mouse(out, btn, bytes[j + 2] - 33, bytes[j + 3] - 33);
          if (valid && btn & 3 == 3 && btn & 96 == 0) {
            out.add(TermRelease()); // 3 is a release
          }
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
    // Motion with a button held (32): a left drag; others scroll nothing.
    if (btn & 3 == 0) out.add(TermDrag(x, y));
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
      if (m & 8 != 0) prefix += 'meta+'; // super/cmd: dropping it made cmd+up fire up
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

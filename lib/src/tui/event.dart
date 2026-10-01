part of '../../tui.dart';

/// What the terminal sends an app: [Key], [Char], [Paste], [Mouse], [Resize]. An app's own
/// messages ([Tui.send]) arrive beside them as plain objects.
///
/// ```dart
/// update: (s, e) => switch (e) {
///   Key.up => s.prev(),
///   Char(char: 'q') => Tui.quit(),
///   Mouse(:final y, kind: MouseKind.press) => s.at(y),
///   _ => s,
/// },
/// ```
///
/// {@category CLI}
sealed class Event {
  const Event();
}

/// A key that is not text: arrows, Enter, F1–F12, and Ctrl+letter (`const Key('c', ctrl: true)`).
///
/// {@category CLI}
final class Key extends Event {
  /// `up`, `enter`, `f5`, … or the letter of a Ctrl combination.
  final String name;
  final bool ctrl, alt, shift;

  const Key(this.name, {this.ctrl = false, this.alt = false, this.shift = false});

  static const up = Key('up');
  static const down = Key('down');
  static const left = Key('left');
  static const right = Key('right');
  static const home = Key('home');
  static const end = Key('end');
  static const pageUp = Key('pageUp');
  static const pageDown = Key('pageDown');
  static const insert = Key('insert');
  static const delete = Key('delete');
  static const enter = Key('enter');
  static const tab = Key('tab');
  static const backTab = Key('tab', shift: true);
  static const backspace = Key('backspace');
  static const esc = Key('esc');

  /// Function key [n], 1–12; match it as `const Key('f5')`.
  factory Key.f(int n, {bool ctrl = false, bool alt = false, bool shift = false}) =>
      Key('f$n', ctrl: ctrl, alt: alt, shift: shift);

  @override
  bool operator ==(Object other) =>
      other is Key && other.name == name && other.ctrl == ctrl && other.alt == alt && other.shift == shift;

  @override
  int get hashCode => Object.hash(name, ctrl, alt, shift);

  @override
  String toString() => '${ctrl ? 'ctrl+' : ''}${alt ? 'alt+' : ''}${shift ? 'shift+' : ''}$name';
}

/// Typed text: one character (a grapheme's first code point and what joins it), maybe with Alt.
///
/// {@category CLI}
final class Char extends Event {
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
final class Paste extends Event {
  final String text;

  const Paste(this.text);
}

/// What a [Mouse] event did.
///
/// {@category CLI}
enum MouseKind { press, release, drag, wheelUp, wheelDown }

/// A click, drag or wheel turn at column [x], row [y] (0-based, of the screen or inline region).
///
/// Only with `mouse: true` on [Tui.run].
///
/// {@category CLI}
final class Mouse extends Event {
  final int x, y;
  final MouseKind kind;

  /// 0 left, 1 middle, 2 right.
  final int button;
  final bool ctrl, alt, shift;

  const Mouse(this.x, this.y, this.kind, {this.button = 0, this.ctrl = false, this.alt = false, this.shift = false});

  @override
  String toString() => 'Mouse(${kind.name} $x,$y)';
}

/// The terminal is now [width] × [height]; the next frame is already drawn at that size.
///
/// {@category CLI}
final class Resize extends Event {
  final int width, height;

  const Resize(this.width, this.height);
}

/// Bytes in, events out. Holds a partial sequence until the next chunk, or until [flush] — the
/// ESC timeout — says a lone ESC was the key.
final class _Decoder {
  final List<int> _pending = [];
  final List<int> _paste = [];
  bool _inPaste = false;

  /// Whether a lone ESC (or a cut-off sequence) waits on more bytes.
  bool get isWaiting => _pending.isNotEmpty;

  List<Object> add(List<int> bytes) {
    _pending.addAll(bytes);
    final out = <Object>[];
    var i = 0;
    while (i < _pending.length) {
      final n = _inPaste ? _pasteStep(i, out) : _step(i, out);
      if (n == 0) break;
      i += n;
    }
    _pending.removeRange(0, i);
    return out;
  }

  /// What waits, read as typed: a lone ESC is Esc, a cut-off sequence is its bytes.
  List<Object> flush() {
    if (_pending.isEmpty) return const [];
    final bytes = List.of(_pending);
    _pending.clear();
    if (_inPaste) {
      _paste.addAll(bytes);
      return const [];
    }
    if (bytes.length == 1) return const [Key.esc];
    final rest = _Decoder().add(bytes.sublist(1));
    return [if (rest.isEmpty) Key.esc, for (final e in rest) _alt(e)];
  }

  static Object _alt(Object e) => switch (e) {
    Char(:final char) => Char(char, alt: true),
    Key(:final name, :final ctrl, :final shift) => Key(name, ctrl: ctrl, alt: true, shift: shift),
    _ => e,
  };

  int _pasteStep(int i, List<Object> out) {
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
  int _step(int i, List<Object> out) {
    final b = _pending[i];
    if (b == 0x1b) return _escape(i, out);
    if (b < 0x80) {
      out.add(_byte(b));
      return 1;
    }
    final len = b >= 0xf0 ? 4 : (b >= 0xe0 ? 3 : (b >= 0xc0 ? 2 : 1));
    if (i + len > _pending.length) return 0;
    final text = utf8.decode(_pending.sublist(i, i + len), allowMalformed: true);
    // A combining mark or joiner belongs to the character before it.
    if (out.isNotEmpty && out.last is Char && _cellWidth(text.runes.first) == 0) {
      final last = out.removeLast() as Char;
      out.add(Char(last.char + text, alt: last.alt));
    } else {
      out.add(Char(text));
    }
    return len;
  }

  static Object _byte(int b) => switch (b) {
    0x0d || 0x0a => Key.enter,
    0x09 => Key.tab,
    0x7f || 0x08 => Key.backspace,
    0x00 => const Key(' ', ctrl: true),
    < 0x1b => Key(String.fromCharCode(b + 0x60), ctrl: true),
    < 0x20 => Key(String.fromCharCode(b + 0x40), ctrl: true),
    _ => Char(String.fromCharCode(b)),
  };

  int _escape(int i, List<Object> out) {
    if (i + 1 >= _pending.length) return 0;
    final next = _pending[i + 1];
    if (next == 0x5b) return _csi(i, out);
    if (next == 0x4f) {
      // SS3: ESC O x
      if (i + 2 >= _pending.length) return 0;
      final key = switch (_pending[i + 2]) {
        0x41 => Key.up,
        0x42 => Key.down,
        0x43 => Key.right,
        0x44 => Key.left,
        0x48 => Key.home,
        0x46 => Key.end,
        0x50 => const Key('f1'),
        0x51 => const Key('f2'),
        0x52 => const Key('f3'),
        0x53 => const Key('f4'),
        _ => null,
      };
      if (key != null) out.add(key);
      return 3;
    }
    if (next == 0x1b) {
      out.add(Key.esc);
      return 1;
    }
    // ESC then a key: Alt+key.
    final inner = <Object>[];
    final used = _step(i + 1, inner);
    if (used == 0) return 0;
    out.addAll(inner.map(_alt));
    return 1 + used;
  }

  int _csi(int i, List<Object> out) {
    var j = i + 2;
    if (j < _pending.length && _pending[j] == 0x3c) return _mouse(i, out);
    while (j < _pending.length && (_pending[j] < 0x40 || _pending[j] > 0x7e)) {
      j++;
    }
    if (j >= _pending.length) return 0;
    final params = String.fromCharCodes(_pending.sublist(i + 2, j)).split(';');
    final last = _pending[j];
    final used = j - i + 1;
    final first = int.tryParse(params[0]) ?? 1;
    final mod = params.length > 1 ? (int.tryParse(params[1]) ?? 1) - 1 : 0;
    final (shift, alt, ctrl) = (mod & 1 != 0, mod & 2 != 0, mod & 4 != 0);
    String? name = switch (last) {
      0x41 => 'up',
      0x42 => 'down',
      0x43 => 'right',
      0x44 => 'left',
      0x48 => 'home',
      0x46 => 'end',
      0x50 => 'f1',
      0x51 => 'f2',
      0x52 => 'f3',
      0x53 => 'f4',
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
        200 => null,
        _ => null,
      },
      _ => null,
    };
    if (last == 0x7e && first == 200) {
      _inPaste = true;
      return used;
    }
    if (name != null) out.add(Key(name, ctrl: ctrl, alt: alt, shift: shift || last == 0x5a));
    return used;
  }

  /// SGR mouse: ESC [ < b ; x ; y (M | m).
  int _mouse(int i, List<Object> out) {
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

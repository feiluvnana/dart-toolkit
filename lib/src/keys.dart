/// One key-name table for `tui`, `console` and `chrome.press`.
///
/// VISION §4.12 is the canon: printable characters as themselves plus
/// `'space'`; `'enter'` `'tab'` `'shift+tab'` `'backspace'` `'escape'`
/// `'insert'` `'delete'`; `'up'` `'down'` `'left'` `'right'` `'home'` `'end'`
/// `'pageup'` `'pagedown'`, `'f1'`…`'f12'`; `ctrl+`/`alt+`/`shift+` prefixes.
/// Aliases (`esc`, `cmd`, `control`, `meta`) canonicalize; an unknown name
/// is an [ArgumentError], so one name works everywhere.
/// Decoding (CSI/SS3) stays in `terminal.dart`; this file owns names.
library;

/// Canonical names (all lower-case).
const Set<String> canonicalKeys = {
  'enter',
  'tab',
  'shift+tab',
  'backspace',
  'escape',
  'insert',
  'delete',
  'up',
  'down',
  'left',
  'right',
  'home',
  'end',
  'pageup',
  'pagedown',
  'space',
  'f1',
  'f2',
  'f3',
  'f4',
  'f5',
  'f6',
  'f7',
  'f8',
  'f9',
  'f10',
  'f11',
  'f12',
};

/// Alias → canonical. Single printable characters never need the table: the
/// caller types them.
const Map<String, String> _aliases = {
  'esc': 'escape',
  'del': 'delete',
  'ins': 'insert',
  'pgup': 'pageup',
  'pgdn': 'pagedown',
  'pagedn': 'pagedown',
  'page-up': 'pageup',
  'page-down': 'pagedown',
  'ctrl': 'ctrl',
  'control': 'ctrl',
  'cmd': 'meta',
  'command': 'meta',
  'meta': 'meta',
  'alt': 'alt',
  'shift': 'shift',
  'space': 'space',
  ' ': 'space',
};

/// Canonicalize [key] to the VISION §4.12 name (lower-case).
///
/// - A single printable character returns as-is (`'a'`, `'Q'`, `'1'`; `'+'`
///   stays `'+'` — the caller types it, except `' '` which is `'space'`).
/// - A named key returns its canonical form (`'ESC'` → `'escape'`).
/// - A chord `a+b+c` canonicalizes each part (`'Control+A'` →
///   `'ctrl+a'`, `'CMD+Enter'` → `'meta+enter'`).
/// - Unknown names throw [ArgumentError] (never silently mis-hit).
String canonicalize(String key) {
  if (key == '+') return '+';
  if (key.length == 1) {
    if (key == ' ') return 'space';
    return key;
  }
  final parts = key.split('+');
  if (parts.length == 1) {
    return _one(parts[0], key);
  }
  final mods = <String>[];
  for (var i = 0; i < parts.length - 1; i++) {
    final m = parts[i].toLowerCase();
    final c = _aliases[m];
    if (c == 'ctrl' || c == 'alt' || c == 'shift' || c == 'meta') {
      mods.add(c!);
    } else if (m == 'ctrl' || m == 'alt' || m == 'shift' || m == 'meta') {
      mods.add(m);
    } else {
      throw ArgumentError.value(key, 'key', 'unknown modifier: ${parts[i]}');
    }
  }
  // One order whatever the spelling (the decoder's): 'shift+ctrl+a' is
  // 'ctrl+shift+a', or a binding would never fire.
  const order = ['ctrl', 'alt', 'shift', 'meta'];
  mods.sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
  final main = parts.last;
  String base;
  if (main.length == 1) {
    base = main;
  } else {
    base = _one(main, key);
    // Named keys are lower-case, single characters as typed.
    if (base.length > 1) base = base.toLowerCase();
  }
  return '${mods.join('+')}+$base';
}

String _one(String name, String whole) {
  final lower = name.toLowerCase();
  if (_aliases.containsKey(lower)) {
    final c = _aliases[lower]!;
    // Bare modifiers are not keys.
    if (c == 'ctrl' || c == 'alt' || c == 'shift' || c == 'meta') {
      // e.g. press('ctrl') alone: unknown key, not a chord.
      if (lower == 'ctrl' ||
          lower == 'control' ||
          lower == 'alt' ||
          lower == 'shift' ||
          lower == 'meta' ||
          lower == 'cmd' ||
          lower == 'command') {
        throw ArgumentError.value(whole, 'key', 'unknown key: $whole');
      }
    }
    return c;
  }
  if (canonicalKeys.contains(lower)) return lower;
  throw ArgumentError.value(whole, 'key', 'unknown key: $whole');
}

/// Split a binding like `'b escape'` into its alternatives.
List<String> splitBinding(String binding) => binding.split(_spaces).where((s) => s.isNotEmpty).toList();

final _spaces = RegExp(r'\s+');

/// True when [keyName] (already canonical, e.g. from the decoder) matches
/// [binding] (`'b escape'`, `'ctrl+c'`). Alternatives are canonicalized
/// (`'esc'` fires on `'escape'`); names [canonicalize] rejects (mouse
/// kinds) compare as written. Comparison is case-insensitive, so `'b'`
/// fires on `'B'` too (console menus rely on it).
bool matchesBinding(String binding, String keyName) {
  final keyLower = keyName.toLowerCase();
  for (final alt in splitBinding(binding)) {
    String name;
    try {
      name = canonicalize(alt);
    } on ArgumentError {
      name = alt;
    }
    if (name.toLowerCase() == keyLower) return true;
  }
  return false;
}

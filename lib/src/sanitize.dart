/// Untrusted text made inert for a terminal, shared by `console`, `tui` and
/// `cli`. No imports, so a CLI that only prints messages stays cheap.
library;

/// [s] with every control replaced by `�`: C0 (newline and ESC included),
/// DEL, C1 (a lone 0x9b/0x9d starts CSI/OSC on some terminals) and the bidi
/// overrides (they reorder what is shown). An untrusted label cannot break a
/// repaint, move the cursor or disguise itself.
String plainLabel(String s) => s.replaceAll(_controls, '\uFFFD');

final _controls = RegExp('[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]');

/// Text for prompts and log lines: like [plainLabel], but SGR styling
/// (`ESC [ … m`, what the colour helpers write), newlines and tabs pass.
/// Everything else that could act on the terminal (OSC titles and
/// clipboard, cursor moves, clears) is shown as `�`.
String safeText(String s) {
  if (!_controls.hasMatch(s)) return s;
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final sgr = _sgr.matchAsPrefix(s, i);
    if (sgr != null) {
      out.write(sgr[0]);
      i = sgr.end;
      continue;
    }
    final c = s.codeUnitAt(i);
    out.write(c == 0x0a || c == 0x09 || !_controls.hasMatch(s[i]) ? s[i] : '\uFFFD');
    i++;
  }
  return out.toString();
}

final _sgr = RegExp(r'\x1b\[[0-9;:]*m');

/// [s] without its SGR styling (what [safeText] lets through), for
/// measuring the cells it takes.
String unstyled(String s) => s.contains('\x1b') ? s.replaceAll(_sgr, '') : s;

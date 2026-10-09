part of '../../tui.dart';

/// Markdown, wrapped to its width: `#` headings, **bold** and *italic*, `inline` and fenced
/// code, `-`/`*`/`1.` lists, `>` quotes, `---` rules and `[links](https://…)`, which are
/// hyperlinks a terminal that supports them opens on a click. Colours come from the palette.
///
/// ```dart
/// Scroll(Markdown(readme))
/// ```
///
/// {@category CLI}
final class Markdown extends Widget {
  final String text;

  const Markdown(this.text);

  /// The laid-out blocks of each markdown seen, by palette: parsed once, not every frame.
  static final _built = Expando<(Palette, Widget)>();

  Widget _body(Palette p) {
    if (_built[this] case (final palette, final body) when identical(palette, p)) return body;
    final body = _blocks(text, p);
    _built[this] = (p, body);
    return body;
  }

  @override
  int get width => _body(const Palette()).width;

  @override
  int heightAt(int width) => _body(_last ?? const Palette()).heightAt(width);

  /// The palette it was last painted in: what [heightAt] measures with.
  Palette? get _last => _built[this]?.$1;

  @override
  void paint(Canvas canvas) => canvas.draw(_body(canvas.palette));
}

final _fence = RegExp(r'^\s*(```|~~~)');
final _heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
final _bullet = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$');
final _quote = RegExp(r'^\s*>\s?(.*)$');
final _ruleLine = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');

/// [text]'s blocks as widgets, top to bottom.
Widget _blocks(String text, Palette p) {
  final out = <Widget>[];
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  final paragraph = <String>[];
  void flush() {
    if (paragraph.isEmpty) return;
    out.add(Label.spans(_inline(paragraph.join(' '), p)));
    paragraph.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (_fence.hasMatch(line)) {
      flush();
      final code = <String>[];
      for (i++; i < lines.length && !_fence.hasMatch(lines[i]); i++) {
        code.add(lines[i]);
      }
      for (final c in code) {
        out.add(Label('  $c', style: p.warning, wrap: false));
      }
      continue;
    }
    if (line.trim().isEmpty) {
      flush();
      if (out.isNotEmpty && out.last is! _Gap) out.add(const _Gap());
      continue;
    }
    if (_heading.firstMatch(line) case final m?) {
      flush();
      final level = m[1]!.length;
      final style = p.accent + Style(bold: true, underline: level == 1);
      out.add(Label.spans(_inline(m[2]!, p), style: style));
      continue;
    }
    if (_ruleLine.hasMatch(line)) {
      flush();
      out.add(Paint((c) => c.text(0, 0, p.border.top * c.width, p.muted)));
      continue;
    }
    if (_quote.firstMatch(line) case final m?) {
      flush();
      out.add(
        HStack([
          Label('${p.border.side} ', style: p.muted).fixed(2),
          Label.spans(_inline(m[1]!, p), style: p.muted).flex(),
        ]),
      );
      continue;
    }
    if (_bullet.firstMatch(line) case final m?) {
      flush();
      final depth = m[1]!.length ~/ 2;
      final mark = m[2]!.endsWith('.') || m[2]!.endsWith(')') ? m[2]! : (TerminalBridge.drawsUnicode ? '•' : '-');
      final lead = '${'  ' * depth}$mark ';
      out.add(HStack([Label(lead, style: p.accent).fixed(Style.width(lead)), Label.spans(_inline(m[3]!, p)).flex()]));
      continue;
    }
    paragraph.add(line.trim());
  }
  flush();
  while (out.isNotEmpty && out.last is _Gap) {
    out.removeLast();
  }
  return VStack(out);
}

/// A blank line between blocks.
final class _Gap extends Widget {
  const _Gap();

  @override
  void paint(Canvas canvas) {}
}

final _link = RegExp(r'\[([^\]]*)\]\(([^)\s]+)\)');

/// [text]'s inline markup as spans: `code`, links, **bold**, *italic* (and `_`/`__`).
List<Span> _inline(String text, Palette p) {
  final out = <Span>[];
  var bold = false, italic = false;
  final plain = StringBuffer();
  Style now() => Style(bold: bold ? true : null, italic: italic ? true : null);
  void flush() {
    if (plain.isEmpty) return;
    out.add(Span('$plain', now()));
    plain.clear();
  }

  for (var i = 0; i < text.length;) {
    final c = text[i];
    if (c == r'\' && i + 1 < text.length) {
      plain.write(text[i + 1]);
      i += 2;
      continue;
    }
    if (c == '`') {
      final end = text.indexOf('`', i + 1);
      if (end > i) {
        flush();
        out.add(Span(text.substring(i + 1, end), p.warning));
        i = end + 1;
        continue;
      }
    }
    if (c == '[') {
      if (_link.matchAsPrefix(text, i) case final m?) {
        flush();
        final url = Uri.tryParse(m[2]!);
        out.add(Span(m[1]!, p.accent + const Style(underline: true) + now(), url));
        i = m.end;
        continue;
      }
    }
    if ((c == '*' || c == '_') && i + 1 < text.length && text[i + 1] == c) {
      flush();
      bold = !bold;
      i += 2;
      continue;
    }
    // A lone `_` inside a word (snake_case) is text.
    final word = c == '_' && i > 0 && i + 1 < text.length && _wordy(text[i - 1]) && _wordy(text[i + 1]);
    if ((c == '*' || c == '_') && !word) {
      flush();
      italic = !italic;
      i++;
      continue;
    }
    plain.write(c);
    i++;
  }
  flush();
  return out;
}

bool _wordy(String c) => RegExp(r'\w').hasMatch(c);

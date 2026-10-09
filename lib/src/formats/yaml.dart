part of '../../json.dart';

final class _Line {
  final int number;
  final int indent;
  final String text; // without indent and trailing comment

  _Line(this.number, this.indent, this.text);

  /// The key and the rest when this line starts a mapping entry, else `null`; computed once.
  late final (String, String)? entry = _entry(text);

  /// `---` or `...` at the left margin: a document boundary, which ends any scalar.
  bool get isMarker => indent == 0 && _isMarker(text);

  static bool _isMarker(String t) => t == '---' || t.startsWith('--- ') || t == '...';

  bool get isItem => text == '-' || text.startsWith('- ');

  /// `key: rest`, scanned by hand: a regular expression backtracked quadratically on long lines.
  static (String, String)? _entry(String t) {
    if (t.isEmpty) return null;
    final c = t.codeUnitAt(0);
    bool colonAt(int j) =>
        j < t.length &&
        t.codeUnitAt(j) == 0x3A /* : */ &&
        (j + 1 == t.length || t.codeUnitAt(j + 1) == 0x20 || t.codeUnitAt(j + 1) == 0x09);
    if (c == 0x22 /* " */ || c == 0x27 /* ' */ ) {
      final end = _closingQuote(t, 0);
      if (end == -1) return null;
      var j = end + 1;
      while (j < t.length) {
        final cu = t.codeUnitAt(j);
        if (cu != 0x20 && cu != 0x09) break;
        j++;
      }
      return colonAt(j) ? (_YamlParser._unescape(t.substring(1, end), c == 0x22), t.substring(j + 1).trim()) : null;
    }
    if (_isIndicator(c) || (_isDashQuestionColon(c) && (t.length == 1 || t.codeUnitAt(1) == 0x20))) return null;
    for (var j = 1; j < t.length; j++) {
      if (colonAt(j)) return (t.substring(0, j).trimRight(), t.substring(j + 1).trim());
    }
    return null;
  }

  static bool _isIndicator(int c) => switch (c) {
    0x5B /* [ */ ||
    0x5D /* ] */ ||
    0x7B /* { */ ||
    0x7D /* } */ ||
    0x2C /* , */ ||
    0x23 /* # */ ||
    0x26 /* & */ ||
    0x2A /* * */ ||
    0x21 /* ! */ ||
    0x7C /* | */ ||
    0x3E /* > */ ||
    0x25 /* % */ ||
    0x40 /* @ */ ||
    0x60 /* ` */ => true,
    _ => false,
  };

  static bool _isDashQuestionColon(int c) => c == 0x2D /* - */ || c == 0x3F /* ? */ || c == 0x3A /* : */;
}

/// Where the quote opening [t] at [from] closes, or -1: `\` escapes in double quotes, `''`
/// is a quote in single ones.
int _closingQuote(String t, int from) {
  final q = t.codeUnitAt(from);
  for (var j = from + 1; j < t.length; j++) {
    final c = t.codeUnitAt(j);
    if (q == 0x22 /* " */ && c == 0x5C /* \ */ ) {
      j++;
    } else if (c == q) {
      if (q == 0x27 /* ' */ && j + 1 < t.length && t.codeUnitAt(j + 1) == 0x27) {
        j++;
      } else {
        return j;
      }
    }
  }
  return -1;
}

final class _YamlParser {
  final List<_Line> lines;

  /// The raw lines, for block and multi-line quoted scalars, which keep the blank lines and
  /// `#` text that [lines] drops.
  final List<String> source;

  final Map<String, Object?> anchors = {};
  int pos = 0;

  /// Collection nesting; past 1000 the input is refused rather than overflow the stack.
  int _depth = 0;

  void _enter() {
    if (++_depth > 1000) _fail('nested deeper than 1000');
  }

  /// CR LF and a lone CR are line breaks.
  _YamlParser(String text)
    : this._((text.contains('\r') ? text.replaceAll('\r\n', '\n').replaceAll('\r', '\n') : text).split('\n'));

  /// A trailing newline ends the last line rather than starting an empty one `|+` would keep.
  _YamlParser._(List<String> raw) : source = raw.last.isEmpty ? (raw..removeLast()) : raw, lines = _split(raw);

  static List<_Line> _split(List<String> raw) => [
    for (var n = 0; n < raw.length; n++)
      if (_stripComment(raw[n]) case final line when line.trim().isNotEmpty)
        _Line(n + 1, line.length - line.trimLeft().length, line.trim()),
  ];

  /// [line] without a `#` comment that is not inside quotes.
  static String _stripComment(String line) {
    if (!line.contains('#')) return line;
    for (var i = 0; i < line.length; i++) {
      final c = line.codeUnitAt(i);
      if ((c == 0x22 || c == 0x27) && _opensString(line, i)) {
        final end = _closingQuote(line, i);
        if (end == -1) return line;
        i = end;
      } else if (c == 0x23 /* # */ && (i == 0 || line.codeUnitAt(i - 1) == 0x20 || line.codeUnitAt(i - 1) == 0x09)) {
        return line.substring(0, i);
      }
    }
    return line;
  }

  /// Whether the quote at [i] opens a string: only where a scalar starts — the line's start, after
  /// `:`, `[`, `{`, `,`, a `-` or `?` indicator, or a tag or anchor. Anywhere else it is a
  /// character of a plain scalar (`don't`, `rock 'n roll # c`), so a ` #` after it is a comment.
  static bool _opensString(String line, int i) {
    var p = i - 1;
    while (p >= 0 && (line.codeUnitAt(p) == 0x20 || line.codeUnitAt(p) == 0x09)) {
      p--;
    }
    if (p < 0) return true;
    switch (line.codeUnitAt(p)) {
      case 0x3A /* : */ || 0x5B /* [ */ || 0x7B /* { */ || 0x2C /* , */ :
        return true;
      case 0x2D /* - */ || 0x3F /* ? */ when p == 0 || _isBlank(line.codeUnitAt(p - 1)):
        return p < i - 1; // `- "x"`, not `-"x"`
    }
    // A property before it: `!!str "1"`, `&a 'x'`.
    if (p == i - 1) return false;
    var start = p;
    while (start > 0 && !_isBlank(line.codeUnitAt(start - 1))) {
      start--;
    }
    final c = line.codeUnitAt(start);
    return c == 0x21 /* ! */ || c == 0x26 /* & */;
  }

  static bool _isBlank(int c) => c == 0x20 || c == 0x09;

  Never _fail(String why) =>
      throw FormatException('YAML line ${pos < lines.length ? line.number : lines.lastOrNull?.number ?? 1}: $why');

  /// Every document in the stream.
  List<Object?> parse() {
    try {
      return _documents();
    } on FormatException catch (e) {
      // A scalar's escapes are decoded where no line is known; this names it.
      if (e.message.startsWith('YAML line')) rethrow;
      _fail(e.message);
    }
  }

  List<Object?> _documents() {
    final docs = <Object?>[];
    var open = false; // a `---` has started a document nothing has filled yet
    while (pos < lines.length) {
      final t = line.text;
      if (line.indent == 0 && t.startsWith('%') && !open) {
        pos++; // a directive: `%YAML 1.2`, `%TAG …`
      } else if (line.isMarker && t != '...') {
        if (open) docs.add(null);
        open = true;
        if (t.length > 4) {
          lines[pos] = _Line(line.number, 0, t.substring(4).trim());
          docs.add(_node(-1));
          open = false;
        } else {
          pos++;
        }
      } else if (t == '...' && line.indent == 0) {
        if (open) docs.add(null);
        open = false;
        pos++;
      } else {
        docs.add(_node(-1));
        open = false;
        if (pos < lines.length && !line.isMarker) _fail('expected "---" before another document');
      }
    }
    if (open) docs.add(null);
    return docs;
  }

  _Line get line => lines[pos];

  /// A node whose first line is [line], inside a parent at [parent] (-1 at the top).
  Object? _node(int parent) {
    if (pos >= lines.length) return null;
    if (_keyProperty(line.text) case final rest?) lines[pos] = _Line(line.number, line.indent, rest);
    if (line.isItem || line.entry != null) {
      _enter();
      final v = line.isItem ? _sequence(line.indent) : _mapping(line.indent);
      _depth--;
      return v;
    }
    final t = line.text;
    pos++;
    return _flowOrScalar(t, parent);
  }

  /// `&a key: value` puts the anchor on the key, not on the mapping: the entry without it,
  /// with the anchor recorded; `null` when [t] is not that.
  String? _keyProperty(String t) {
    if (!t.startsWith('&') && !t.startsWith('!')) return null;
    final sp = t.indexOf(' ');
    if (sp == -1) return null;
    final rest = t.substring(sp + 1).trimLeft();
    final entry = _Line._entry(rest);
    if (entry == null) return null;
    if (t.startsWith('&')) anchors[t.substring(1, sp)] = entry.$1;
    return rest;
  }

  /// The node on the lines after a key or a dash with nothing after it: more indented than
  /// [parent], or `null` when nothing is.
  Object? _below(int parent) => pos < lines.length && line.indent > parent && !line.isMarker ? _node(parent) : null;

  List<Object?> _sequence(int indent) {
    final out = <Object?>[];
    while (pos < lines.length && line.indent == indent && line.isItem) {
      final text = line.text;
      var rest = text == '-' ? '' : text.substring(2).trimLeft();
      // A collection begun on the dash line is indented to where it starts: `-   a: 1` puts
      // `b: 2` four columns in.
      final column = indent + text.length - rest.length;
      rest = _keyProperty(rest) ?? rest;
      if (rest.isEmpty) {
        pos++;
        out.add(_below(indent));
      } else if (rest == '-' || rest.startsWith('- ') || _Line._entry(rest) != null) {
        lines[pos] = _Line(line.number, column, rest);
        out.add(_node(indent));
      } else {
        pos++;
        out.add(_flowOrScalar(rest, indent));
      }
    }
    return out;
  }

  Map<String, Object?> _mapping(int indent) {
    final out = <String, Object?>{};
    List<Object?>? merges;
    while (pos < lines.length && line.indent == indent && line.entry != null) {
      final (key, rest) = line.entry!;
      // Only a plain `<<` merges: `"<<"` is a key.
      final merge = key == '<<' && line.text.startsWith('<<');
      if (!merge && out.containsKey(key)) _fail('"$key" is defined twice');
      pos++;
      final Object? value;
      if (rest.isNotEmpty) {
        value = _flowOrScalar(rest, indent, inMap: true);
      } else if (pos < lines.length && line.indent == indent && line.isItem) {
        value = _sequence(indent); // `key:` with its items at the key's own indent
      } else {
        value = _below(indent);
      }
      merge ? (merges ??= []).add(value) : out[key] = value;
    }
    if (pos < lines.length && line.indent > indent) _fail('unexpected indentation');
    return merges == null ? out : _merge(out, merges);
  }

  /// [out] with the `<<` merge keys' mappings under it: a key written in [out] wins, and of
  /// two merged mappings the earlier one wins — `<<: [*a, *b]` reads `a` first.
  Map<String, Object?> _merge(Map<String, Object?> out, List<Object?> merges) {
    final merged = <String, Object?>{};
    for (final m in merges) {
      for (final source in m is List ? m : [m]) {
        if (source is! Map) _fail('"<<" merges a mapping or a list of mappings');
        for (final MapEntry(:key, :value) in source.entries) {
          merged.putIfAbsent('$key', () => value);
        }
      }
    }
    return merged..addAll(out);
  }

  /// The value after a key or dash on the line just consumed, possibly continuing below;
  /// its parent collection is at [parent], a mapping's with [inMap].
  Object? _flowOrScalar(String t, int parent, {bool inMap = false}) {
    if (t.startsWith('&') || t.startsWith('!')) {
      final sp = t.indexOf(' ');
      final name = sp == -1 ? t.substring(1) : t.substring(1, sp);
      final rest = sp == -1 ? '' : t.substring(sp + 1).trim();
      final Object? value;
      if (rest.isEmpty) {
        // `a: &x` with its items at the key's own indent, as a plain `a:` takes them.
        final items = inMap && pos < lines.length && line.indent == parent && line.isItem;
        final below = items ? _sequence(parent) : _below(parent);
        value = below == null && name == '!str' ? '' : below;
      } else if (name == '!str' && !'"\'[{|>*&!'.contains(rest[0])) {
        value = _plainText(rest, parent); // `!!str 123` is the text 123
      } else {
        value = _flowOrScalar(rest, parent, inMap: inMap);
      }
      if (t.startsWith('&')) anchors[name] = value;
      return value;
    }
    if (t.startsWith('*')) return _alias(t.substring(1).trim());
    if (t == '?' || t.startsWith('? ') || t.startsWith('?\t')) {
      _fail('explicit mapping keys ("?") are not supported');
    }
    if (t.startsWith('|') || t.startsWith('>')) return _block(t, parent);
    if (t.startsWith('[') || t.startsWith('{')) return _flow(_joinFlow(t));
    if (t.startsWith('"') || t.startsWith("'")) {
      final end = _closingQuote(t, 0);
      if (end == -1) return _multilineQuoted(t);
      if (end + 1 < t.length) _fail('unexpected "${t.substring(end + 1).trim()}" after a quoted scalar');
      return _unescape(t.substring(1, end), t[0] == '"');
    }
    return _plain(_plainText(t, parent));
  }

  Object? _alias(String name) {
    if (!anchors.containsKey(name)) _fail('unknown alias *$name');
    final value = anchors[name];
    // An alias shares its node, but whoever walks the result walks every copy: a few nested
    // anchors would otherwise expand a kilobyte into billions of nodes.
    if ((_expanded += _sizeOf(value)) > 1000000) _fail('aliases expand past 1000000 nodes');
    return value;
  }

  /// Nodes an alias to a value expands into; aliases inside share it, so each is counted once.
  int _expanded = 0;
  final _sizes = Map<Object, int>.identity();

  int _sizeOf(Object? v) => switch (v) {
    final Map<Object?, Object?> m => _sizes[m] ??= m.values.fold(1, (n, e) => n + _sizeOf(e)),
    final List<Object?> l => _sizes[l] ??= l.fold(1, (n, e) => n + _sizeOf(e)),
    _ => 1,
  };

  /// A plain scalar and its more-indented continuation lines, joined by a space, or a
  /// newline per blank line between.
  String _plainText(String t, int parent) {
    bool continues() =>
        pos < lines.length && line.indent > parent && line.entry == null && !line.isItem && !line.isMarker;
    if (!continues()) return t;
    final sb = StringBuffer(t);
    for (var previous = lines[pos - 1].number; continues(); previous = lines[pos++].number) {
      var blanks = 0;
      for (var n = previous; n < line.number - 1; n++) {
        if (source[n].trim().isEmpty) blanks++;
      }
      sb
        ..write(blanks == 0 ? ' ' : '\n' * blanks)
        ..write(line.text);
    }
    return sb.toString();
  }

  /// A quoted scalar that does not close on its line, folded: a break is a space, a blank line
  /// a newline, and in double quotes a trailing `\` joins lines with nothing between.
  String _multilineQuoted(String first) {
    final double = first[0] == '"';
    final parts = [first.substring(1)];
    var row = lines[pos - 1].number; // 1-based: source[row] is the next line
    for (; ; row++) {
      if (row >= source.length) _fail('unterminated quoted scalar');
      final text = source[row];
      final end = _closingQuote('${first[0]}$text', 0);
      if (end != -1) {
        parts.add(text.substring(0, end - 1));
        break;
      }
      parts.add(text);
    }
    while (pos < lines.length && lines[pos].number <= row + 1) {
      pos++;
    }
    final sb = StringBuffer();
    var blanks = 0;
    var tight = false;
    for (var i = 0; i < parts.length; i++) {
      final last = i == parts.length - 1;
      var t = i == 0 ? parts[i].trimRight() : (last ? parts[i].trimLeft() : parts[i].trim());
      if (t.isEmpty && i > 0 && !last) {
        blanks++;
        continue;
      }
      if (i > 0 && !tight) sb.write(blanks > 0 ? '\n' * blanks : ' ');
      tight = double && !last && _escapesBreak(t);
      if (tight) t = t.substring(0, t.length - 1);
      sb.write(t);
      blanks = 0;
    }
    return _unescape(sb.toString(), double);
  }

  /// Whether [t] ends in an odd run of backslashes: the last one escapes the line break.
  static bool _escapesBreak(String t) {
    var n = 0;
    while (n < t.length && t.codeUnitAt(t.length - 1 - n) == 0x5C /* \ */ ) {
      n++;
    }
    return n.isOdd;
  }

  /// [t] and the lines after it until its brackets (outside quotes) balance.
  String _joinFlow(String t) {
    final sb = StringBuffer(t);
    var depth = 0;
    int? quote;
    void count(String x) {
      for (var j = 0; j < x.length; j++) {
        final c = x.codeUnitAt(j);
        if (quote != null) {
          if (c == 0x5C /* \ */ && quote == 0x22 /* " */ ) {
            j++;
          } else if (c == quote) {
            quote = null;
          }
        } else if ((c == 0x22 || c == 0x27) && _opensString(x, j)) {
          // A quote opens a string only where one may start: `don't` is a word.
          quote = c;
        } else if (c == 0x5B || c == 0x7B) {
          // [ or {
          depth++;
        } else if (c == 0x5D || c == 0x7D) {
          // ] or }
          depth--;
        }
      }
    }

    count(t);
    while (depth > 0 && pos < lines.length) {
      sb
        ..write(' ')
        ..write(line.text);
      count(line.text);
      pos++;
    }
    return sb.toString();
  }

  static final _blockHeader = RegExp('[|>+-]');

  /// A `|` literal or `>` folded block: the source lines after it indented past [parent].
  Object? _block(String header, int parent) {
    final folded = header[0] == '>';
    final keep = header.contains('+'), strip = header.contains('-');
    // An indentation indicator counts from the parent: `a: |2` is two columns in from `a`.
    final explicit = int.tryParse(header.replaceAll(_blockHeader, '').trim());
    var blockIndent = explicit == null ? -1 : (parent < 0 ? 0 : parent) + explicit;
    final body = <String>[];
    var leading = 0; // blank lines before the first content line, which are content too
    var row = lines[pos - 1].number; // the source line after the header, blank or not
    for (; row < source.length; row++) {
      final text = source[row];
      if (text.trim().isEmpty) {
        if (blockIndent == -1) {
          leading++;
        } else {
          body.add(folded ? '' : (text.length > blockIndent ? text.substring(blockIndent) : ''));
        }
        continue;
      }
      final column = text.length - text.trimLeft().length;
      if (blockIndent == -1) {
        if (column <= parent) break; // dedented before any content: the block is empty
        blockIndent = column;
      }
      if (column < blockIndent || (column == 0 && _Line._isMarker(text))) break;
      body.add(folded ? text.substring(blockIndent).trimRight() : text.substring(blockIndent));
    }
    while (pos < lines.length && lines[pos].number <= row) {
      pos++;
    }
    if (body.isNotEmpty) body.insertAll(0, List.filled(leading, ''));
    if (body.isEmpty) return keep ? '\n' * leading : '';

    // Trailing blank lines are chomping's business rather than content.
    var trailing = 0;
    while (body.isNotEmpty && body.last.isEmpty) {
      body.removeLast();
      trailing++;
    }

    final text = folded ? _fold(body) : body.join('\n');
    if (strip) return text;
    return keep ? text + '\n' * (trailing + 1) : '$text\n';
  }

  /// Folded style: a break is a space, or a newline per blank line between, and is kept when
  /// either line is more indented.
  static String _fold(List<String> body) {
    final out = StringBuffer();
    String? previous;
    var blanks = 0;
    for (final text in body) {
      if (text.isEmpty) {
        blanks++;
        continue;
      }
      if (previous == null) {
        out.write('\n' * blanks);
      } else if (previous.startsWith(' ') || text.startsWith(' ')) {
        out.write('\n' * (blanks + 1));
      } else {
        out.write(blanks == 0 ? ' ' : '\n' * blanks);
      }
      out.write(text);
      previous = text;
      blanks = 0;
    }
    return out.toString();
  }

  /// A flow collection or scalar, all on one (joined) line.
  Object? _flow(String t) {
    var i = 0;
    void ws() {
      while (i < t.length) {
        final c = t.codeUnitAt(i);
        if (c != 0x20 && c != 0x09) break;
        i++;
      }
    }

    bool isFlowSep(int c) => c == 0x20 || c == 0x2C || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D;

    String word() {
      final start = i;
      while (i < t.length && !isFlowSep(t.codeUnitAt(i))) {
        i++;
      }
      return t.substring(start, i);
    }

    late Object? Function() value;

    /// A collection's entries up to [close]; [entry] reads one.
    void entries(String close, void Function() entry) {
      final closeCode = close.codeUnitAt(0);
      i++;
      while (true) {
        ws();
        if (i >= t.length) _fail('unterminated flow collection');
        if (t.codeUnitAt(i) == closeCode) {
          i++;
          return;
        }
        entry();
        ws();
        if (i >= t.length) _fail('unterminated flow collection');
        final c = t.codeUnitAt(i);
        if (c == 0x2C /* , */ ) {
          i++;
        } else if (c != closeCode) {
          _fail('expected "," or "$close" in a flow collection');
        }
      }
    }

    /// A key's value after an optional `:`, or `null` without one.
    Object? afterColon() {
      ws();
      if (i >= t.length || t.codeUnitAt(i) != 0x3A /* : */ ) return null;
      i++;
      ws();
      if (i < t.length) {
        final c = t.codeUnitAt(i);
        if (c == 0x2C || c == 0x5D || c == 0x7D) return null; // ,]}
      }
      return value();
    }

    value = () {
      ws();
      if (i >= t.length) _fail('unterminated flow collection');
      final c = t.codeUnitAt(i);
      switch (c) {
        case 0x5B /* [ */ :
          _enter();
          final out = <Object?>[];
          entries(']', () {
            final v = value();
            ws();
            // `[a: 1]` is a sequence holding a one-entry mapping.
            out.add(i < t.length && t.codeUnitAt(i) == 0x3A /* : */ ? {'$v': afterColon()} : v);
          });
          _depth--;
          return out;
        case 0x7B /* { */ :
          _enter();
          final out = <String, Object?>{};
          List<Object?>? merges;
          entries('}', () {
            final start = i;
            final v = value();
            final firstC = t.codeUnitAt(start);
            final k = (firstC == 0x22 || firstC == 0x27) ? '$v' : t.substring(start, i).trim();
            if (k == '<<' && firstC == 0x3C /* < */ ) return (merges ??= []).add(afterColon());
            if (out.containsKey(k)) _fail('"$k" is defined twice');
            out[k] = afterColon();
          });
          _depth--;
          return merges == null ? out : _merge(out, merges!);
        case 0x22 /* " */ || 0x27 /* ' */ :
          final end = _closingQuote(t, i);
          if (end == -1) _fail('unterminated quoted scalar');
          final v = _unescape(t.substring(i + 1, end), c == 0x22);
          i = end + 1;
          return v;
        case 0x2A /* * */ :
          i++;
          return _alias(word());
        case 0x26 /* & */ || 0x21 /* ! */ :
          final anchor = c == 0x26;
          i++;
          final name = word();
          ws();
          final start = i;
          final v = (i < t.length && (t.codeUnitAt(i) != 0x2C && t.codeUnitAt(i) != 0x5D && t.codeUnitAt(i) != 0x7D))
              ? value()
              : null;
          if (anchor) anchors[name] = v;
          return name == '!str' && v is! String && v is! Map && v is! List ? t.substring(start, i).trim() : v;
      }
      // A plain scalar may hold spaces (`[hello world]`); it ends at a flow indicator, at `: `
      // and at ` #`. Anchors and aliases still end at a space ([word]).
      final start = i;
      while (i < t.length) {
        final cu = t.codeUnitAt(i);
        if (cu != 0x20 && isFlowSep(cu)) break;
        if (cu == 0x3A /* : */ && (i + 1 >= t.length || isFlowSep(t.codeUnitAt(i + 1)))) break;
        if (cu == 0x23 /* # */ && i > start && t.codeUnitAt(i - 1) == 0x20) break;
        i++;
      }
      return _plain(t.substring(start, i).trim());
    };

    final v = value();
    ws();
    if (i < t.length) _fail('unexpected "${t.substring(i)}" after a flow collection');
    return v;
  }

  /// A quoted scalar's [body] with its escapes decoded: YAML's double-quoted set, or `''`
  /// for a quote inside single ones.
  static String _unescape(String body, bool double) {
    if (!double) return body.replaceAll("''", "'");
    if (!body.contains(r'\')) return body;
    final sb = StringBuffer();
    var chunkStart = 0;
    for (var i = 0; i < body.length; i++) {
      final c = body.codeUnitAt(i);
      if (c != 0x5C /* \ */ || i + 1 >= body.length) {
        continue;
      }
      if (i > chunkStart) {
        sb.write(body.substring(chunkStart, i));
      }
      final e = body[++i];
      final hex = switch (e) {
        'x' => 2,
        'u' => 4,
        'U' => 8,
        _ => 0,
      };
      if (hex > 0) {
        // Exactly [hex] digits: `int.tryParse` would also take a sign.
        var code = 0;
        for (var k = 1; k <= hex; k++) {
          final d = i + k < body.length ? _yamlHex(body.codeUnitAt(i + k)) : -1;
          if (d < 0) throw FormatException('\\$e needs $hex hex digits');
          code = code * 16 + d;
        }
        if (code > 0x10FFFF) throw FormatException('\\$e${body.substring(i + 1, i + 1 + hex)} is past U+10FFFF');
        sb.writeCharCode(code);
        i += hex;
        chunkStart = i + 1;
        continue;
      }
      sb.write(switch (e) {
        '0' => '\x00',
        'a' => '\x07',
        'b' => '\b',
        't' || '\t' => '\t',
        'n' => '\n',
        'v' => '\x0b',
        'f' => '\f',
        'r' => '\r',
        'e' => '\x1b',
        'N' => '\u0085',
        '_' => ' ',
        'L' => ' ',
        'P' => ' ',
        _ => e, // `\\`, `\"`, `\/`, `\ ` and anything unknown
      });
      chunkStart = i + 1;
    }
    if (chunkStart < body.length) {
      sb.write(body.substring(chunkStart));
    }
    return sb.toString();
  }

  static final _int = RegExp(r'^[+-]?\d+$');
  static final _hex = RegExp(r'^0x[0-9a-fA-F]+$');
  static final _oct = RegExp(r'^0o[0-7]+$');
  static final _float = RegExp(r'^[+-]?(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?$');
  static final _fractional = RegExp(r'[.eE]');

  static Object? _plain(String t) {
    switch (t) {
      case '' || '~' || 'null' || 'Null' || 'NULL':
        return null;
      case 'true' || 'True' || 'TRUE':
        return true;
      case 'false' || 'False' || 'FALSE':
        return false;
      case '.inf' || '.Inf' || '.INF' || '+.inf' || '+.Inf' || '+.INF':
        return double.infinity;
      case '-.inf' || '-.Inf' || '-.INF':
        return double.negativeInfinity;
      case '.nan' || '.NaN' || '.NAN':
        return double.nan;
    }
    final c = t.codeUnitAt(0);
    // Only something that starts like a number can be one; most scalars are words.
    if (!(c >= 0x30 && c <= 0x39) && c != 0x2b && c != 0x2d && c != 0x2e) return t;
    // Past int64 a number reads as a double, as `jsonDecode` and package:yaml read it.
    if (_int.hasMatch(t)) return int.tryParse(t) ?? double.parse(t);
    if (_hex.hasMatch(t)) return int.tryParse(t.substring(2), radix: 16) ?? t;
    if (_oct.hasMatch(t)) return int.tryParse(t.substring(2), radix: 8) ?? t;
    if (_float.hasMatch(t) && t.contains(_fractional)) return double.parse(t);
    return t;
  }
}

int _yamlHex(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  return -1;
}

/// [value] as block-style YAML, quoted only where a plain scalar would read back as something
/// else. Walked on a stack, so a deep document does not overflow.
String _yaml(Object? value) {
  final sb = StringBuffer();
  // What is left to write: a value at an indent, and whether it sits after a `- ` on its line.
  final pending = <(Object?, int, bool)>[(value, 0, false)];
  while (pending.isNotEmpty) {
    var (value, indent, inList) = pending.removeLast();
    if (value is Doc) value = value.raw;
    final pad = '  ' * indent;
    switch (value) {
      case Map<Object?, Object?> m when m.isEmpty:
        sb.writeln('{}');
      case List<Object?> l when l.isEmpty:
        sb.writeln('[]');
      case Map<Object?, Object?> m:
        // Pushed last first, so they pop in order; each writes its key, then its value.
        final entries = m.entries.toList();
        for (var i = entries.length - 1; i >= 0; i--) {
          pending.add((_YamlKey(entries[i].key, entries[i].value, first: i == 0 && inList), indent, false));
        }
      case _YamlKey(:final key, value: final v, :final first):
        final item = v is Doc ? v.raw : v;
        sb
          ..write(first ? '' : pad)
          ..write('${_yamlScalar('$key')}:');
        final block = item is Map<Object?, Object?> && item.isNotEmpty || item is List<Object?> && item.isNotEmpty;
        block ? sb.writeln() : sb.write(' ');
        pending.add((item, indent + 1, false));
      case List<Object?> l:
        for (var i = l.length - 1; i >= 0; i--) {
          pending.add((_YamlItem(l[i]), indent, false));
        }
      case _YamlItem(value: final v):
        final item = v is Doc ? v.raw : v;
        sb.write('$pad- ');
        if (item is List<Object?> && item.isNotEmpty) sb.writeln();
        pending.add((item, indent + 1, item is Map<Object?, Object?> && item.isNotEmpty));
      case null:
        sb.writeln('null');
      case String s:
        sb.writeln(_yamlScalar(s));
      case double d when d.isNaN:
        sb.writeln('.nan');
      case double d when d.isInfinite:
        sb.writeln(d.isNegative ? '-.inf' : '.inf');
      case DateTime d:
        sb.writeln(d.toIso8601String());
      default:
        sb.writeln('$value');
    }
  }
  return sb.toString();
}

/// A map entry still to write: its key, then its value one level in.
final class _YamlKey {
  final Object? key, value;

  /// Whether it is the first entry of a map after a `- `, written on that line.
  final bool first;

  const _YamlKey(this.key, this.value, {required this.first});
}

/// A list element still to write, after its `- `.
final class _YamlItem {
  final Object? value;

  const _YamlItem(this.value);
}

/// [s] plain when it would read back as itself, double-quoted otherwise. Scanned by hand: two
/// regular expressions per scalar were three quarters of writing a document.
String _yamlScalar(String s) => s.isNotEmpty && s != '<<' && !_yamlTyped(s) && !_unsafePlain(s) ? s : jsonEncode(s);

/// What makes a plain scalar read back as something else: an indicator first, `---` or `...`
/// alone, `: ` or a `:` at the end (a key), ` #` (a comment), space at the end, a line break or
/// another character YAML does not print.
bool _unsafePlain(String s) {
  final first = s.codeUnitAt(0);
  if (_yamlSpace(first) || '-?:,[]{}#&*!|>\'"%@`'.contains(s[0])) return true;
  if ((s.startsWith('---') || s.startsWith('...')) && (s.length == 3 || _yamlSpace(s.codeUnitAt(3)))) return true;
  if (_yamlSpace(s.codeUnitAt(s.length - 1)) || s.codeUnitAt(s.length - 1) == 0x3a) return true;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x20 && c != 0x09 || c >= 0x7f && c <= 0x9f || c == 0x2028 || c == 0x2029 || c == 0xfeff) return true;
    if (c == 0x3a && _yamlSpace(s.codeUnitAt(i + 1))) return true; // `:` is never last here
    if (c == 0x23 && i > 0 && _yamlSpace(s.codeUnitAt(i - 1))) return true;
  }
  return false;
}

/// Whitespace as a regular expression's `\s` has it.
bool _yamlSpace(int c) =>
    c == 0x20 ||
    (c >= 0x09 && c <= 0x0d) ||
    c == 0xa0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200a) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202f ||
    c == 0x205f ||
    c == 0x3000 ||
    c == 0xfeff;

/// Whether YAML's core schema reads plain [s] as something other than text: null, a boolean, a
/// number, an infinity or NaN.
bool _yamlTyped(String s) {
  if (_yamlWords.contains(s)) return true;
  final c = s.codeUnitAt(0);
  // Only something that starts like a number can be one; most scalars are words.
  return (c >= 0x30 && c <= 0x39 || c == 0x2b || c == 0x2d || c == 0x2e) && _yamlNumber.hasMatch(s);
}

const _yamlWords = {
  '~', 'null', 'Null', 'NULL', 'true', 'True', 'TRUE', 'false', 'False', 'FALSE', //
  '.inf', '.Inf', '.INF', '+.inf', '+.Inf', '+.INF', '-.inf', '-.Inf', '-.INF', '.nan', '.NaN', '.NAN',
};

final _yamlNumber = RegExp(r'^([+-]?\d+|0x[0-9a-fA-F]+|0o[0-7]+|[+-]?(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?)$');

part of '../../formats.dart';

/// YAML decoding and encoding.
///
/// {@category Formats}
extension StringYamlExtensions on String {
  /// This YAML text as a document: block and flow mappings and sequences, plain and quoted
  /// scalars, `|` and `>` blocks, anchors and aliases, comments. Numbers, booleans and null
  /// are themselves; dates and times stay text; a tag is ignored. Several documents (`---`)
  /// decode to a list.
  ///
  /// Throws [FormatException] with a line number on bad syntax.
  JsonDocument get yaml => JsonDocument(_YamlParser(this).parse());
}

/// {@category Formats}
extension JsonDocumentYamlExtensions on JsonDocument {
  /// This document as YAML: block style, two-space indent, quoted only where a plain scalar
  /// would read as something else.
  String toYaml() {
    final sb = StringBuffer();
    _emitYaml(raw, sb, 0, inList: false);
    return sb.toString();
  }
}

// ---------------------------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------------------------

final class _Line {
  final int number;
  final int indent;
  final String text; // without indent and trailing comment
  const _Line(this.number, this.indent, this.text);
}

final class _YamlParser {
  final List<_Line> lines;

  /// The document as written. A block scalar reads from here, not from [lines]: [lines] has
  /// had comments stripped and blank lines dropped, and a `|` block keeps both.
  final List<String> source;

  final Map<String, Object?> anchors = {};
  int pos = 0;

  _YamlParser(String text) : source = _sourceLines(text), lines = _split(text);

  /// The document's lines, with a trailing newline understood as ending the last line
  /// rather than starting an empty one — which a `|+` block would otherwise keep as a
  /// blank line that was never written.
  static List<String> _sourceLines(String text) {
    final out = text.replaceAll('\r\n', '\n').split('\n');
    if (out.isNotEmpty && out.last.isEmpty) out.removeLast();
    return out;
  }

  static List<_Line> _split(String source) {
    final out = <_Line>[];
    final raw = source.replaceAll('\r\n', '\n').split('\n');
    for (var n = 0; n < raw.length; n++) {
      final line = raw[n];
      final stripped = _stripComment(line);
      if (stripped.trim().isEmpty) continue;
      var indent = 0;
      while (indent < stripped.length && stripped[indent] == ' ') {
        indent++;
      }
      out.add(_Line(n + 1, indent, stripped.substring(indent).trimRight()));
    }
    return out;
  }

  /// [line] without a `#` comment that is not inside quotes.
  static String _stripComment(String line) {
    var q = '';
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (q.isNotEmpty) {
        if (c == q) q = '';
        continue;
      }
      if ((c == '"' || c == "'") && _opensString(line, i)) {
        q = c;
      } else if (c == '#' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t')) {
        return line.substring(0, i);
      }
    }
    return line;
  }

  /// Whether the quote at [i] starts a quoted string rather than being an apostrophe.
  ///
  /// `name: don't # x` has a `'` in the middle of a word: treating that as an opening quote
  /// left the string unterminated and kept the comment as part of the value.
  static bool _opensString(String line, int i) {
    if (i == 0) return true;
    return switch (line[i - 1]) {
      ' ' || '\t' || ':' || '-' || '[' || '{' || ',' || '>' => true,
      _ => false,
    };
  }

  Object? parse() {
    final docs = <Object?>[];
    while (pos < lines.length) {
      final t = lines[pos].text;
      if (t == '---' || t.startsWith('--- ')) {
        if (t.length > 4) {
          lines[pos] = _Line(lines[pos].number, lines[pos].indent, t.substring(4).trim());
        } else {
          pos++;
        }
        if (pos < lines.length && !(lines[pos].text == '---' || lines[pos].text.startsWith('--- '))) {
          docs.add(_node(lines[pos].indent));
        } else {
          docs.add(null);
        }
        continue;
      }
      if (t == '...') {
        pos++;
        continue;
      }
      docs.add(_node(lines[pos].indent));
    }
    if (docs.isEmpty) return null;
    return docs.length == 1 ? docs.single : docs;
  }

  _Line get line => lines[pos];

  /// A node whose first line is at [indent].
  Object? _node(int indent) {
    if (pos >= lines.length) return null;
    final t = line.text;
    if (t.startsWith('- ') || t == '-') return _sequence(indent);
    if (_isMappingLine(t)) return _mapping(indent);
    pos++;
    return _flowOrScalar(t, indent);
  }

  List<Object?> _sequence(int indent) {
    final out = <Object?>[];
    while (pos < lines.length && line.indent == indent && (line.text.startsWith('- ') || line.text == '-')) {
      final n = line.number;
      final rest = line.text == '-' ? '' : line.text.substring(2).trimLeft();
      if (rest.isEmpty) {
        pos++;
        out.add(pos < lines.length && line.indent > indent ? _node(line.indent) : null);
      } else if (rest.startsWith('- ') || rest == '-') {
        // A nested sequence on the same line: treat the rest as a line indented past the dash.
        lines[pos] = _Line(n, indent + 2, rest);
        out.add(_sequence(indent + 2));
      } else if (_isMappingLine(rest)) {
        // A mapping whose first entry sits on the dash line.
        lines[pos] = _Line(n, indent + 2, rest);
        out.add(_mapping(indent + 2));
      } else {
        pos++;
        out.add(_flowOrScalar(rest, indent + 2));
      }
    }
    return out;
  }

  Map<String, Object?> _mapping(int indent) {
    final out = <String, Object?>{};
    while (pos < lines.length && line.indent == indent && _isMappingLine(line.text)) {
      final (key, rest) = _splitKey(line.text);
      pos++;
      if (rest.isEmpty) {
        out[key] = pos < lines.length && line.indent > indent
            ? _node(line.indent)
            : (pos < lines.length && line.indent == indent && line.text.startsWith('- ') ? _sequence(indent) : null);
      } else {
        out[key] = _flowOrScalar(rest, indent + 1);
      }
    }
    if (pos < lines.length && line.indent > indent) {
      throw FormatException('YAML line ${line.number}: unexpected indentation');
    }
    return out;
  }

  static final _mappingKey = RegExp(
    r'''^(?:"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s"'\[\]{},#&*!|>%@`][^:#]*?)\s*:(?:\s|$)''',
  );

  static bool _isMappingLine(String t) => _mappingKey.hasMatch(t);

  (String, String) _splitKey(String t) {
    final m = _mappingKey.firstMatch(t)!;
    var key = m.group(0)!;
    key = key.substring(0, key.lastIndexOf(':')).trim();
    if (key.length >= 2 && (key[0] == '"' || key[0] == "'")) key = _quoted(key);
    return (key, t.substring(m.end).trim());
  }

  /// The value that follows a key or a dash, possibly continuing on the next lines.
  Object? _flowOrScalar(String t, int indent) {
    if (t.startsWith('&')) {
      final sp = t.indexOf(' ');
      final name = sp == -1 ? t.substring(1) : t.substring(1, sp);
      final rest = sp == -1 ? '' : t.substring(sp + 1).trim();
      final value = rest.isEmpty
          ? (pos < lines.length && line.indent >= indent ? _node(line.indent) : null)
          : _flowOrScalar(rest, indent);
      anchors[name] = value;
      return value;
    }
    if (t.startsWith('*')) {
      final name = t.substring(1).trim();
      if (!anchors.containsKey(name)) throw FormatException('YAML: unknown alias *$name');
      return anchors[name];
    }
    if (t.startsWith('!')) {
      final sp = t.indexOf(' ');
      return sp == -1 ? null : _flowOrScalar(t.substring(sp + 1).trim(), indent);
    }
    if (t.startsWith('|') || t.startsWith('>')) return _block(t, indent);
    if (t.startsWith('[') || t.startsWith('{')) return _flow(_joinFlow(t));
    if (t.startsWith('"') || t.startsWith("'")) return _quoted(t);
    // A plain scalar may continue on more-indented lines.
    final sb = StringBuffer(t);
    while (pos < lines.length && line.indent >= indent && !_isMappingLine(line.text) && !line.text.startsWith('- ')) {
      sb.write(' ${line.text}');
      pos++;
    }
    return _plain(sb.toString());
  }

  /// A flow collection may span lines until its brackets balance.
  String _joinFlow(String t) {
    final sb = StringBuffer(t);
    var depth = 0;
    void count(String x) {
      for (final c in x.split('')) {
        if (c == '[' || c == '{') depth++;
        if (c == ']' || c == '}') depth--;
      }
    }

    count(t);
    while (depth > 0 && pos < lines.length) {
      sb.write(' ${line.text}');
      count(line.text);
      pos++;
    }
    return sb.toString();
  }

  /// A `|` literal or `>` folded block: the following source lines indented past [indent],
  /// blank lines and interior spacing included.
  Object? _block(String header, int indent) {
    final folded = header[0] == '>';
    final keep = header.contains('+'), strip = header.contains('-');
    // An explicit indentation indicator, as in `|2`.
    final explicit = int.tryParse(header.replaceAll(RegExp('[|>+-]'), '').trim());

    var blockIndent = explicit == null ? -1 : indent + explicit;
    final body = <String>[];
    var row = (pos < lines.length ? lines[pos].number : source.length + 1) - 1;
    for (; row < source.length; row++) {
      final text = source[row];
      if (text.trim().isEmpty) {
        // A blank line inside the block is content — which is why this reads the source.
        if (blockIndent != -1) body.add('');
        continue;
      }
      var column = 0;
      while (column < text.length && text[column] == ' ') {
        column++;
      }
      if (blockIndent == -1) {
        if (column < indent) break; // dedented before any content: the block is empty
        blockIndent = column;
      }
      if (column < blockIndent) break;
      body.add(text.substring(blockIndent).trimRight());
    }
    while (pos < lines.length && lines[pos].number <= row) {
      pos++;
    }

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

  /// Folded style: a break between two non-empty lines becomes one space, a blank line
  /// becomes a newline, and a line indented past the block keeps its own break. Spaces
  /// inside a line are content and are left alone.
  static String _fold(List<String> body) {
    final out = StringBuffer();
    for (var i = 0; i < body.length; i++) {
      final text = body[i];
      if (text.isEmpty) {
        out.write('\n');
        continue;
      }
      if (i > 0 && body[i - 1].isNotEmpty && out.isNotEmpty) {
        out.write(text.startsWith(' ') ? '\n' : ' ');
      }
      out.write(text);
    }
    return out.toString();
  }

  Object? _flow(String t) {
    var i = 0;
    Object? value() {
      while (i < t.length && t[i] == ' ') {
        i++;
      }
      if (t[i] == '[') {
        i++;
        final out = <Object?>[];
        while (true) {
          while (i < t.length && (t[i] == ' ' || t[i] == ',')) {
            i++;
          }
          if (t[i] == ']') {
            i++;
            return out;
          }
          out.add(value());
        }
      }
      if (t[i] == '{') {
        i++;
        final out = <String, Object?>{};
        while (true) {
          while (i < t.length && (t[i] == ' ' || t[i] == ',')) {
            i++;
          }
          if (t[i] == '}') {
            i++;
            return out;
          }
          final k = value();
          while (i < t.length && (t[i] == ' ' || t[i] == ':')) {
            i++;
          }
          out['$k'] = value();
        }
      }
      if (t[i] == '"' || t[i] == "'") {
        final q = t[i];
        var j = i + 1;
        while (j < t.length &&
            !(t[j] == q && !(q == '"' && t[j - 1] == r'\') && !(q == "'" && j + 1 < t.length && t[j + 1] == "'"))) {
          if (q == "'" && t[j] == "'" && j + 1 < t.length && t[j + 1] == "'") j++;
          j++;
        }
        final v = _quoted(t.substring(i, j + 1));
        i = j + 1;
        return v;
      }
      final start = i;
      while (i < t.length && !',]}'.contains(t[i]) && !(t[i] == ':' && (i + 1 >= t.length || t[i + 1] == ' '))) {
        i++;
      }
      return _plain(t.substring(start, i).trim());
    }

    return value();
  }

  static String _quoted(String t) {
    final q = t[0];
    final body = t.substring(1, t.length - 1);
    if (q == "'") return body.replaceAll("''", "'");
    return body.replaceAllMapped(RegExp(r'\\(u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|.)'), (m) {
      final e = m[1]!;
      if (e.startsWith('u')) return String.fromCharCode(int.parse(e.substring(1), radix: 16));
      if (e.startsWith('x')) return String.fromCharCode(int.parse(e.substring(1), radix: 16));
      return switch (e) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => '\x00',
        '\\' => '\\',
        '"' => '"',
        '/' => '/',
        ' ' => ' ',
        _ => e,
      };
    });
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
      case '.inf' || '.Inf' || '.INF' || '+.inf':
        return double.infinity;
      case '-.inf' || '-.Inf' || '-.INF':
        return double.negativeInfinity;
      case '.nan' || '.NaN' || '.NAN':
        return double.nan;
    }
    if (_int.hasMatch(t)) return int.parse(t);
    if (_hex.hasMatch(t)) return int.parse(t.substring(2), radix: 16);
    if (_oct.hasMatch(t)) return int.parse(t.substring(2), radix: 8);
    if (_float.hasMatch(t) && t.contains(_fractional)) return double.parse(t);
    return t;
  }
}

// ---------------------------------------------------------------------------------------------
// Emitter
// ---------------------------------------------------------------------------------------------

void _emitYaml(Object? value, StringBuffer sb, int indent, {required bool inList}) {
  final pad = '  ' * indent;
  switch (value) {
    case Map<Object?, Object?> m when m.isEmpty:
      sb.writeln('{}');
    case List<Object?> l when l.isEmpty:
      sb.writeln('[]');
    case Map<Object?, Object?> m:
      var first = true;
      for (final MapEntry(:key, :value) in m.entries) {
        sb.write(first && inList ? '' : pad);
        first = false;
        sb.write('${_yamlScalar('$key')}:');
        if (value is Map<Object?, Object?> && value.isNotEmpty || value is List<Object?> && value.isNotEmpty) {
          sb.writeln();
          _emitYaml(value, sb, indent + 1, inList: false);
        } else {
          sb.write(' ');
          _emitYaml(value, sb, indent + 1, inList: false);
        }
      }
    case List<Object?> l:
      for (final item in l) {
        sb.write('$pad- ');
        if (item is Map<Object?, Object?> && item.isNotEmpty) {
          _emitYaml(item, sb, indent + 1, inList: true);
        } else if (item is List<Object?> && item.isNotEmpty) {
          sb.writeln();
          _emitYaml(item, sb, indent + 1, inList: false);
        } else {
          _emitYaml(item, sb, indent + 1, inList: false);
        }
      }
    case null:
      sb.writeln('null');
    case String s:
      sb.writeln(_yamlScalar(s));
    case double d when d.isNaN:
      sb.writeln('.nan');
    case double d when d.isInfinite:
      sb.writeln(d.isNegative ? '-.inf' : '.inf');
    default:
      sb.writeln('$value');
  }
}

/// [s] plain when it would read back as itself, double-quoted otherwise.
String _yamlScalar(String s) {
  final readsBack =
      _YamlParser._plain(s) == s &&
      s.isNotEmpty &&
      !RegExp(r'''^[\s\-?:,\[\]{}#&*!|>'"%@`]|[:#]\s|\s$|\n''').hasMatch(s) &&
      !s.contains(': ');
  if (readsBack) return s;
  return jsonEncode(s);
}

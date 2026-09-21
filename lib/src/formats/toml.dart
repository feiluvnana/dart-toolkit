part of '../../formats.dart';

/// TOML decoding.
///
/// {@category Formats}
extension StringTomlExtensions on String {
  /// This TOML text as a document: tables and arrays of tables become nested objects and
  /// arrays, dotted keys nest, strings of all four kinds decode, numbers and booleans are
  /// themselves, dates and times stay text.
  ///
  /// Covers TOML 1.0 as scripts use it, checked by `test/formats_test.dart` rather than
  /// against the specification's own suite: redefining a table is not detected.
  ///
  /// Throws [FormatException] with a line number on bad syntax.
  JsonDocument get toml => JsonDocument(_TomlParser(this).parse());
}

final class _TomlParser {
  final String s;
  int i = 0;
  final Map<String, Object?> root = {};
  Map<String, Object?> current;

  _TomlParser(this.s) : current = {} {
    current = root;
  }

  Map<String, Object?> parse() {
    while (true) {
      _skipBlank();
      if (i >= s.length) return root;
      final c = s[i];
      if (c == '[') {
        _tableHeader();
      } else {
        _keyValue(current);
        _lineEnd();
      }
    }
  }

  void _tableHeader() {
    final array = s.startsWith('[[', i);
    i += array ? 2 : 1;
    final path = _key();
    _ws();
    _expect(array ? ']]' : ']');
    var target = root;
    for (final part in path.take(path.length - 1)) {
      target = _child(target, part);
    }
    final name = path.last;
    if (array) {
      final list = (target[name] ??= <Object?>[]) as List;
      final table = <String, Object?>{};
      list.add(table);
      current = table;
    } else {
      current = _child(target, name);
    }
    _lineEnd();
  }

  /// [name] in [table], made if absent; the last element when it is an array of tables.
  Map<String, Object?> _child(Map<String, Object?> table, String name) {
    final existing = table[name];
    if (existing is Map<String, Object?>) return existing;
    if (existing is List && existing.isNotEmpty && existing.last is Map<String, Object?>) {
      return existing.last as Map<String, Object?>;
    }
    if (existing != null) throw _error('"$name" is already a value');
    return table[name] = <String, Object?>{};
  }

  void _keyValue(Map<String, Object?> table) {
    final path = _key();
    _ws();
    _expect('=');
    _ws();
    var target = table;
    for (final part in path.take(path.length - 1)) {
      target = _child(target, part);
    }
    if (target.containsKey(path.last)) throw _error('"${path.last}" is defined twice');
    target[path.last] = _value();
  }

  List<String> _key() {
    final parts = <String>[];
    while (true) {
      _ws();
      if (i < s.length && (s[i] == '"' || s[i] == "'")) {
        parts.add(_string());
      } else {
        final start = i;
        while (i < s.length && _isBare(s.codeUnitAt(i))) {
          i++;
        }
        if (i == start) throw _error('Expected a key');
        parts.add(s.substring(start, i));
      }
      _ws();
      if (i < s.length && s[i] == '.') {
        i++;
        continue;
      }
      return parts;
    }
  }

  Object? _value() {
    if (i >= s.length) throw _error('Expected a value');
    final c = s[i];
    if (c == '"' || c == "'") return _string();
    if (c == '[') return _array();
    if (c == '{') return _inlineTable();
    final start = i;
    while (i < s.length && !',]}\n\r#'.contains(s[i]) && !(s[i] == ' ' && _restIsCommentOrEnd())) {
      i++;
    }
    final token = s.substring(start, i).trim();
    if (token.isEmpty) throw _error('Expected a value');
    return _literal(token);
  }

  bool _restIsCommentOrEnd() {
    var k = i;
    while (k < s.length && s[k] == ' ') {
      k++;
    }
    return k >= s.length || s[k] == '#' || s[k] == '\n' || s[k] == '\r' || s[k] == ',' || s[k] == ']' || s[k] == '}';
  }

  static final _int = RegExp(r'^[+-]?\d+$');
  static final _float = RegExp(r'^[+-]?(\d+\.\d+([eE][+-]?\d+)?|\d+[eE][+-]?\d+)$');
  static final _dateOrTime = RegExp(r'^\d{4}-\d\d-\d\d|^\d\d:\d\d:\d\d');

  Object? _literal(String t) {
    switch (t) {
      case 'true':
        return true;
      case 'false':
        return false;
      case 'inf' || '+inf':
        return double.infinity;
      case '-inf':
        return double.negativeInfinity;
      case 'nan' || '+nan' || '-nan':
        return double.nan;
    }
    final plain = t.replaceAll('_', '');
    if (_int.hasMatch(plain)) return int.parse(plain);
    if (plain.startsWith('0x')) return int.parse(plain.substring(2), radix: 16);
    if (plain.startsWith('0o')) return int.parse(plain.substring(2), radix: 8);
    if (plain.startsWith('0b')) return int.parse(plain.substring(2), radix: 2);
    if (_float.hasMatch(plain)) return double.parse(plain);
    if (_dateOrTime.hasMatch(t)) return t; // dates and times stay text
    throw _error('Not a TOML value: $t');
  }

  String _string() {
    final q = s[i];
    final triple = s.startsWith(q * 3, i);
    i += triple ? 3 : 1;
    if (triple && s.startsWith('\n', i)) i++;
    if (triple && s.startsWith('\r\n', i)) i += 2;
    final sb = StringBuffer();
    while (true) {
      if (i >= s.length) throw _error('Unterminated string');
      if (triple ? s.startsWith(q * 3, i) : s[i] == q) {
        i += triple ? 3 : 1;
        // A quote right before the closing triple belongs to the content.
        while (triple && i < s.length && s[i] == q) {
          sb.write(q);
          i++;
        }
        return sb.toString();
      }
      if (q == '"' && s[i] == r'\') {
        i++;
        final e = s[i];
        switch (e) {
          case 'n':
            sb.write('\n');
          case 't':
            sb.write('\t');
          case 'r':
            sb.write('\r');
          case 'b':
            sb.write('\b');
          case 'f':
            sb.write('\f');
          case '"':
            sb.write('"');
          case r'\':
            sb.write(r'\');
          case 'u' || 'U':
            final n = e == 'u' ? 4 : 8;
            sb.writeCharCode(int.parse(s.substring(i + 1, i + 1 + n), radix: 16));
            i += n;
          case '\n' || '\r' || ' ' || '\t':
            // Line-ending backslash in a multi-line string: skip whitespace and newlines.
            while (i < s.length && ' \t\r\n'.contains(s[i])) {
              i++;
            }
            continue;
          default:
            throw _error('Bad escape \\$e');
        }
        i++;
        continue;
      }
      if (!triple && (s[i] == '\n' || s[i] == '\r')) throw _error('Newline in a single-line string');
      sb.write(s[i]);
      i++;
    }
  }

  List<Object?> _array() {
    i++; // [
    final out = <Object?>[];
    while (true) {
      _skipBlank();
      if (i >= s.length) throw _error('Unterminated array');
      if (s[i] == ']') {
        i++;
        return out;
      }
      out.add(_value());
      _skipBlank();
      if (i < s.length && s[i] == ',') i++;
    }
  }

  Map<String, Object?> _inlineTable() {
    i++; // {
    final out = <String, Object?>{};
    _ws();
    if (i < s.length && s[i] == '}') {
      i++;
      return out;
    }
    while (true) {
      _keyValue(out);
      _ws();
      if (i < s.length && s[i] == ',') {
        i++;
        continue;
      }
      _expect('}');
      return out;
    }
  }

  void _ws() {
    while (i < s.length && (s[i] == ' ' || s[i] == '\t')) {
      i++;
    }
  }

  /// Whitespace, newlines and comments.
  void _skipBlank() {
    while (i < s.length) {
      final c = s[i];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        i++;
      } else if (c == '#') {
        while (i < s.length && s[i] != '\n') {
          i++;
        }
      } else {
        return;
      }
    }
  }

  void _lineEnd() {
    _ws();
    if (i < s.length && s[i] == '#') {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
    }
    if (i < s.length && s[i] != '\n' && s[i] != '\r') throw _error('Expected the end of the line');
  }

  void _expect(String t) {
    if (!s.startsWith(t, i)) throw _error('Expected "$t"');
    i += t.length;
  }

  FormatException _error(String message) {
    final line = s.substring(0, i < s.length ? i : s.length).split('\n').length;
    return FormatException('TOML line $line: $message');
  }

  static bool _isBare(int c) =>
      (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f || c == 0x2d;
}

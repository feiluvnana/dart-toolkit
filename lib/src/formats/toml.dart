part of '../../formats.dart';

final class _TomlParser {
  final String s;
  int i = 0;
  final Map<String, Object?> root = {};
  Map<String, Object?> current;
  int _depth = 0;

  // What made each table, by identity: a `[header]` (defined, so never again), a header's
  // path (implicit, so a later header may define it), a dotted key, or an inline table — which
  // nothing may extend. Only an array `[[header]]` made may be appended to.
  final Set<Object> _implicit = Set.identity();
  final Set<Object> _dotted = Set.identity();
  final Set<Object> _frozen = Set.identity();
  final Set<Object> _tables = Set.identity();

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
      target = _child(target, part, header: true);
    }
    final name = path.last;
    final existing = target[name];
    if (array) {
      final List<Object?> list;
      if (existing == null) {
        _tables.add(list = target[name] = <Object?>[]);
      } else if (_tables.contains(existing)) {
        list = existing as List<Object?>;
      } else {
        throw _error('"$name" is already a value, not an array of tables');
      }
      final table = <String, Object?>{};
      list.add(table);
      current = table;
    } else if (existing == null) {
      current = target[name] = <String, Object?>{};
    } else if (existing is Map<String, Object?> && _implicit.remove(existing)) {
      current = existing;
    } else if (existing is Map<String, Object?>) {
      throw _error('Table "${path.join('.')}" is defined twice');
    } else {
      throw _error('"$name" is already a value');
    }
    _lineEnd();
  }

  /// [name] in [table], made if absent; the last element when it is an array of tables. A
  /// [header] walks through any table but an inline one; a dotted key walks only through the
  /// tables dotted keys made.
  Map<String, Object?> _child(Map<String, Object?> table, String name, {bool header = false}) {
    final existing = table[name];
    if (existing == null) {
      final made = table[name] = <String, Object?>{};
      (header ? _implicit : _dotted).add(made);
      return made;
    }
    if (existing is Map<String, Object?>) {
      if (_frozen.contains(existing)) throw _error('Inline table "$name" cannot be extended');
      if (!header && !_dotted.contains(existing)) throw _error('Table "$name" is already defined');
      return existing;
    }
    if (existing is List && _tables.contains(existing)) {
      if (!header) throw _error('Array of tables "$name" cannot take a dotted key');
      return existing.last as Map<String, Object?>;
    }
    throw _error('"$name" is already a value');
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
    if (c == '[' || c == '{') {
      if (++_depth > 1000) throw _error('nested deeper than 1000');
      final v = c == '[' ? _array() : _freeze(_inlineTable());
      _depth--;
      return v;
    }
    // A token runs to the next delimiter and drops the spaces before it, which is what lets
    // `1979-05-27 07:32:00Z` keep its inner space.
    final start = i;
    while (i < s.length && !_delimiter(s.codeUnitAt(i))) {
      i++;
    }
    final token = s.substring(start, i).trim();
    if (token.isEmpty) throw _error('Expected a value');
    return _literal(token);
  }

  static bool _delimiter(int c) => c == 0x2c || c == 0x5d || c == 0x7d || c == 0x0a || c == 0x0d || c == 0x23;

  /// Closes [table], and every table inside it, to later keys and headers.
  Map<String, Object?> _freeze(Map<String, Object?> table) {
    _frozen.add(table);
    for (final v in table.values) {
      if (v is Map<String, Object?>) _freeze(v);
    }
    return table;
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
    // TOML integers are 64-bit, and one that does not fit is an error, not a rounding.
    final radix = switch (plain.length > 2 ? plain.substring(0, 2) : '') {
      '0x' => 16,
      '0o' => 8,
      '0b' => 2,
      _ => _int.hasMatch(plain) ? 10 : 0,
    };
    if (radix != 0) {
      return int.tryParse(radix == 10 ? plain : plain.substring(2), radix: radix) ??
          (throw _error('Integer out of range: $t'));
    }
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
        if (i >= s.length) throw _error('Unterminated string');
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
            var code = 0;
            for (var k = 1; k <= n; k++) {
              final d = i + k < s.length ? _hex(s.codeUnitAt(i + k)) : -1;
              if (d < 0) throw _error('\\$e needs $n hex digits');
              code = code * 16 + d;
            }
            if (code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
              throw _error('\\$e${s.substring(i + 1, i + 1 + n)} is not a Unicode scalar value');
            }
            sb.writeCharCode(code);
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
      if (i < s.length && s[i] == ',') {
        i++;
      } else if (i >= s.length || s[i] != ']') {
        throw _error('Expected "," or "]"');
      }
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

  static int _hex(int c) => switch (c) {
    >= 0x30 && <= 0x39 => c - 0x30,
    >= 0x41 && <= 0x46 => c - 0x37,
    >= 0x61 && <= 0x66 => c - 0x57,
    _ => -1,
  };

  static bool _isBare(int c) =>
      (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f || c == 0x2d;
}

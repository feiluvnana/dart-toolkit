part of '../../json.dart';

final class _TomlParser {
  final String s;
  int i = 0;
  final Map<String, Object?> root = {};
  late Map<String, Object?> current = root;
  int _depth = 0;

  /// How deep the current `[table]` header is.
  int _tableDepth = 0;

  // What made each table, by identity: a `[header]` (defined, so never again), a header's
  // path (implicit, so a later header may define it), a dotted key, or an inline table — which
  // nothing may extend. Only an array `[[header]]` made may be appended to.
  final Set<Object> _implicit = Set.identity();
  final Set<Object> _dotted = Set.identity();
  final Set<Object> _frozen = Set.identity();
  final Set<Object> _tables = Set.identity();

  _TomlParser(this.s);

  Map<String, Object?> parse() {
    while (true) {
      _skipBlank();
      if (i >= s.length) return root;
      if (s.codeUnitAt(i) == 0x5B /* [ */ ) {
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
    if (path.length > 1000) throw _error('nested deeper than 1000');
    _tableDepth = path.length;
    _ws();
    _expect(array ? ']]' : ']');
    var target = root;
    for (final part in path.take(path.length - 1)) {
      target = _child(target, part, header: true);
    }
    final name = path.last;
    final existing = target[name];
    if (array) {
      if (existing == null) {
        _tables.add(target[name] = <Object?>[]);
      } else if (!_tables.contains(existing)) {
        throw _error('"$name" is already a value, not an array of tables');
      }
      (target[name] as List<Object?>).add(current = <String, Object?>{});
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
    // Dotted keys nest as brackets do, and count toward the same bound.
    if (_tableDepth + _depth + path.length > 1000) throw _error('nested deeper than 1000');
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
      if (i < s.length && (s.codeUnitAt(i) == 0x22 || s.codeUnitAt(i) == 0x27)) {
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
      if (i < s.length && s.codeUnitAt(i) == 0x2E /* . */ ) {
        i++;
        continue;
      }
      return parts;
    }
  }

  Object? _value() {
    if (i >= s.length) throw _error('Expected a value');
    final c = s.codeUnitAt(i);
    if (c == 0x22 || c == 0x27) return _string();
    if (c == 0x5B || c == 0x7B) {
      // [ or {
      if (++_depth > 1000) throw _error('nested deeper than 1000');
      final v = c == 0x5B ? _array() : _freeze(_inlineTable());
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

  static final _float = RegExp(r'^[+-]?(\d+\.\d+([eE][+-]?\d+)?|\d+[eE][+-]?\d+)$');
  // `_` only between digits: hex ones after `0x`, decimal ones elsewhere, so `1e_5` is refused.
  static final _strayUnderscore = RegExp(r'(?<!\d)_|_(?!\d)');
  static final _strayHexUnderscore = RegExp(r'(?<![0-9A-Fa-f])_|_(?![0-9A-Fa-f])');
  static final _date = RegExp(r'^(\d{4})-(\d\d)-(\d\d)');
  static final _time = RegExp(r'^(\d\d):(\d\d)(?::(\d\d)(?:\.\d+)?)?(?:[Zz]|[+-]\d\d:\d\d)?$');

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
    if (t.contains('_') && (t.startsWith('0x') ? _strayHexUnderscore : _strayUnderscore).hasMatch(t)) {
      throw _error('Misplaced "_" in $t');
    }
    final plain = t.replaceAll('_', '');
    // TOML integers are 64-bit, and one that does not fit is an error, not a rounding.
    final radix = switch (plain.length > 2 ? plain.substring(0, 2) : '') {
      '0x' => 16,
      '0o' => 8,
      '0b' => 2,
      _ => _isInt(plain) ? 10 : 0,
    };
    final float = radix == 0 && _float.hasMatch(plain);
    if ((radix == 10 || float) && _leadsWithZero(plain)) {
      throw _error('Leading zero in $t');
    }
    if (radix != 0) {
      return int.tryParse(radix == 10 ? plain : plain.substring(2), radix: radix) ??
          (throw _error('Integer out of range: $t'));
    }
    if (float) return double.parse(plain);
    if (_isDateOrTime(t)) return t; // dates and times stay text
    throw _error('Not a TOML value: $t');
  }

  // Scans, not RegExps: every number in a document goes through these, and AOT interprets regexes.

  /// Whether [t] is `[+-]?\d+`.
  static bool _isInt(String t) {
    var i = t.startsWith('+') || t.startsWith('-') ? 1 : 0;
    if (i == t.length) return false;
    for (; i < t.length; i++) {
      if (!_isDigit(t.codeUnitAt(i))) return false;
    }
    return true;
  }

  /// Whether [t] starts `[+-]?0\d`.
  static bool _leadsWithZero(String t) {
    final i = t.startsWith('+') || t.startsWith('-') ? 1 : 0;
    return t.length > i + 1 && t.codeUnitAt(i) == 0x30 && _isDigit(t.codeUnitAt(i + 1));
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  /// Whether [t] is a whole RFC 3339 date, time or both, each field in range.
  static bool _isDateOrTime(String t) {
    int at(RegExpMatch m, int g) => int.parse(m.group(g) ?? '0');
    var rest = t;
    if (_date.firstMatch(t) case final d?) {
      if (at(d, 2) < 1 || at(d, 2) > 12 || at(d, 3) < 1 || at(d, 3) > 31) return false;
      rest = t.substring(d.end);
      if (rest.isEmpty) return true;
      if (!'Tt '.contains(rest[0])) return false;
      rest = rest.substring(1);
    }
    final time = _time.firstMatch(rest);
    return time != null && at(time, 1) < 24 && at(time, 2) < 60 && at(time, 3) <= 60;
  }

  String _string() {
    final qCode = s.codeUnitAt(i);
    final q = s[i];
    final tripleQuote = q * 3;
    final triple = s.startsWith(tripleQuote, i);
    i += triple ? 3 : 1;
    if (triple && s.startsWith('\n', i)) i++;
    if (triple && s.startsWith('\r\n', i)) i += 2;
    final sb = StringBuffer();
    var chunkStart = i;
    while (true) {
      if (i >= s.length) throw _error('Unterminated string');
      final c = s.codeUnitAt(i);
      if (triple ? s.startsWith(tripleQuote, i) : c == qCode) {
        if (i > chunkStart) sb.write(s.substring(chunkStart, i));
        i += triple ? 3 : 1;
        // A quote right before the closing triple belongs to the content.
        final extraStart = i;
        while (triple && i < s.length && s.codeUnitAt(i) == qCode) {
          i++;
        }
        if (i > extraStart) sb.write(s.substring(extraStart, i));
        return sb.toString();
      }
      if (qCode == 0x22 /* " */ && c == 0x5C /* \ */ ) {
        if (i > chunkStart) sb.write(s.substring(chunkStart, i));
        i++;
        if (i >= s.length) throw _error('Unterminated string');
        final e = s[i];
        switch (e) {
          case 'n' || 't' || 'r' || 'b' || 'f' || '"' || r'\':
            sb.write(_escapes[e]);
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
            // Line-ending backslash in a multi-line string: skip whitespace and newlines. Only
            // blanks may sit between it and the end of its line.
            var eol = i;
            while (eol < s.length && (s.codeUnitAt(eol) == 0x20 || s.codeUnitAt(eol) == 0x09)) {
              eol++;
            }
            if (!triple || eol == s.length || (s.codeUnitAt(eol) != 0x0A && s.codeUnitAt(eol) != 0x0D)) {
              throw _error('Bad escape \\$e');
            }
            while (i < s.length) {
              final cu = s.codeUnitAt(i);
              if (cu != 0x20 && cu != 0x09 && cu != 0x0D && cu != 0x0A) break;
              i++;
            }
            chunkStart = i;
            continue;
          default:
            throw _error('Bad escape \\$e');
        }
        i++;
        chunkStart = i;
        continue;
      }
      if (!triple && (c == 0x0A || c == 0x0D)) throw _error('Newline in a single-line string');
      i++;
    }
  }

  List<Object?> _array() {
    i++; // [
    final out = <Object?>[];
    while (true) {
      _skipBlank();
      if (i >= s.length) throw _error('Unterminated array');
      if (s.codeUnitAt(i) == 0x5D /* ] */ ) {
        i++;
        return out;
      }
      out.add(_value());
      _skipBlank();
      if (i < s.length && s.codeUnitAt(i) == 0x2C /* , */ ) {
        i++;
      } else if (i >= s.length || s.codeUnitAt(i) != 0x5D /* ] */ ) {
        throw _error('Expected "," or "]"');
      }
    }
  }

  Map<String, Object?> _inlineTable() {
    i++; // {
    final out = <String, Object?>{};
    _ws();
    if (i < s.length && s.codeUnitAt(i) == 0x7D /* } */ ) {
      i++;
      return out;
    }
    while (true) {
      _keyValue(out);
      _ws();
      if (i < s.length && s.codeUnitAt(i) == 0x2C /* , */ ) {
        i++;
        continue;
      }
      _expect('}');
      return out;
    }
  }

  void _ws() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c != 0x20 && c != 0x09) break;
      i++;
    }
  }

  /// Whitespace, newlines and comments.
  void _skipBlank() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        i++;
      } else if (c == 0x23 /* # */ ) {
        _comment();
      } else {
        return;
      }
    }
  }

  void _lineEnd() {
    _ws();
    _comment();
    if (i < s.length && s.codeUnitAt(i) != 0x0A && s.codeUnitAt(i) != 0x0D) {
      throw _error('Expected the end of the line');
    }
  }

  void _comment() {
    if (i < s.length && s.codeUnitAt(i) == 0x23) {
      while (i < s.length && s.codeUnitAt(i) != 0x0A) {
        i++;
      }
    }
  }

  void _expect(String t) {
    if (!s.startsWith(t, i)) throw _error('Expected "$t"');
    i += t.length;
  }

  FormatException _error(String message) {
    var line = 1;
    final limit = i < s.length ? i : s.length;
    for (var k = 0; k < limit; k++) {
      if (s.codeUnitAt(k) == 0x0A) line++;
    }
    return FormatException('TOML line $line: $message');
  }

  static const _escapes = {'n': '\n', 't': '\t', 'r': '\r', 'b': '\b', 'f': '\f', '"': '"', r'\': r'\'};

  static int _hex(int c) => switch (c) {
    >= 0x30 && <= 0x39 => c - 0x30,
    >= 0x41 && <= 0x46 => c - 0x37,
    >= 0x61 && <= 0x66 => c - 0x57,
    _ => -1,
  };

  static bool _isBare(int c) =>
      (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f || c == 0x2d;
}

/// [doc] as TOML: each table's values first, then its tables under `[a.b]` headers and its
/// arrays of tables under `[[a.b]]`; a table with only tables below it gets no header of its
/// own. A `null` (TOML has none) or a root that is not a map is a [FormatException] naming where.
String _toml(Doc doc) {
  final root = doc.raw;
  if (root is! Map<Object?, Object?>) throw FormatException('Invalid TOML at \$: ${_kind(root)}, not a map');
  final out = StringBuffer();
  // Tables still to write, last first: the map, its header's keys, its JSONPath, and whether it
  // is an element of an array of tables.
  final pending = <(Map<Object?, Object?>, List<String>, String, bool)>[(root, const [], r'$', false)];
  while (pending.isNotEmpty) {
    final (table, name, at, element) = pending.removeLast();
    final values = <MapEntry<Object?, Object?>>[];
    final below = <(Map<Object?, Object?>, List<String>, String, bool)>[];
    for (final MapEntry(:key, value: v) in table.entries) {
      final value = v is Doc ? v.raw : v;
      if (value is Map<Object?, Object?>) {
        below.add((value, [...name, '$key'], Doc._key(at, '$key'), false));
      } else if (value is List<Object?> && value.isNotEmpty && value.every((x) => (x is Doc ? x.raw : x) is Map)) {
        final where = Doc._key(at, '$key');
        for (final (i, x) in value.indexed) {
          below.add(((x is Doc ? x.raw : x) as Map<Object?, Object?>, [...name, '$key'], '$where[$i]', true));
        }
      } else {
        values.add(MapEntry(key, value));
      }
    }
    if (element || name.isNotEmpty && (values.isNotEmpty || below.isEmpty)) {
      if (out.isNotEmpty) out.writeln();
      final header = name.map(_tomlKey).join('.');
      out.writeln(element ? '[[$header]]' : '[$header]');
    }
    for (final MapEntry(:key, :value) in values) {
      out
        ..write(_tomlKey('$key'))
        ..write(' = ');
      _tomlValue(out, value, at, '$key');
      out.writeln();
    }
    pending.addAll(below.reversed);
  }
  return out.toString();
}

String _tomlKey(String key) => _isTomlBare(key) ? key : _tomlString(key);

bool _isTomlBare(String key) {
  if (key.isEmpty) return false;
  for (var i = 0; i < key.length; i++) {
    if (!_TomlParser._isBare(key.codeUnitAt(i))) return false;
  }
  return true;
}

/// [value], at key [key] (a `String` or an index) below [parent], written into [out] as an inline
/// TOML value. The path a failure names is joined only when one is thrown.
void _tomlValue(StringBuffer out, Object? value, String parent, Object key) {
  String path() => key is int ? '$parent[$key]' : Doc._key(parent, '$key');
  switch (value) {
    case null:
      throw FormatException('Invalid TOML at ${path()}: null has no TOML form');
    case final Doc d:
      _tomlValue(out, d.raw, parent, key);
    case final String s:
      _writeTomlString(out, s);
    case final double d when d.isNaN:
      out.write('nan');
    case final double d when d.isInfinite:
      out.write(d.isNegative ? '-inf' : 'inf');
    case final DateTime d:
      out.write(d.toIso8601String());
    case bool() || num():
      out.write(value);
    case final List<Object?> l:
      final at = path();
      out.write('[');
      for (final (i, x) in l.indexed) {
        if (i > 0) out.write(', ');
        _tomlValue(out, x, at, i);
      }
      out.write(']');
    case final Map<Object?, Object?> m:
      final at = path();
      out.write('{');
      var first = true;
      for (final MapEntry(key: k, value: x) in m.entries) {
        if (!first) out.write(', ');
        first = false;
        out
          ..write(_tomlKey('$k'))
          ..write(' = ');
        _tomlValue(out, x, at, '$k');
      }
      out.write('}');
    default:
      _writeTomlString(out, '$value');
  }
}

/// [s] as a TOML basic string.
String _tomlString(String s) {
  final out = StringBuffer();
  _writeTomlString(out, s);
  return out.toString();
}

/// [s] as a TOML basic string into [out], the runs between escapes copied whole.
void _writeTomlString(StringBuffer out, String s) {
  out.write('"');
  var from = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final String escape;
    switch (c) {
      case 0x22:
        escape = r'\"';
      case 0x5c:
        escape = r'\\';
      case 0x08:
        escape = r'\b';
      case 0x09:
        escape = r'\t';
      case 0x0a:
        escape = r'\n';
      case 0x0c:
        escape = r'\f';
      case 0x0d:
        escape = r'\r';
      case < 0x20 || 0x7f:
        escape = '\\u${c.toRadixString(16).padLeft(4, '0')}';
      default:
        continue;
    }
    if (i > from) out.write(s.substring(from, i));
    out.write(escape);
    from = i + 1;
  }
  out
    ..write(from == 0 ? s : s.substring(from))
    ..write('"');
}

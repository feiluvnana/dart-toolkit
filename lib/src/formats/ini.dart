part of '../../json.dart';

final _iniNewline = RegExp(r'\r\n?|\n');

int _findAssign(String line) {
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (c == 0x3d || c == 0x3a) return i;
  }
  return -1;
}

int _findComment(String value) {
  for (var i = 0; i < value.length - 1; i++) {
    final c = value.codeUnitAt(i);
    if (c == 0x20 || c == 0x09) {
      final next = value.codeUnitAt(i + 1);
      if (next == 0x3b || next == 0x23) return i;
    }
  }
  return -1;
}

Map<String, Object?> _parseIni(String text) {
  final root = <String, Object?>{};
  var section = root;
  var n = 0;
  // [name] in [table], made if absent.
  Map<String, Object?> table(Map<String, Object?> table, String name) => switch (table[name] ??= <String, Object?>{}) {
    final Map<String, Object?> t => t,
    _ => throw FormatException('INI line $n: "$name" is already a value'),
  };
  // [value] at the dotted [key], or at [key] whole when a part of it is already a value or the
  // key already holds a table; returns where it went, for continuation lines.
  (Map<String, Object?>, String) put(Map<String, Object?> section, String key, Object? value) {
    var target = section;
    final parts = key.split('.');
    for (final part in parts.take(parts.length - 1)) {
      final next = target[part] ??= <String, Object?>{};
      if (next is! Map<String, Object?>) return (section..[key] = value, key);
      target = next;
    }
    if (target[parts.last] is Map) {
      if (parts.length == 1) throw FormatException('INI line $n: "$key" is already a table');
      return (section..[key] = value, key);
    }
    return (target..[parts.last] = value, parts.last);
  }

  // The last key's indent, map and name: a more indented line continues its value.
  (int, Map<String, Object?>, String)? last;
  for (final raw in text.split(_iniNewline)) {
    n++;
    final line = raw.trim();
    if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) continue;
    // A more indented line continues the value, even one that looks like `[a section]`.
    final indent = raw.length - raw.trimLeft().length;
    if (last case (final lastIndent, final map, final key) when indent > lastIndent) {
      final existing = map[key];
      map[key] = existing == null || existing == '' ? line : '$existing\n$line';
      continue;
    }
    final close = line.startsWith('[') ? line.indexOf(']') : -1;
    // `[section] ; comment` is a section too.
    final rest = close != -1 && close < line.length - 1 ? line.substring(close + 1).trimLeft() : '';
    if (close != -1 && (close == line.length - 1 || rest.startsWith(';') || rest.startsWith('#'))) {
      section = root;
      for (final part in _sectionName(line.substring(1, close))) {
        section = table(section, part);
      }
      last = null;
      continue;
    }
    final eq = _findAssign(line);
    if (eq == -1) {
      section[line] = '';
      last = (indent, section, line);
      continue;
    }
    final key = line.substring(0, eq).trim();
    var value = line.substring(eq + 1).trim();
    final quote = value.length >= 2 && (value[0] == '"' || value[0] == "'") ? value.indexOf(value[0], 1) : -1;
    if (quote != -1) {
      value = value.substring(1, quote);
    } else {
      final comment = _findComment(value);
      if (comment != -1) value = value.substring(0, comment).trim();
    }
    final (map, at) = put(section, key, value);
    last = (indent, map, at);
  }
  return root;
}

/// A section name's parts: split at dots, except inside double quotes, and before a quoted
/// part, which is git's subsection — `remote "a.b"` is `remote` then `a.b`.
List<String> _sectionName(String name) {
  final parts = <String>[];
  final sb = StringBuffer();
  void end() {
    final part = sb.toString().trim();
    if (part.isNotEmpty) parts.add(part);
    sb.clear();
  }

  for (var i = 0; i < name.length; i++) {
    final c = name[i];
    if (c == '"') {
      end();
      final close = name.indexOf('"', i + 1);
      final stop = close == -1 ? name.length : close;
      parts.add(name.substring(i + 1, stop));
      i = stop;
    } else if (c == '.') {
      end();
    } else {
      sb.write(c);
    }
  }
  end();
  return parts;
}

/// [doc] as INI: the root's values, then a `[section]` per map (`[a.b]` for one inside another),
/// each with its values; text that would read back otherwise is quoted, and a line break
/// continues on an indented line. What would not read back as itself is a [FormatException]
/// naming where: a list or a root that is not a map (INI has neither), a key that holds `=`, `:`,
/// `.` or a line break or starts like a comment or a section, a value that needs both quotes, and
/// a continued line that is blank, padded, quoted or starts like a comment.
String _ini(Doc doc) {
  final root = doc.raw;
  if (root is! Map<Object?, Object?>) throw FormatException('Invalid INI at \$: ${_kind(root)}, not a map');
  final out = StringBuffer();
  final pending = <(Map<Object?, Object?>, List<String>, String)>[(root, const [], r'$')];
  while (pending.isNotEmpty) {
    final (section, name, path) = pending.removeLast();
    // A failure's path is joined only when one is thrown.
    Never fail(Object? key, String why) => throw FormatException('Invalid INI at ${Doc._key(path, '$key')}: $why');
    final values = <(String, Object?)>[];
    final below = <(Map<Object?, Object?>, List<String>, String)>[];
    for (final MapEntry(:key, value: v) in section.entries) {
      final value = v is Doc ? v.raw : v;
      switch (value) {
        case final Map<Object?, Object?> m:
          below.add((m, [...name, '$key'], Doc._key(path, '$key')));
        case List<Object?>():
          fail(key, 'a list has no INI form');
        default:
          final k = '$key';
          if (k.isEmpty || k != k.trim() || k.contains(_iniKeyBreak) || _iniLead.contains(k[0])) {
            fail(key, 'the key is empty, padded, holds = : . or a line break, or starts with ; # or [');
          }
          values.add((k, value));
      }
    }
    if (name.isNotEmpty && (values.isNotEmpty || below.isEmpty)) {
      if (out.isNotEmpty) out.writeln();
      out.writeln('[${name.map(_iniSection).join('.')}]');
    }
    for (final (key, value) in values) {
      if (value == null) {
        out.writeln('$key =');
      } else {
        out.writeln('$key = ${_iniValue(value) ?? fail(key, 'the value would not read back as itself')}');
      }
    }
    pending.addAll(below.reversed);
  }
  return out.toString();
}

final _iniKeyBreak = RegExp(r'[=:.\n\r]');

/// What a key may not start with: a comment or a section.
const _iniLead = ';#[';

final _iniSectionBreak = RegExp(r'[.\]"\s]');

/// A section name's part, quoted when it holds what would split it.
String _iniSection(String part) => part.contains(_iniSectionBreak) ? '"$part"' : part;

/// [value] as an INI value: as written when it reads back as itself, else quoted; each line
/// break continues on an indented line. `null` when no spelling reads back as [value].
String? _iniValue(Object value) {
  final text = value is DateTime ? value.toIso8601String() : '$value';
  if (text.contains('\r')) return null;
  if (text.contains('\n')) {
    final lines = text.split('\n');
    final readable =
        lines.every((l) => l.isNotEmpty && _iniPlain(l)) && lines.skip(1).every((l) => l[0] != ';' && l[0] != '#');
    return readable ? lines.join('\n  ') : null;
  }
  if (_iniPlain(text)) return text;
  if (!text.contains('"')) return '"$text"';
  return text.contains("'") ? null : "'$text'";
}

/// Whether [text] reads back as itself unquoted: no padding, no opening quote, no comment.
bool _iniPlain(String text) =>
    text == text.trim() &&
    !text.startsWith('"') &&
    !text.startsWith("'") &&
    !text.contains(' ;') &&
    !text.contains(' #') &&
    !text.contains('\t;') &&
    !text.contains('\t#');

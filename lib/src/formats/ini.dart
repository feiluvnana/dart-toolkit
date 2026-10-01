part of '../../formats.dart';

/// INI decoding.
///
/// {@category Formats}
extension StringIniExtensions on String {
  /// This INI text as a document: one object per `[section]`, keys before any section at the
  /// root. `;` and `#` start comments; `key = value` and `key: value` both work; quoted values
  /// lose their quotes.
  ///
  /// Dots nest: `a.b = 1` and `[server.tls]` are tables inside tables. A key that cannot nest
  /// — `x.y.z` after `x.y` is already a value, or `x.y` after it is already a table, as Java
  /// properties files write them — stays whole in its section, so `log4j.appender.A1` and
  /// `log4j.appender.A1.layout` both read back. A quoted part of a section name is one name,
  /// dots and all: `["www.example.com"]`, and git's `[remote "origin"]` is `remote.origin`.
  JsonDocument get ini => JsonDocument(_parseIni(this));
}

final _iniNewline = RegExp(r'\r?\n');

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
  // [name] in [table], made if absent; a name already holding a value cannot become a table.
  Map<String, Object?> table(Map<String, Object?> table, String name) => switch (table[name] ??= <String, Object?>{}) {
    final Map<String, Object?> t => t,
    _ => throw FormatException('INI line $n: "$name" is already a value'),
  };
  // [value] at the dotted [key] in [section], or at [key] whole when a part of it is already
  // a value, or the key already holds a table.
  (Map<String, Object?>, String) put(Map<String, Object?> section, String key, Object? value) {
    var target = section;
    final parts = key.split('.');
    for (final part in parts.take(parts.length - 1)) {
      final next = target[part] ??= <String, Object?>{};
      if (next is! Map<String, Object?>) {
        section[key] = value;
        return (section, key);
      }
      target = next;
    }
    if (parts.length > 1 && target[parts.last] is Map) {
      section[key] = value;
      return (section, key);
    } else if (target[parts.last] is Map) {
      throw FormatException('INI line $n: "${parts.last}" is already a table');
    } else {
      target[parts.last] = value;
      return (target, parts.last);
    }
  }

  int? lastIndent;
  Map<String, Object?>? lastTarget;
  String? lastKey;

  for (final raw in text.split(_iniNewline)) {
    n++;
    final line = raw.trim();
    if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) continue;
    final close = line.startsWith('[') ? line.indexOf(']') : -1;
    // `[section] ; comment` is a section too.
    final rest = close != -1 && close < line.length - 1 ? line.substring(close + 1).trimLeft() : '';
    if (close != -1 && (close == line.length - 1 || rest.startsWith(';') || rest.startsWith('#'))) {
      section = root;
      for (final part in _sectionName(line.substring(1, close))) {
        section = table(section, part);
      }
      lastIndent = null;
      lastTarget = null;
      lastKey = null;
      continue;
    }
    final rawIndent = raw.length - raw.trimLeft().length;
    if (lastKey != null && lastTarget != null && lastIndent != null && rawIndent > lastIndent) {
      final existing = lastTarget[lastKey];
      lastTarget[lastKey] = existing == null ? line : '$existing\n$line';
      continue;
    }
    final eq = _findAssign(line);
    if (eq == -1) {
      section[line] = null;
      lastIndent = rawIndent;
      lastTarget = section;
      lastKey = line;
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
    final (t, k) = put(section, key, quote != -1 ? value : _scalar(value));
    lastIndent = rawIndent;
    lastTarget = t;
    lastKey = k;
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

/// `true`, `42`, `1.5` and `null` as themselves, anything else as text — a number only when
/// it reads back as written, so `1.10`, `007`, `0x10` and `NaN` keep what they said.
Object? _scalar(String v) => switch (v) {
  'true' || 'yes' || 'on' => true,
  'false' || 'no' || 'off' => false,
  'null' || 'none' || '~' || '' => null,
  _ => switch ((int.tryParse(v), double.tryParse(v))) {
    (final int i, _) when '$i' == v => i,
    (null, final double d) when d.isFinite && '$d' == v => d,
    _ => v,
  },
};

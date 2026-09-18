part of '../../formats.dart';

/// INI decoding.
///
/// {@category Formats}
extension StringIniExtensions on String {
  /// This INI text as a document: one object per `[section]`, keys before any section at the
  /// root. `;` and `#` start comments; `key = value` and `key: value` both work; quoted values
  /// lose their quotes; `a.b = 1` nests.
  JsonDocument get ini => JsonDocument(_parseIni(this));
}

Map<String, Object?> _parseIni(String text) {
  final root = <String, Object?>{};
  var section = root;
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      section = root;
      for (final part in line.substring(1, line.length - 1).trim().split('.')) {
        section = (section[part] ??= <String, Object?>{}) as Map<String, Object?>;
      }
      continue;
    }
    final eq = line.indexOf(RegExp('[=:]'));
    if (eq == -1) {
      section[line] = null;
      continue;
    }
    final key = line.substring(0, eq).trim();
    var value = line.substring(eq + 1).trim();
    final close = value.length >= 2 && (value[0] == '"' || value[0] == "'") ? value.indexOf(value[0], 1) : -1;
    if (close != -1) {
      value = value.substring(1, close);
    } else {
      final comment = value.indexOf(RegExp(r'\s[;#]'));
      if (comment != -1) value = value.substring(0, comment).trim();
    }
    var target = section;
    final parts = key.split('.');
    for (final part in parts.take(parts.length - 1)) {
      target = (target[part] ??= <String, Object?>{}) as Map<String, Object?>;
    }
    target[parts.last] = close != -1 ? value : _scalar(value);
  }
  return root;
}

/// `true`, `42`, `1.5` and `null` as themselves, anything else as text.
Object? _scalar(String v) => switch (v) {
  'true' || 'yes' || 'on' => true,
  'false' || 'no' || 'off' => false,
  'null' || 'none' || '~' || '' => null,
  _ => int.tryParse(v) ?? double.tryParse(v) ?? v,
};

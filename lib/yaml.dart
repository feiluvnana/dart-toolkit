/// Reading YAML: a document becomes the same [Json] value, so config files,
/// `pubspec.yaml` and CI workflows read with `$`, `or` and `text`. Thin
/// facade over `package:yaml`; read only.
///
/// ```dart
/// final version = await Fs.file('pubspec.yaml').yaml().$('version').text();
/// final jobs = (await Fs.file('.github/workflows/ci.yml').yaml()).$('jobs').length;
/// ```
///
/// Public surface is exactly: [Yaml], [ReaderYaml].
/// - `Yaml.parse()` reads the first document of a YAML text.
/// - `reader.yaml()` parses any [Reader], with `or:` for a missing source.
/// Everything else is private.
library;

import 'dart:io' show PathNotFoundException;

import 'package:yaml/yaml.dart' as y;

import 'json.dart';
export 'json.dart';

/// Entry point: YAML text to a [Json].
abstract final class Yaml {
  /// The first document of [text] as a [Json] (maps, lists, scalars; anchors
  /// and aliases resolved). Throws [ContentException] naming the line.
  static Json parse(String text, {String? from}) {
    try {
      return Json.of(_plain(y.loadYaml(text)));
    } on y.YamlException catch (e) {
      final line = e.span == null ? '' : ' at line ${e.span!.start.line + 1}';
      throw ContentException(
        'invalid YAML${from == null ? '' : ' in $from'}$line: ${e.message}',
        text,
        e.span?.start.offset,
        e,
      );
    }
  }
}

/// Plain Dart values: string keys, lists and maps the `Json` rules read.
Object? _plain(Object? v) => switch (v) {
  final Map<dynamic, dynamic> m => {for (final e in m.entries) '${e.key}': _plain(e.value)},
  final List<dynamic> l => [for (final e in l) _plain(e)],
  _ => v,
};

/// `reader.yaml()`: [or] is returned when the source does not exist.
extension ReaderYaml on Reader {
  Future<Json> yaml({Json? or}) async {
    final String text;
    try {
      text = await this.text();
    } on PathNotFoundException {
      if (or != null) return or;
      rethrow;
    }
    final o = origin();
    return Yaml.parse(text, from: o.path() ?? o.url());
  }
}

/// The Future mirror (rule 4).
extension ReaderFutureYaml on Future<Reader> {
  Future<Json> yaml({Json? or}) async => (await this).yaml(or: or);
}

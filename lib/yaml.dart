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
    final where = from == null ? '' : ' in $from';
    if (_flowDepth(text) > 1000) throw ContentException('YAML$where nested too deep', text);
    try {
      final doc = y.loadYaml(text);
      // Aliases share nodes, so a few hundred bytes can stand for billions
      // of them once copied out (an alias bomb): count first, with a memo.
      if (_size(doc, Map.identity()) > _maxNodes) {
        throw ContentException('YAML$where expands past $_maxNodes values (nested aliases)', text);
      }
      return Json.of(_plain(doc));
    } on StackOverflowError {
      throw ContentException('YAML$where nested too deep', text);
    } on y.YamlException catch (e) {
      final line = e.span == null ? '' : ' at line ${e.span!.start.line + 1}';
      throw ContentException('invalid YAML$where$line: ${e.message}', text, e.span?.start.offset, e);
    }
  }
}

const _maxNodes = 1000000;

/// The deepest `[`/`{` nesting in [text] (quotes not excluded: only a cap):
/// `package:yaml` recurses per level and takes seconds to overflow.
int _flowDepth(String text) {
  var depth = 0, most = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x5B || c == 0x7B) {
      if (++depth > most) most = depth;
    } else if ((c == 0x5D || c == 0x7D) && depth > 0) {
      depth--;
    }
  }
  return most;
}

/// How many values [v] stands for once every alias is copied out; each
/// shared node is counted once and then reused from [seen].
int _size(Object? v, Map<Object, int> seen) {
  if (v is! Map && v is! List) return 1;
  final known = seen[v!];
  if (known != null) return known;
  var n = 1;
  if (v is Map) {
    for (final e in v.values) {
      n += _size(e, seen);
    }
  } else {
    for (final e in v as List) {
      n += _size(e, seen);
    }
  }
  return seen[v] = n > _maxNodes ? _maxNodes + 1 : n;
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

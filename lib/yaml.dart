/// Reading YAML: a document becomes the same [Json] value, so config files,
/// `pubspec.yaml` and CI workflows read with `$`, `or` and `text`. In-house
/// YAML 1.2 reader (`src/yaml_parser.dart`); read only.
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

import 'json.dart';
export 'core.dart';
export 'json.dart' show Json, JsonFuture, ReaderJson, ReaderFutureJson;

import 'src/missing.dart';
import 'src/names.dart' as names;
import 'src/yaml_parser.dart' as y;

/// Entry point: YAML text to a [Json].
abstract final class Yaml {
  /// The first document of [text] as a [Json] (maps with string keys,
  /// lists, scalars by the YAML 1.2 core schema; anchors and aliases
  /// resolved; later documents ignored). Throws [ContentException] naming
  /// the line.
  static Json parse(String text) => _parse(text, null);
}

Json _parse(String text, String? from) {
  final where = from == null ? '' : ' in $from';
  try {
    final doc = y.parseYaml(text);
    // Aliases share nodes, so a few hundred bytes can stand for billions
    // of them once walked (an alias bomb): count first, with a memo.
    if (_size(doc, Map.identity()) > _maxNodes) {
      throw ContentException('YAML$where expands past $_maxNodes values (nested aliases)', text);
    }
    return Json.of(doc);
  } on y.YamlError catch (e) {
    final line = '\n'.allMatches(text.substring(0, e.offset.clamp(0, text.length))).length + 1;
    throw ContentException('invalid YAML$where at line $line: ${e.message}', text, e.offset, e);
  }
}

const _maxNodes = 1000000;

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

/// `reader.yaml()`: [or] is returned when the source is missing.
extension ReaderYaml on Reader {
  /// The body parsed as YAML into a [Json]; [or] when the source is missing
  /// (a missing file, an HTTP 404 or 410).
  Future<Json> yaml({Json? or}) => orMissing(this, or, _yaml);
}

Future<Json> _yaml(Reader r) async {
  final text = await r.text();
  final o = r.origin();
  final url = o.url();
  return _parse(text, o.path() ?? (url == null ? null : names.redact(url)));
}

/// The Future mirror (rule 4).
extension ReaderFutureYaml on Future<Reader> {
  Future<Json> yaml({Json? or}) => orMissing(this, or, (r) => r.yaml());
}

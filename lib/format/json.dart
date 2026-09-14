/// # JSON
///
/// The format codec, spelled exactly like [YamlFormat] and [TomlFormat]:
/// `parse`, `read`, `format`. A format is knowledge from outside Dart — Rule
/// 1's definition of a subject is the format or the binary — which is the same
/// argument that admitted archives, and it puts all the configuration
/// formats in one family rather than JSON in one place and the others in
/// another.
///
/// The [Json] *cursor* the readers return is exported from `util`, because it
/// is a pure value that `net` hands back too, through [DocumentFormat], and a type
/// `net` needs cannot live under `format`.
/// {@category Formats}
library;

import '../src/jsontext.dart';
import '../src/format.dart';
import '../src/json.dart';
import 'format.dart';

// ============================================================================
// JSON (format.json.*)
// ============================================================================

/// Entry point for JSON, reachable as [parseJson].
///
/// ```dart
/// final doc = res.body.parse(.json);
/// final cfg = await Path('config.json').read(.json);
/// Path('out.json').sync.writeText(const JsonFormat().format(doc.raw));
/// ```
///
/// `Path(path).write(value, as: .json)` writes one to disk, staged through a
/// `.part` file like every other write in this library; [writeJson] is the same
/// call under the shorter name a script reaches for. [format] is the string
/// half, for when the text is going somewhere that is not a file.
class JsonFormat implements DocumentFormat<Json, Object?> {
  /// Creates the codec. Prefer the shared [DocumentFormat.json] instance.
  const JsonFormat();

  /// Decodes [text] into a [Json] cursor.
  ///
  /// Text that is not JSON gives the empty cursor rather than throwing,
  /// matching how a missing path reads: a reader asked for a document and the
  /// honest answer is that there is not one.
  @override
  Json parse(String text) => Json(JsonText.decode(text));

  /// Encodes [value] as JSON text, indented by [indent] spaces.
  ///
  /// Pass `indent: 0` for the compact single-line form.
  ///
  /// `Path(path).write(value, as: .json)` is this plus an atomic write, and
  /// [writeJson] is that under a shorter name.
  @override
  String format(Object? value, {int indent = 2}) =>
      JsonText.encode(value, indent: indent);
}

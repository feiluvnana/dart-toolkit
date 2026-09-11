/// # JSON (`format.json.*`)
///
/// The format codec, spelled exactly like [YamlAccessor] and [TomlAccessor]:
/// `parse`, `read`, `format`. A format is knowledge from outside Dart — Rule
/// 1's definition of a subject is the format or the binary — which is the same
/// argument that admitted `format.zip`, and it puts all the configuration
/// formats in one family rather than JSON in one place and the others in
/// another.
///
/// The [Json] *cursor* the readers return is exported from `util`, because it
/// is a pure value that `net` hands back too, through [Codec], and a type
/// `net` needs cannot live under `format`.
library;

import '../src/jsontext.dart';
import '../src/codec.dart';
import '../src/json.dart';
import 'format.dart';

// ============================================================================
// JSON (format.json.*)
// ============================================================================

/// Entry point for JSON, reachable as `format.json`.
///
/// ```dart
/// final doc = format.json.parse(res.body);
/// final cfg = await format.json.read('config.json');
/// io.write('out.json', format.json.format(doc.raw));
/// ```
///
/// Writing a document straight to disk is `io.dump`, which stages through a
/// `.part` file like every other write in this library; [format] is the string
/// half, for when the text is going somewhere that is not a file.
class JsonAccessor with FileCodec<Json> implements Codec<Json> {
  /// Creates the accessor. Prefer the shared `format.json` instance.
  const JsonAccessor();

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
  String format(Object? value, {int indent = 2}) =>
      JsonText.encode(value, indent: indent);
}

import 'dom.dart';
import 'parser.dart';

export 'dom.dart' show Doc, Element, Node, TextNode;
export 'selector.dart' show selectorMatches;

/// Parse HTML into a queryable [Doc].
///
/// ```dart
/// final doc = Html.parse('<h1>Hello</h1>');
/// doc.find('h1')?.text;       // 'Hello'
/// doc.all('a.btn').length;    // every matching anchor
/// ```
abstract final class Html {
  /// Parses [source] into a document tree.
  static Doc parse(String source) => parseHtml(source);

  /// Escapes [text] for safe HTML output.
  static String escape(String text) => escapeHtml(text);

  /// Decodes HTML character references in [text].
  static String decode(String text) => decodeEntities(text);
}

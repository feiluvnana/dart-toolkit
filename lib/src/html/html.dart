import '../core/pipe.dart';
import '../core/traits.dart';
import 'dom.dart';

export 'dom.dart' show Doc, Element, Node, Text;

/// Parse HTML into a queryable [Doc].
///
/// ```dart
/// final doc = Html.parse('<h1>Hello</h1>');
/// doc.find('h1')?.text;       // 'Hello'
/// doc.all('a.btn').length;    // every matching anchor
/// ```
abstract final class Html {
  /// Parses [text] into a document tree.
  ///
  /// A fragment without `<html>` is wrapped in an implied
  /// `html > head + body`, so `find('body')` works on text-only pages.
  static Doc parse(String text) => parseHtml(text);

  /// Escapes [text] for safe HTML output.
  static String escape(String text) => escapeHtml(text);
}

/// `File('a.html').html()`, `Http.get(u).html()`.
extension SourceHtml on Source {
  /// The body parsed as HTML.
  Future<Doc> html() async => Html.parse(await text());
}

import '../core/decoding.dart';
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
  /// [url] is where it came from: [Element.link] resolves against it.
  static Doc parse(String text, {String? url}) => parseHtml(text, url: url);

  /// Escapes [text] for safe HTML output.
  static String escape(String text) => escapeHtml(text);
}

/// `File('a.html').html()`, `Http.get(u).html()`.
extension SourceHtml on Source {
  /// The body parsed as HTML, its [Doc.url] the source's: a response's final URL, a
  /// page's, a file's.
  Future<Doc> html() async {
    final body = await text();
    final file = switch (this) {
      Located(:final path) => Uri.base.resolveUri(Uri.file(path)).toString(),
      _ => null,
    };
    return Html.parse(body, url: sourceUrls[this]?.call() ?? file);
  }
}

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

export 'package:html/dom.dart' show Document, Element;

/// A parsed HTML document with standard CSS (selectAll) and XPath selector support.
class HtmlDocument {
  /// The underlying parsed DOM document.
  final dom.Document document;

  /// Creates an [HtmlDocument] wrapping an existing [document].
  HtmlDocument(this.document);

  /// Parses [text] as HTML.
  factory HtmlDocument.parse(String text) => HtmlDocument(html_parser.parse(text));

  /// Finds all matching elements by CSS [selector] (selectAll).
  List<dom.Element> $(String selector) => document.querySelectorAll(selector);

  /// XPath selector query.
  List<dom.Element> $xpath(String query) {
    try {
      final result = HtmlXPath.node(document).query(query);
      return result.nodes.map((n) => n.node).whereType<dom.Element>().toList();
    } catch (_) {
      return const [];
    }
  }
}

/// Convenience DOM query extensions on [dom.Element].
extension ElementQueryExtensions on dom.Element {
  /// Finds all matching descendants by CSS [selector] (selectAll).
  List<dom.Element> $(String selector) => querySelectorAll(selector);

  /// XPath selector query scoped to this element.
  List<dom.Element> $xpath(String query) {
    try {
      final result = HtmlXPath.node(this).query(query);
      return result.nodes.map((n) => n.node).whereType<dom.Element>().toList();
    } catch (_) {
      return const [];
    }
  }

  /// Attribute [name] on this element, or `null`.
  String? attr(String name) => attributes[name];

  /// Text lines split by `<br>` or newlines with HTML tags stripped.
  List<String> get lines => innerHtml
      .split(RegExp(r'<br\s*/?>|\r?\n'))
      .map((s) => s.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'&nbsp;'), ' ').trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'src/markup.dart';

/// A parsed HTML document with CSS and XPath selector support.
class HtmlDocument {
  /// The underlying parsed DOM document.
  final dom.Document document;

  /// Creates an [HtmlDocument] wrapping an existing [document].
  HtmlDocument(this.document);

  /// Parses [text] as HTML.
  factory HtmlDocument.parse(String text) => HtmlDocument(html_parser.parse(text));

  /// CSS selector query.
  Markup $(String selector) => Markup.of(document).$(selector);

  /// Returns all matching elements as a list of scoped [Markup] cursors.
  List<Markup> $$(String selector) => Markup.of(document).$$(selector);

  /// XPath selector query.
  Markup $xpath(String query) => Markup.of(document).$xpath(query);
}

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

export 'package:html/dom.dart' show Element;

/// A parsed HTML document with CSS selector support.
///
/// {@category Formats}
class HtmlDocument {
  /// The underlying parsed DOM document.
  final dom.Document document;

  /// Creates an [HtmlDocument] wrapping an existing [document].
  HtmlDocument(this.document);

  /// Parses [text] as HTML.
  factory HtmlDocument.parse(String text) => HtmlDocument(html_parser.parse(text));

  /// Finds all elements matching CSS [selector].
  List<dom.Element> $(String selector) => document.querySelectorAll(selector);
}

final _lineBreaks = RegExp(r'<br\s*/?>|\r?\n');
final _tags = RegExp('<[^>]*>');

/// Query extensions on [dom.Element].
///
/// {@category Formats}
extension ElementExtensions on dom.Element {
  /// Finds all descendants matching CSS [selector].
  List<dom.Element> $(String selector) => querySelectorAll(selector);

  /// Attribute [name] on this element, or `null`.
  String? attr(String name) => attributes[name];

  /// Text lines split by `<br>` or newlines with HTML tags stripped.
  List<String> get lines => innerHtml
      .split(_lineBreaks)
      .map((s) => s.replaceAll(_tags, '').replaceAll('&nbsp;', ' ').trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

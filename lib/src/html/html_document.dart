import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../http/fetch.dart';
import '../http/response.dart';

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

/// Query extensions on [dom.Element].
///
/// {@category Formats}
extension ElementExtensions on dom.Element {
  /// Finds all descendants matching CSS [selector].
  List<dom.Element> $(String selector) => querySelectorAll(selector);

  /// Attribute [name] on this element, or `null`.
  String? attr(String name) => attributes[name];

  /// Text lines split at `<br>` and newlines, entities decoded, tags dropped, blanks removed.
  ///
  /// Walks the parsed nodes; it does not re-serialise the subtree.
  List<String> get lines {
    final out = <String>[];
    final current = StringBuffer();

    void flush() {
      final line = current.toString().replaceAll(' ', ' ').trim();
      if (line.isNotEmpty) out.add(line);
      current.clear();
    }

    void walk(dom.Node node) {
      for (final child in node.nodes) {
        if (child is dom.Element) {
          child.localName == 'br' ? flush() : walk(child);
        } else if (child is dom.Text) {
          final parts = child.data.split('\n');
          for (var i = 0; i < parts.length; i++) {
            if (i > 0) flush();
            current.write(parts[i]);
          }
        }
      }
    }

    walk(this);
    flush();
    return out;
  }
}

final Expando<HtmlDocument> _htmlMemo = Expando<HtmlDocument>('htmlMemo');

/// HTML parsing on [http.Response].
///
/// {@category Formats}
extension ResponseHtmlExtensions on http.Response {
  /// Parses the response body as HTML (memoized per response instance).
  HtmlDocument html() => _htmlMemo[this] ??= HtmlDocument.parse(text);
}

/// HTML fetching on [Uri].
///
/// {@category Formats}
extension UriHtmlExtensions on Uri {
  /// Fetches this URI and parses the response body as HTML.
  ///
  /// Throws [HttpException] unless the status is 2xx — an error page parses fine and
  /// then matches nothing. Use `get` with `ok` to handle it yourself.
  Future<HtmlDocument> html({Map<String, String>? headers, http.Client? client}) async =>
      (await fetchOk(this, headers, client)).html();
}

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import '../http/http.dart';
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
/// final file = await Html.read('index.html');
/// final live = await Html.parse(await Http.get(url).text());
/// ```
abstract final class Html {
  /// Parses [source] (a `String` or UTF-8 bytes) into a document tree.
  ///
  /// A fragment without `<html>` is wrapped in an implied
  /// `html > head + body`, so `find('body')` works on text-only pages.
  static Doc parse(Object source) {
    if (source is String) return parseHtml(source);
    if (source is Uint8List) return parseHtml(utf8.decode(source, allowMalformed: true));
    if (source is List<int>) return parseHtml(utf8.decode(source, allowMalformed: true));
    throw ArgumentError.value(source, 'source', 'Must be a String or UTF-8 bytes');
  }

  /// Reads the file at [path] and parses it (mirror of `Json.read`).
  static Future<Doc> read(Object path) async {
    final file = path is String ? path : path.toString();
    return parse(await io.File(file).readAsString());
  }

  /// Escapes [text] for safe HTML output.
  static String escape(String text) => escapeHtml(text);

  /// Decodes HTML character references in [text].
  static String decode(String text) => decodeEntities(text);
}

/// A streaming HTTP response read as HTML: `Html.parse(await resp.text())`,
/// strict (a non-2xx throws a [StatusException]).
extension RespHtml on Resp {
  /// The body parsed as HTML.
  Future<Doc> html({Duration? timeout}) async => Html.parse(await text(timeout: timeout));
}

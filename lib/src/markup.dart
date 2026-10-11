/// The markup tree `xml.dart` and `xpath.dart` share: [Element] and the other
/// nodes, [Selection], [Markup], CSS `$` queries, and [Xml] with its parser. XPath is a
/// library of its own, reaching the tree through [MarkupInternals].
library;

import 'dart:collection';
import 'dart:typed_data';

import 'core/errors.dart';

part 'formats/markup/dom.dart';
part 'formats/markup/internals.dart';
part 'formats/markup/scan.dart';
part 'formats/markup/selector.dart';
part 'formats/queries.dart';
part 'formats/xml/parser.dart';
part 'formats/xml/xml.dart';

/// [make]'s result for [key], cached among the last 256: the CSS and XPath
/// caches, bounded for programs that build queries from data.
V compiled<K, V>(Map<K, V> cache, K key, V Function() make) {
  final hit = cache[key];
  if (hit != null) return hit;
  if (cache.length >= 256) cache.remove(cache.keys.first);
  return cache[key] = make();
}

/// [parse] of [text], whose [FormatException] names [format], [where] (a file or a URL)
/// when there is one: `Invalid XML in a.xml: …`, `Invalid XML: …`.
T parsedText<T>(String format, String? where, String text, T Function(String text) parse) {
  try {
    return _parsed(format, where ?? '', text, parse);
  } on FormatException catch (e) {
    final prefix = 'Invalid $format in ${where ?? ''}: ';
    if (!e.message.startsWith(prefix)) rethrow;
    final (source, offset) = (e.source, e.offset);
    final line = source is String && offset != null
        ? '\n'.allMatches(source.substring(0, offset < source.length ? offset : source.length)).length + 1
        : null;
    final head = 'Invalid $format${where == null ? '' : ' in $where'}${line == null ? '' : ', line $line'}';
    Error.throwWithStackTrace(
      FormatException('$head: ${e.message.substring(prefix.length)}', source, offset),
      StackTrace.current,
    );
  }
}

/// [text] parsed by [parse]; what it cannot parse is a [FormatException]
/// naming [format] and [path].
T _parsed<T>(String format, String path, String text, T Function(String text) parse) {
  try {
    return parse(text);
  } on FormatException catch (e) {
    var message = e.message;
    var offset = e.offset;
    if (message.startsWith('$format: ')) {
      message = message.substring(format.length + 2);
    }
    Error.throwWithStackTrace(
      FormatException('Invalid $format in $path: $message', e.source is String ? e.source : text, offset),
      StackTrace.current,
    );
  }
}

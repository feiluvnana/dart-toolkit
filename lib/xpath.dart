/// # XPath
///
/// XPath 1.0 `$x` on an [Element], a [Selection] and a document ([Markup]: an `Html` or an
/// `Xml`), and the checked [XPath] text. Import it beside `html.dart` or `xml.dart`.
library;

import 'src/markup.dart' hide compiled, parsedText;

export 'src/foundations.dart';
export 'src/markup.dart' show Attribute, Element, Markup, Node, Selection, Syntax, Text;

part 'src/formats/xpath.dart';

/// [make]'s result for [key], cached among the last 256: xpath's own copy of
/// the markup cache helper (the shared one is hidden from this library's
/// `import`, which the `part` file above also reads through).
V _compiled<K, V>(Map<K, V> cache, K key, V Function() make) {
  final hit = cache[key];
  if (hit != null) return hit;
  if (cache.length >= 256) cache.remove(cache.keys.first);
  return cache[key] = make();
}

/// # XPath
///
/// XPath 1.0 `$x` on an [Element], a [Selection] and a document ([Markup]: an `Html` or an
/// `Xml`), and the checked [XPath] text. Import it beside `html.dart` or `xml.dart`.
///
/// {@category Formats}
library;

import 'src/collection/formats_bridge.dart';
import 'src/markup.dart';

export 'src/foundations.dart';
export 'src/markup.dart' show Attribute, Element, Markup, Node, Selection, Syntax, Text;

part 'src/formats/xpath.dart';

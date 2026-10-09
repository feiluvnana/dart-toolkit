/// # HTML
///
/// [Html] and the tree it shares with `xml.dart` ([Element], [Node], [Text], [Attribute],
/// [Selection]), CSS `$` and XPath `$x` queries, and HTML entities.
///
/// {@category Formats}
library;

export 'collection.dart';
export 'core.dart';

export 'src/markup.dart' hide MarkupInternals, Xml, XmlResponse, XmlResponseFuture, XmlString;

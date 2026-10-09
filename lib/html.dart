/// # HTML
///
/// [Html], parsed as a browser parses it, and the tree it shares with `xml.dart` ([Element],
/// [Node], [Text], [Attribute], [Selection], [Markup]) with CSS `$` queries. XPath `$x` comes
/// with `xpath.dart`.
///
/// {@category Formats}
library;

export 'src/foundations.dart';

export 'src/html.dart' hide HtmlInternals;
export 'src/markup.dart' hide MarkupInternals, Names, TextRun, Xml, XmlResponse, XmlResponseFuture, XmlString;

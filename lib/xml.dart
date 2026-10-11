/// # XML
///
/// [Xml] and the tree it shares with `html.dart` ([Element], [Node], [Text], [Attribute],
/// [Selection], [Markup]) with CSS `$` queries. XPath `$x` comes with `xpath.dart`.
library;

export 'src/foundations.dart';

export 'src/markup.dart' hide MarkupInternals, Names, TextRun, compiled, parsedText;

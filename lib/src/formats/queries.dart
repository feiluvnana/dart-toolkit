part of '../markup.dart';

/// A CSS selector, checked when made: what `$(…)` takes. It is a [String], so it goes wherever
/// a selector's text does, and is compiled once.
///
/// ```dart
/// const titles = 'h2 a';                 // checked at the first `$`
/// final links  = 'a[href\$=".zip"]'.css;  // checked here
/// page.$(links).links;
/// ```
///
/// {@category Formats}
extension type const Css._(String _text) implements String {
  /// [text] as a selector; one that does not parse is a [FormatException] naming where.
  Css(String text) : _text = text {
    _Selector.parse(text);
  }
}

/// An XPath 1.0 location path or expression, checked when made: what `$x(…)` takes. It is a
/// [String], so it goes wherever an XPath's text does, and is compiled once.
///
/// ```dart
/// final hrefs = '//a/@href'.xpath;
/// page.$x(hrefs).links;
/// ```
///
/// {@category Formats}
extension type const XPath._(String _text) implements String {
  /// [text] as an XPath; one that does not parse is a [FormatException] naming where.
  XPath(String text) : _text = text {
    _XPath.parse(text);
  }
}

/// Text read as a query.
///
/// {@category Formats}
extension StringQueryExtensions on String {
  /// This text as a CSS selector: `'h2 a'.css`. One that does not parse is a [FormatException].
  Css get css => Css(this);

  /// This text as an XPath: `'//a/@href'.xpath`. One that does not parse is a [FormatException].
  XPath get xpath => XPath(this);
}

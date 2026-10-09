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

/// Text read as a CSS selector.
///
/// {@category Formats}
extension StringCssExtensions on String {
  /// This text as a CSS selector: `'h2 a'.css`. One that does not parse is a [FormatException].
  Css get css => Css(this);
}

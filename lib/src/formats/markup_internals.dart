part of '../markup.dart';

/// What `scrape.dart` needs from the tree. Hidden from `html.dart` and `xml.dart`.
abstract final class MarkupInternals {
  /// [res]'s HTML if something has parsed it already, else `null`.
  static Html? parsed(Response res) => _responseHtml[res];
}

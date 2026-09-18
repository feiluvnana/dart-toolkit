/// Common string convenience extensions.
///
/// {@category Formats}
extension StringExtensions on String {
  /// Parses this string as a [Uri].
  Uri get url => Uri.parse(this);

  /// Extracts the first match of [pattern] at [group], or `null`.
  ///
  /// Evaluates [pattern] using standard Dart `Pattern` semantics without coercing non-RegExp strings into regex.
  String? match(Pattern pattern, [int group = 0]) => switch (pattern.allMatches(this).firstOrNull) {
    null => null,
    final m => group <= m.groupCount ? m.group(group) : null,
  };
}

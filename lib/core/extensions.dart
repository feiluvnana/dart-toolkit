/// Common string convenience extensions.
///
/// {@category Utilities}
extension StringCoreExtensions on String {
  /// Parses this string as a [Uri].
  Uri get url => Uri.parse(this);

  /// Extracts the first match of [pattern] at [group], or `null`.
  ///
  /// Evaluates [pattern] using standard Dart `Pattern` semantics without coercing non-RegExp strings into regex.
  String? match(Pattern pattern, [int group = 0]) {
    final matches = pattern.allMatches(this);
    if (matches.isEmpty) return null;
    final m = matches.first;
    return (m is RegExpMatch) ? (group <= m.groupCount ? m.group(group) : null) : (group == 0 ? m.group(0) : null);
  }
}

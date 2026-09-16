/// Common string convenience extensions.
extension StringCoreExtensions on String {
  /// Parses this string as a [Uri].
  Uri get url => Uri.parse(this);

  /// Extracts the first match of [pattern] at [group], or `null`.
  String? match(Pattern pattern, [int group = 0]) {
    final match = pattern.allMatches(this).firstOrNull;
    return match?.group(group);
  }
}

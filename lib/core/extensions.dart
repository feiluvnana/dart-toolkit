/// Common string convenience extensions.
extension StringCoreExtensions on String {
  /// Parses this string as a [Uri].
  Uri get url => Uri.parse(this);

  /// Extracts the first match of [pattern] at [group], or `null`.
  String? match(Pattern pattern, [int group = 0]) {
    final regExp = pattern is RegExp ? pattern : RegExp(pattern.toString());
    return regExp.firstMatch(this)?.group(group);
  }
}

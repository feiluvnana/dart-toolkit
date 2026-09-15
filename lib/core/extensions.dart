import 'dart:core';
import 'dart:core' as core;

/// Common string convenience extensions.
extension StringCoreExtensions on String {
  /// Parses this string as a [Uri].
  Uri get url => Uri.parse(this);

  /// Extracts the first match of [pattern] at [group], or `null`.
  String? match(Pattern pattern, [core.int group = 0]) {
    final regExp = pattern is RegExp ? pattern : RegExp(pattern.toString());
    return regExp.firstMatch(this)?.group(group);
  }

  /// Extracts digits only from this string.
  String get digits => replaceAll(RegExp(r'\D'), '');

  /// Parses this string as an integer, or `null`.
  core.int? get int => core.int.tryParse(this);
}

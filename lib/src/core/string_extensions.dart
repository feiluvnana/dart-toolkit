part of '../../core.dart';

/// String helpers.
///
/// {@category Formats}
extension StringExtensions on String {
  /// Parses this string as a [Uri].
  Uri get url => Uri.parse(this);

  /// Group [group] of the first match of [pattern], or `null`. A `String` pattern matches literally.
  String? match(Pattern pattern, [int group = 0]) => switch (pattern.allMatches(this).firstOrNull) {
    null => null,
    final m => group <= m.groupCount ? m.group(group) : null,
  };
}

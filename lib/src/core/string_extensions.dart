part of '../../core.dart';

final _whitespaceRegExp = RegExp(r'\s+');
final _linesRegExp = RegExp(r'\r?\n');

/// String helpers.
///
/// {@category Utilities}
extension StringExtensions on String {
  /// Parses this string as a [Uri].
  Uri get url => Uri.parse(this);

  /// Group [group] of the first match of [pattern], or `null`. A `String` pattern matches literally.
  String? match(Pattern pattern, [int group = 0]) => switch (pattern.allMatches(this).firstOrNull) {
    null => null,
    final m => group <= m.groupCount ? m.group(group) : null,
  };

  /// The substring after the first occurrence of [delimiter], or [or] (`''` by default) if not found.
  String after(Pattern delimiter, {String? or}) {
    final m = delimiter.allMatches(this).firstOrNull;
    return m == null ? (or ?? '') : substring(m.end);
  }

  /// The substring after the last occurrence of [delimiter], or [or] (`''` by default) if not found.
  String afterLast(Pattern delimiter, {String? or}) {
    final m = delimiter.allMatches(this).lastOrNull;
    return m == null ? (or ?? '') : substring(m.end);
  }

  /// The substring before the first occurrence of [delimiter], or [or] (`''` by default) if not found.
  String before(Pattern delimiter, {String? or}) {
    final m = delimiter.allMatches(this).firstOrNull;
    return m == null ? (or ?? '') : substring(0, m.start);
  }

  /// The substring before the last occurrence of [delimiter], or [or] (`''` by default) if not found.
  String beforeLast(Pattern delimiter, {String? or}) {
    final m = delimiter.allMatches(this).lastOrNull;
    return m == null ? (or ?? '') : substring(0, m.start);
  }

  /// The substring between the first occurrence of [start] and the subsequent occurrence of [end],
  /// or [or] (`''` by default) if either is not found.
  String between(Pattern start, Pattern end, {String? or}) {
    final s = start.allMatches(this).firstOrNull;
    if (s == null) return or ?? '';
    final e = end.allMatches(this, s.end).firstOrNull;
    if (e == null) return or ?? '';
    return substring(s.end, e.start);
  }

  /// Removes all occurrences of [pattern] (shorthand for `replaceAll(pattern, '')`).
  String remove(Pattern pattern) => replaceAll(pattern, '');

  /// Removes all occurrences of each pattern in [patterns].
  String removeAll(Iterable<Pattern> patterns) {
    var result = this;
    for (final p in patterns) {
      result = result.replaceAll(p, '');
    }
    return result;
  }

  /// If this string starts with [prefix], returns it without the prefix; otherwise returns this.
  String removePrefix(Pattern prefix) {
    final m = prefix.allMatches(this).firstOrNull;
    return (m != null && m.start == 0) ? substring(m.end) : this;
  }

  /// If this string ends with [suffix], returns it without the suffix; otherwise returns this.
  String removeSuffix(Pattern suffix) {
    final m = suffix.allMatches(this).lastOrNull;
    return (m != null && m.end == length) ? substring(0, m.start) : this;
  }

  /// Strips matching surrounding quotes from [quotes] (default `'` and `"`, or ``` ` ```).
  String unquote([String quotes = "'\"`"]) {
    if (length < 2) return this;
    final first = this[0];
    final last = this[length - 1];
    if (first == last && quotes.contains(first)) {
      return substring(1, length - 1);
    }
    return this;
  }

  /// Replaces every run of whitespace characters with a single space, and trims both ends.
  String collapseWhitespace() => trim().replaceAll(_whitespaceRegExp, ' ');

  /// Splits this string into lines (by `\n` or `\r\n`).
  List<String> get lines => split(_linesRegExp);

  /// Splits this string by whitespace into non-empty words.
  List<String> get words => trim().split(_whitespaceRegExp).where((w) => w.isNotEmpty).toList();

  /// Whether this string contains any of [patterns].
  bool containsAny(Iterable<Pattern> patterns) {
    for (final p in patterns) {
      if (contains(p)) return true;
    }
    return false;
  }

  /// Whether this string contains all of [patterns].
  bool containsAll(Iterable<Pattern> patterns) {
    for (final p in patterns) {
      if (!contains(p)) return false;
    }
    return true;
  }
}

/// Helpers on collections of strings.
///
/// {@category Utilities}
extension StringIterableExtensions on Iterable<String> {
  /// Each string trimmed: `map((s) => s.trim())`.
  Iterable<String> get trimmed => map((s) => s.trim());

  /// Each non-empty string: `where((s) => s.isNotEmpty)`.
  Iterable<String> get nonEmpty => where((s) => s.isNotEmpty);

  /// Each string trimmed and non-empty: `map((s) => s.trim()).where((s) => s.isNotEmpty)`.
  Iterable<String> get cleaned => map((s) => s.trim()).where((s) => s.isNotEmpty);

  /// Each string with its whitespace collapsed: `map((s) => s.collapseWhitespace()).where((s) => s.isNotEmpty)`.
  Iterable<String> get collapsed => map((s) => s.collapseWhitespace()).where((s) => s.isNotEmpty);

  /// Only strings that contain [pattern].
  Iterable<String> matching(Pattern pattern) => where((s) => s.contains(pattern));

  /// Only strings that do not contain [pattern].
  Iterable<String> without(Pattern pattern) => where((s) => !s.contains(pattern));

  /// Each string with [pattern] removed.
  Iterable<String> remove(Pattern pattern) => map((s) => s.remove(pattern));

  /// Each string unquoted if wrapped in matching quotes.
  Iterable<String> unquoted([String quotes = "'\"`"]) => map((s) => s.unquote(quotes));
}

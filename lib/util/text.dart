/// # Text (`util.text.*`)
///
/// The string handling a scraper actually needs: turning a heading into a
/// filename, collapsing the whitespace a page is full of, pulling a number out
/// of `'$1,234.50'`, and stripping tags off a fragment.
library;

// ============================================================================
// TEXT (util.text.*)
// ============================================================================

/// Entry point for string helpers, reachable as `util.text`.
///
/// ```dart
/// util.text.slug('Hello, World!');     // 'hello-world'
/// util.text.clean('  a   b  ');        // 'a b'
/// util.text.number(r'$1,234.50');      // 1234.5
/// ```
class TextAccessor {
  /// Creates the accessor. Prefer the shared `util.text` instance.
  const TextAccessor();

  static final _tags = RegExp(r'<[^>]*>');
  static final _spaces = RegExp(r'\s+');
  static final _invisible = RegExp(r'[​-‍﻿­]');
  static final _notSlug = RegExp(r'[^a-z0-9]+');
  static final _edges = RegExp(r'^-+|-+$');
  static final _digits = RegExp(r'-?\d[\d,_ ]*(?:\.\d+)?');
  static final _wordish = RegExp(r"[\w']+");

  /// A lowercase, hyphenated form of [text], safe in a URL or a filename.
  ///
  /// Accented Latin letters fold to their plain form; everything else that is
  /// not a letter or digit becomes a single hyphen.
  String slug(String text, {String separator = '-'}) {
    final folded = fold(text).toLowerCase();
    final hyphenated = folded.replaceAll(_notSlug, '-').replaceAll(_edges, '');
    return separator == '-'
        ? hyphenated
        : hyphenated.replaceAll('-', separator);
  }

  /// [text] with accented Latin letters replaced by their plain form.
  String fold(String text) {
    const from =
        'àáâãäåāăąçćĉċčèéêëēĕėęěìíîïĩīĭįıñńņňòóôõöøōŏőùúûüũūŭůűų'
        'ýÿŷñšśŝşžźżđłþðæœ';
    const to =
        'aaaaaaaaacccccceeeeeeeeeiiiiiiiiinnnnooooooooouuuuuuuuuu'
        'yyynsssszzzdlpdao';
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final index = from.indexOf(ch.toLowerCase());
      buffer.write(index == -1 ? ch : to[index]);
    }
    return buffer.toString();
  }

  /// [text] with runs of whitespace collapsed to one space, trimmed.
  ///
  /// Also drops zero-width and soft-hyphen characters, which scraped markup is
  /// full of and which break equality checks in surprising ways.
  String clean(String text) =>
      text.replaceAll(_invisible, '').replaceAll(_spaces, ' ').trim();

  /// [text] with any HTML tags removed and its whitespace cleaned.
  String strip(String text) => clean(text.replaceAll(_tags, ' '));

  /// [text] shortened to at most [length] characters, ending with [ellipsis].
  ///
  /// Returns [text] unchanged when it already fits.
  String clip(String text, int length, {String ellipsis = '…'}) {
    if (length <= 0) return '';
    if (text.length <= length) return text;
    final room = length - ellipsis.length;
    if (room <= 0) return ellipsis.substring(0, length);
    return '${text.substring(0, room).trimRight()}$ellipsis';
  }

  /// The first number in [text], ignoring currency symbols and separators.
  ///
  /// Returns `null` when there is no number. Commas, underscores and spaces
  /// inside the digits are treated as grouping and dropped.
  num? number(String text) {
    final match = _digits.firstMatch(text);
    if (match == null) return null;
    final digits = match.group(0)!.replaceAll(RegExp(r'[,_ ]'), '');
    return num.tryParse(digits);
  }

  /// Every number in [text], in order.
  List<num> numbers(String text) => [
    for (final match in _digits.allMatches(text))
      if (num.tryParse(match.group(0)!.replaceAll(RegExp(r'[,_ ]'), ''))
          case final value?)
        value,
  ];

  /// [text] with the first letter of each word capitalised.
  String title(String text) => text.replaceAllMapped(
    _wordish,
    (m) =>
        m.group(0)!.substring(0, 1).toUpperCase() +
        m.group(0)!.substring(1).toLowerCase(),
  );

  /// [text] with its first letter capitalised and the rest untouched.
  String upper(String text) =>
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

  /// The words in [text].
  List<String> words(String text) =>
      _wordish.allMatches(text).map((m) => m.group(0)!).toList();

  /// Whether [text] holds nothing but whitespace, or is empty.
  bool blank(String text) => text.trim().isEmpty;

  /// [text] between [start] and [end], or `null` when either is missing.
  ///
  /// The quickest way to pull a value out of markup no selector reaches, such
  /// as a string embedded in a `<script>` block.
  ///
  /// ```dart
  /// util.text.between(body, '"videoId":"', '"');
  /// ```
  String? between(String text, String start, String end) {
    final from = text.indexOf(start);
    if (from == -1) return null;
    final head = from + start.length;
    final to = text.indexOf(end, head);
    if (to == -1) return null;
    return text.substring(head, to);
  }

  /// Every occurrence of the text between [start] and [end].
  List<String> betweens(String text, String start, String end) {
    final results = <String>[];
    var cursor = 0;
    while (true) {
      final from = text.indexOf(start, cursor);
      if (from == -1) break;
      final head = from + start.length;
      final to = text.indexOf(end, head);
      if (to == -1) break;
      results.add(text.substring(head, to));
      cursor = to + end.length;
    }
    return results;
  }
}

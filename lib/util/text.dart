/// # Text (`util.text.*`)
///
/// The string handling a scraper actually needs: turning a heading into a
/// filename, collapsing the whitespace a page is full of, pulling a number out
/// of `'$1,234.50'`, stripping tags off a fragment — and, in the other
/// direction, filling a template ([TextAccessor.render]).
library;

import 'sequence.dart';

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
  // Letters and digits from any script survive: collapsing on [^a-z0-9] left
  // a CJK or Cyrillic title with an empty slug, and an empty filename with it.
  static final _notSlug = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
  static final _edges = RegExp(r'^-+|-+$');
  // A space only groups digits when it separates full groups of three, so
  // '1 234 567' reads as one number while '12 34' stays two. Treating any
  // space as grouping merged distinct numbers into one.
  static final _digits = RegExp(
    r'-?\d{1,3}(?:[ \u00A0\u202F]\d{3})+(?:\.\d+)?'
    r'|-?\d[\d,_]*(?:\.\d+)?',
  );
  static final _grouping = RegExp(r'[,_ \u00A0\u202F]');
  static final _wordish = RegExp(r"[\w']+");

  /// A lowercase, hyphenated form of [text], safe in a URL or a filename.
  ///
  /// Accented Latin letters fold to their plain form; letters and digits of
  /// other scripts are kept as they are, and everything else becomes a single
  /// hyphen.
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
    return '${_cut(text, room).trimRight()}$ellipsis';
  }

  /// The first [room] code units of [text], without splitting a character.
  ///
  /// Slicing a plain [String] can land between the two halves of a surrogate
  /// pair — an emoji cut down the middle renders as a replacement character —
  /// so the boundary is walked back to the start of the last whole rune.
  static String _cut(String text, int room) {
    var end = room;
    if (end > 0 && end < text.length) {
      final unit = text.codeUnitAt(end - 1);
      // A high surrogate here would have its pair sliced off.
      if (unit >= 0xD800 && unit <= 0xDBFF) end--;
    }
    return text.substring(0, end);
  }

  /// The first number in [text], ignoring currency symbols and separators.
  ///
  /// Returns `null` when there is no number. Commas and underscores inside the
  /// digits are grouping and dropped; a space counts as grouping only when it
  /// separates whole groups of three, so `'1 234'` is one number and
  /// `'12 34'` is two.
  num? number(String text) {
    final match = _digits.firstMatch(text);
    if (match == null) return null;
    final digits = match.group(0)!.replaceAll(_grouping, '');
    return num.tryParse(digits);
  }

  /// Every number in [text], in order.
  Sequence<num> numbers(String text) => Sequence([
    for (final match in _digits.allMatches(text))
      if (num.tryParse(match.group(0)!.replaceAll(_grouping, ''))
          case final value?)
        value,
  ]);

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
  Sequence<String> words(String text) =>
      _wordish.allMatches(text).map((m) => m.group(0)!).seq;

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

  static final _slots = RegExp(r'\{(\w+)\}');

  /// [template] with every `{key}` replaced by [values].
  ///
  /// The only member here that *produces* text: scripts generate it constantly
  /// — a commit message, a PR body, an HTML index over what was just scraped,
  /// a config file for the next stage — and a template that came from a file
  /// is otherwise `replaceAll` in a loop.
  ///
  /// ```dart
  /// util.text.render('Hello {name}, {count} new', {'name': 'x', 'count': 3});
  /// // 'Hello x, 3 new'
  ///
  /// util.text.render(io.read('template.md'), vars);
  /// ```
  ///
  /// A missing key renders empty — the same contract `Slot.read`, `Field.text`
  /// and `Json.text` keep, now four deep.
  ///
  /// **Deliberately dumb.** `{key}` substitution and nothing else: no
  /// conditionals, no loops, no filters, no partials. Each of those is one step
  /// towards a template engine, and the moment a script needs a template engine
  /// it should have one rather than this.
  String render(String template, Map<String, Object?> values) => template
      .replaceAllMapped(_slots, (m) => values[m.group(1)]?.toString() ?? '');

  /// Every occurrence of the text between [start] and [end].
  Sequence<String> betweens(String text, String start, String end) {
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
    return Sequence(results);
  }
}

/// # Text (`util.text.*`)
///
/// The string handling a scraper actually needs: turning a heading into a
/// filename, collapsing the whitespace a page is full of, pulling a number out
/// of `'$1,234.50'`, stripping tags off a fragment — and, in the other
/// direction, filling a template ([TextAccessor.render]).
library;

import 'dart:convert' as convert;

// ============================================================================
// TEXT (util.text.*)
// ============================================================================

const TextAccessor _textInstance = TextAccessor();

/// A lowercase, hyphenated form of [text], safe in a URL or filename.
String slugify(String text, {String separator = '-'}) =>
    _textInstance.slug(text, separator: separator);

/// Collapses runs of whitespace in [text] to one space and trims it.
String cleanText(String text) => _textInstance.clean(text);

/// Removes HTML tags from [text] and collapses whitespace.
String stripHtmlTags(String text) => _textInstance.tags(text);

/// Shortens [text] to at most [length] characters, ending with [ellipsis].
String clipText(String text, int length, {String ellipsis = '…'}) =>
    _textInstance.clip(text, length, ellipsis: ellipsis);

/// Extracts the first decimal number in [text], ignoring symbols and grouping.
num? extractNumber(String text) => _textInstance.number(text);

/// Fluent string helpers for cleaning, slugs, extraction, and clipping.
extension StringToolkitExtensions on String {
  /// A lowercase, hyphenated form of this string, safe in URLs or filenames.
  String toSlug({String separator = '-'}) =>
      _textInstance.slug(this, separator: separator);

  /// Collapses runs of whitespace to a single space and trims edges.
  String cleanWhitespace() => _textInstance.clean(this);

  /// Extracts the first decimal number, ignoring currency symbols and grouping commas.
  num? extractNumber() => _textInstance.number(this);

  /// Shortens this string to at most [length] characters, ending with [ellipsis].
  String clip(int length, {String ellipsis = '…'}) =>
      _textInstance.clip(this, length, ellipsis: ellipsis);

  /// Removes HTML tags and collapses whitespace.
  String stripTags() => _textInstance.tags(this);
}

// ============================================================================
// STATIC HELPER HUB: Text
// ============================================================================

/// Static helper hub for string manipulation, cleaning, and extraction.
///
/// Easily discoverable via IDE auto-complete:
/// ```dart
/// final slug = Text.slug('Hello World!');     // 'hello-world'
/// final clean = Text.clean('  a   b  ');       // 'a b'
/// final num = Text.extractNumber(r'$1,234.50'); // 1234.5
/// final clip = Text.clip('Long text...', 10);
/// ```
abstract final class Text {
  Text._();

  /// A lowercase, hyphenated form of [text], safe in a URL or filename.
  static String slug(String text, {String separator = '-'}) =>
      _textInstance.slug(text, separator: separator);

  /// Collapses runs of whitespace in [text] to one space and trims it.
  static String clean(String text) => _textInstance.clean(text);

  /// Removes HTML tags from [text] and collapses whitespace.
  static String stripTags(String text) => _textInstance.tags(text);

  /// Shortens [text] to at most [length] characters, ending with [ellipsis].
  static String clip(String text, int length, {String ellipsis = '…'}) =>
      _textInstance.clip(text, length, ellipsis: ellipsis);

  /// Extracts the first decimal number in [text], ignoring symbols and grouping.
  static num? extractNumber(String text) => _textInstance.number(text);

  /// Extracts the first decimal number in [text], ignoring symbols and grouping.
  static num? number(String text) => _textInstance.number(text);

  /// Extracts all numbers in [text].
  static Iterable<num> numbers(String text) => _textInstance.numbers(text);

  /// Removes HTML tags from [text] and collapses whitespace.
  static String tags(String text) => _textInstance.tags(text);

  /// Replaces `{key}` placeholders in [template] with [values].
  static String render(String template, Map<String, Object?> values) =>
      _textInstance.render(template, values);

  /// Strips accents/diacritics from [text].
  static String fold(String text) => _textInstance.fold(text);

  /// Converts [text] to Title Case.
  static String title(String text) => _textInstance.title(text);

  /// Capitalizes the first letter of [text].
  static String upper(String text) => _textInstance.upper(text);

  /// Extracts words from [text].
  static Iterable<String> words(String text) => _textInstance.words(text);

  /// Returns true if [text] is empty or whitespace-only.
  static bool blank(String text) => _textInstance.blank(text);

  /// Extracts the first substring between [start] and [end].
  static String? between(String text, String start, String end) =>
      _textInstance.betweens(text, start, end).firstOrNull;

  /// Extracts all substrings between [start] and [end].
  static Iterable<String> betweens(String text, String start, String end) =>
      _textInstance.betweens(text, start, end);

  /// Encodes [input] as standard Base64 string.
  static String base64(Object input) => _textInstance.base64(input);

  /// Decodes a Base64 string into bytes.
  static List<int> unbase64(String input) => _textInstance.unbase64(input);
}

/// Entry point for string helpers, reachable as `util.text`.
///
/// ```dart
/// Text.slug('Hello, World!');     // 'hello-world'
/// Text.clean('  a   b  ');        // 'a b'
/// Text.number(r'$1,234.50');      // 1234.5
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
  // A separator only groups digits when it separates full groups of three, so
  // '1 234 567' reads as one number while '12 34' stays two. Treating any
  // space as grouping merged distinct numbers into one — and the same
  // reasoning had never been applied to the comma, which is how '1,2' read as
  // twelve.
  static const _magnitude =
      r'\d{1,3}(?:[,_ \u00A0\u202F]\d{3})+(?:\.\d+)?'
      r'|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?';
  // A parenthesised number is an accounting negative — '(1,234.50)' is
  // -1234.50, which is how a financial table writes it and which used to come
  // back positive.
  static final _digits = RegExp('\\((?:$_magnitude)\\)|-?(?:$_magnitude)');
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

  /// What [fold] replaces, keyed by the accented letter.
  ///
  /// A map rather than the two parallel string constants this used to be. Those
  /// were indexed against each other, so one extra `c` in the replacements —
  /// six of them for five `ç` variants — shifted every group after it by one
  /// and folded 14 letters to the previous group's letter: `è` to `c`, `ñ` to
  /// `i`, and `util.text.slug('Señor Muñoz')` to `'seior-muioz'`.
  ///
  /// A map cannot go out of step with itself, a duplicate key is a compile
  /// error rather than a silently unreachable entry — `ñ` was listed twice —
  /// and a replacement may be longer than one letter, which is what `ß`, `æ`
  /// and `œ` need and indexing a [String] could not express.
  static const _folds = <String, String>{
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
    'ă': 'a', 'ą': 'a',
    'ç': 'c', 'ć': 'c', 'ĉ': 'c', 'ċ': 'c', 'č': 'c',
    'đ': 'd', 'ď': 'd', 'ð': 'd',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ĕ': 'e', 'ė': 'e',
    'ę': 'e', 'ě': 'e',
    'ğ': 'g', 'ĝ': 'g', 'ġ': 'g', 'ģ': 'g',
    'ĥ': 'h', 'ħ': 'h',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ī': 'i', 'ĭ': 'i',
    'į': 'i', 'ı': 'i',
    'ĵ': 'j',
    'ķ': 'k',
    'ĺ': 'l', 'ļ': 'l', 'ľ': 'l', 'ł': 'l',
    'ñ': 'n', 'ń': 'n', 'ņ': 'n', 'ň': 'n',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
    'ŏ': 'o', 'ő': 'o',
    'ŕ': 'r', 'ŗ': 'r', 'ř': 'r',
    'ś': 's', 'ŝ': 's', 'ş': 's', 'š': 's',
    'ţ': 't', 'ť': 't', 'ŧ': 't',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ū': 'u', 'ŭ': 'u',
    'ů': 'u', 'ű': 'u', 'ų': 'u',
    'ŵ': 'w',
    'ý': 'y', 'ÿ': 'y', 'ŷ': 'y',
    'ź': 'z', 'ż': 'z', 'ž': 'z',
    // The ligatures and the sharp s, which are two letters where they are
    // spelled out and which is why this is a map of strings.
    'ß': 'ss', 'æ': 'ae', 'œ': 'oe', 'ĳ': 'ij', 'þ': 'th',
  };

  /// [_folds], keyed by code point, with the upper-case forms folded in.
  ///
  /// Built once. Walking [_folds] per character meant a `String.fromCharCode`
  /// and a `toLowerCase` allocation for every rune of every input, which is
  /// most of what [fold] used to cost.
  static final Map<int, String> _byRune = () {
    final map = <int, String>{};
    for (final entry in _folds.entries) {
      map[entry.key.runes.first] = entry.value;
      final upper = entry.key.toUpperCase();
      // 'ß'.toUpperCase() is 'SS' in Dart — two runes, and no upper-case
      // form to key on, so there is nothing to add for it.
      if (upper.runes.length == 1 && upper != entry.key) {
        map[upper.runes.first] = _titled(entry.value);
      }
    }
    return map;
  }();

  /// [text] with accented Latin letters replaced by their plain form.
  ///
  /// `ß`, `æ`, `œ`, `ĳ` and `þ` fold to the two letters they are spelled with;
  /// everything else folds to one. A letter no entry covers is left alone, so
  /// other scripts pass through untouched.
  String fold(String text) {
    // One pass, and no allocation at all when nothing folds — which is the
    // common case, since nothing here is ASCII and most scraped text is. The
    // runs between replacements are copied in bulk rather than a character at
    // a time.
    StringBuffer? buffer;
    var start = 0;
    var at = 0;
    for (final rune in text.runes) {
      final width = rune > 0xFFFF ? 2 : 1;
      final plain = rune > 0x7F ? _byRune[rune] : null;
      if (plain != null) {
        buffer ??= StringBuffer();
        buffer
          ..write(text.substring(start, at))
          ..write(plain);
        start = at + width;
      }
      at += width;
    }
    if (buffer == null) return text;
    buffer.write(text.substring(start));
    return buffer.toString();
  }

  static String _titled(String plain) => plain.length == 1
      ? plain.toUpperCase()
      : plain[0].toUpperCase() + plain.substring(1);

  /// [text] with runs of whitespace collapsed to one space, trimmed.
  ///
  /// Also drops zero-width and soft-hyphen characters, which scraped markup is
  /// full of and which break equality checks in surprising ways.
  String clean(String text) =>
      text.replaceAll(_invisible, '').replaceAll(_spaces, ' ').trim();

  /// [text] with any HTML tags removed and its whitespace cleaned.
  ///
  /// It was `strip` through 5.5.0, which said *remove something* without
  /// saying what, and the something is a whole markup language.
  ///
  /// This is a regex and costs nothing, so it is the one for a snippet and for
  /// the ten thousandth of them. `format.html.parse(t).text` builds a document
  /// and is right about entities, `<script>` bodies and malformed nesting; it
  /// is the one for a page.
  String tags(String text) => clean(text.replaceAll(_tags, ' '));

  /// [input] encoded as base64 text.
  ///
  /// [input] is a `String` or a `List<int>`. It lived on `util.hash` through
  /// 5.5.0 as `encode`, which put a reversible transport encoding among four
  /// one-way digests and named it after the direction rather than the
  /// operation — so `util.hash.encode(secret)` read as the thing it is not.
  String base64(Object input) => convert.base64.encode(_bytes(input));

  /// Reverses [base64], returning the decoded bytes.
  ///
  /// The name is ugly and unambiguous, which is the trade: `decode` on its own
  /// says nothing, and one function is never a sub-namespace.
  List<int> unbase64(String input) => convert.base64.decode(input);

  static List<int> _bytes(Object input) => switch (input) {
    String text => convert.utf8.encode(text),
    List<int> bytes => bytes,
    _ => convert.utf8.encode(input.toString()),
  };

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

  /// The first decimal number in [text], ignoring currency and separators.
  ///
  /// Returns `null` when there is no number.
  ///
  /// ```dart
  /// Text.number(r'$1,234.50');   // 1234.5
  /// Text.number('(1,234.50)');   // -1234.5  — accounting negative
  /// Text.number('1.5e3');        // 1500.0
  /// Text.number('12 34');        // 12       — two numbers, not 1234
  /// ```
  ///
  /// A comma, underscore or space between digits is grouping and dropped, but
  /// only where it separates whole groups of three: `'1 234 567'` is one
  /// number and `'12 34'` is two. A number wrapped in parentheses is negative,
  /// which is how a financial table writes it. An exponent is read.
  ///
  /// Decimal only — the first *numeral* is what it finds, so `'0x10'` is `0`
  /// rather than 16.
  num? number(String text) {
    final match = _digits.firstMatch(text);
    return match == null ? null : _read(match.group(0)!);
  }

  /// Every number in [text], in order, read the same way as [number].
  List<num> numbers(String text) => _digits
      .allMatches(text)
      .map((match) => _read(match.group(0)!))
      .whereType<num>()
      .toList();

  /// One matched token as a number, applying the parenthesised negative.
  static num? _read(String token) {
    final parenthesised = token.startsWith('(');
    final body = parenthesised ? token.substring(1, token.length - 1) : token;
    final value = num.tryParse(body.replaceAll(_grouping, ''));
    if (value == null) return null;
    return parenthesised ? -value : value;
  }

  /// [text] with the first letter of each word capitalised.
  String title(String text) => text.replaceAllMapped(
    _wordish,
    (m) =>
        m.group(0)!.substring(0, 1).toUpperCase() +
        m.group(0)!.substring(1).toLowerCase(),
  );

  /// [text] with its first letter upper-cased and the rest untouched.
  ///
  /// ```dart
  /// Text.upper('crème brûlée');   // 'Crème brûlée'
  /// ```
  ///
  /// The first letter only — [title] is the one that does every word, and
  /// upper-casing a whole string is `toUpperCase`, which `dart:core` owns.
  ///
  /// There is deliberately no `lower`: `toLowerCase()` needs no help, and
  /// this exists only because title-casing an all-caps string wants the
  /// locale-independent first letter.
  String upper(String text) =>
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

  /// The words in [text].
  List<String> words(String text) =>
      _wordish.allMatches(text).map((m) => m.group(0)!).toList();

  /// Whether [text] holds nothing but whitespace, or is empty.
  bool blank(String text) => text.trim().isEmpty;

  static final _slots = RegExp(r'\{(\w+)\}');

  /// [template] with every `{key}` replaced by [values].
  ///
  /// The only member here that *produces* text: scripts generate it constantly
  /// — a commit message, a PR body, an HTML index over what was just scraped,
  /// a config file for the next stage — and a template that came from a file
  /// is otherwise `replaceAll` in a loop.
  ///
  /// ```dart
  /// Text.render('Hello {name}, {count} new', {'name': 'x', 'count': 3});
  /// // 'Hello x, 3 new'
  ///
  /// Text.render(Files.readTextSync('template.md'), vars);
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
  ///
  /// The quickest way to pull a value out of markup no selector reaches, such
  /// as a string embedded in a `<script>` block. The singular was `between`
  /// through 6.1.0 — a second scan of the same string for the first hit,
  /// which `.collect(.first())` already asks for:
  ///
  /// ```dart
  /// Text.betweens(body, '"videoId":"', '"').firstOrNull;
  /// ```
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

part of '../../path.dart';

/// A glob, checked when made: `*` within a name, `**` across folders, `?`, `[abc]`, `[!abc]`,
/// `{a,b}`, and `\` before a character to mean that character (`a\*b`); folders are `/`. It is a [String], so it goes wherever a glob's text does (`files(only:)`,
/// `ignore:`, an archive's `only:`), and is compiled once.
///
/// ```dart
/// final songs = '**/*.{mp3,flac}'.glob;
/// await for (final f in dir.files(only: songs)) { … }
/// songs.matches('a/b/c.mp3');   // true
/// ```
///
/// {@category Files}
extension type const Glob._(String _text) implements String {
  /// [text] as a glob; an empty one, or one with an unclosed `[` or `{`, is a [FormatException].
  Glob(String text) : _text = _checked(text);

  /// Whether [path] (relative, `/` or `\` between folders) is one this glob names.
  bool matches(String path) => _compiled(_text).hasMatch(path.replaceAll(r'\', '/'));

  static String _checked(String text) {
    if (text.isEmpty) throw FormatException('Invalid glob: it is empty', text);
    var brackets = 0, braces = 0;
    for (var i = 0; i < text.length; i++) {
      switch (text[i]) {
        case r'\':
          i++;
        case '[' when brackets == 0:
          brackets = 1;
        case ']' when brackets == 1:
          brackets = 0;
        case '{' when brackets == 0:
          braces++;
        case '}' when brackets == 0 && braces > 0:
          braces--;
      }
    }
    if (brackets > 0) throw FormatException('Invalid glob "$text": a [ is not closed', text);
    if (braces > 0) throw FormatException('Invalid glob "$text": a { is not closed', text);
    _compiled(text);
    return text;
  }

  /// Compiled globs, the most recent kept.
  static final _cache = <String, RegExp>{};

  static RegExp _compiled(String text) {
    if (_cache.remove(text) case final hit?) return _cache[text] = hit;
    if (_cache.length >= 256) _cache.remove(_cache.keys.first);
    return _cache[text] = _globToRegex(text);
  }
}

/// Text read as a [Glob].
///
/// {@category Files}
extension StringGlobExtensions on String {
  /// This text as a [Glob]: `'**/*.mp3'.glob`. An unclosed `[` or `{` is a [FormatException].
  Glob get glob => Glob(this);
}

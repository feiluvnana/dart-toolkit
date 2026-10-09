part of '../path.dart';

/// Permission bits as `chmod` reads them, checked when made: octal (`'755'`, `'0600'`, `'6755'`)
/// or symbolic (`'+x'`, `'u+rw,go-w'`, `'a=r'`). It is a [String], so it goes wherever a mode's
/// text does: `chmod('755')` checks at the call, `chmod('755'.mode)` where the mode is written.
///
/// ```dart
/// final private = '600'.mode;
/// await secrets.chmod(private);
/// final mode = Option.by('mode', 'Permissions', parse: Mode.new);   // a bad one is a usage error
/// ```
///
/// {@category Files}
extension type const Mode._(String _text) implements String {
  /// [text] as a mode; anything that is neither octal nor symbolic is a [FormatException].
  Mode(String text) : _text = _checked(text);

  /// Whether it changes the bits there (`u+x`) rather than setting them all (`755`).
  bool get isSymbolic => !_octalMode.hasMatch(_text);

  /// The bits an octal mode sets; `null` for a symbolic one, which depends on the file's.
  int? get bits => isSymbolic ? null : int.parse(_text, radix: 8);

  static String _checked(String text) {
    if (_octalMode.hasMatch(text) || (text.isNotEmpty && text.split(',').every(_symbolicClause.hasMatch))) return text;
    throw FormatException('Invalid mode "$text": expected octal (755) or symbolic (u+x,go-w)', text);
  }
}

/// Text read as a [Mode].
///
/// {@category Files}
extension StringModeExtensions on String {
  /// This text as a [Mode]: `'755'.mode`. Neither octal nor symbolic is a [FormatException].
  Mode get mode => Mode(this);
}

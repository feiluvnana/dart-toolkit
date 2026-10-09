part of '../../hash.dart';

/// Hex text, checked when made: an even number of hex digits (whitespace allowed between them),
/// as a published digest or a key is written. It is a [String], so it goes wherever hex text does
/// (`Checksum`, `digest.matches(…)`), and [bytes] decodes it.
///
/// ```dart
/// final sum = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'.hex;
/// (await Hash.sha256.file(iso)).matches(sum);
/// ```
///
/// {@category Hashing}
extension type const Hex._(String _text) implements String {
  /// [text] as hex; anything but an even number of hex digits is a [FormatException] naming where.
  Hex(String text) : _text = text {
    if (text.trim().isEmpty) throw FormatException('Invalid hex: it is empty', text);
    text.hexBytes;
  }

  /// The bytes it writes.
  Uint8List get bytes => _text.hexBytes;
}

/// Text read as [Hex].
///
/// {@category Hashing}
extension StringHexExtensions on String {
  /// This text checked as hex, not encoded to it: `'9f86…'.hex`. Anything but an even number of
  /// hex digits is a [FormatException]. To encode bytes, `bytes.hex`.
  Hex get hex => Hex(this);
}

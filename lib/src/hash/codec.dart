part of '../../hash.dart';

const _hexDigits = '0123456789abcdef';
const _b32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

String _hex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb
      ..write(_hexDigits[b >> 4])
      ..write(_hexDigits[b & 0xf]);
  }
  return sb.toString();
}

/// Encodings of bytes: `digest.hex`, `token.base64Url`, `secret.base32`.
///
/// {@category Hashing}
extension BytesEncodingExtensions on List<int> {
  /// Hex, lowercase.
  String get hex => _hex(this);

  /// Standard base64.
  String get base64 => base64Encode(this);

  /// URL-safe base64 without padding, as tokens and JWTs use it.
  String get base64Url => base64UrlEncode(this).replaceAll('=', '');

  /// Base32 (RFC 4648) without padding, as authenticator secrets use it.
  String get base32 {
    final sb = StringBuffer();
    var bits = 0, acc = 0;
    for (final b in this) {
      acc = (acc << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        sb.write(_b32Alphabet[(acc >> bits) & 31]);
      }
    }
    if (bits > 0) sb.write(_b32Alphabet[(acc << (5 - bits)) & 31]);
    return sb.toString();
  }
}

/// Decodings of text: `'6869'.hexBytes`, `'-_8'.base64Bytes`, `'JBSWY3DP'.base32Bytes`.
///
/// {@category Hashing}
extension StringEncodingExtensions on String {
  /// This hex string as bytes; whitespace is ignored.
  Uint8List get hexBytes {
    final s = replaceAll(RegExp(r'\s'), '');
    if (s.length.isOdd) throw FormatException('Odd-length hex string');
    return Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
  }

  /// This base64 or base64url string as bytes, padding optional.
  Uint8List get base64Bytes => base64Decode(base64.normalize(this));

  /// This base32 string as bytes; case, spaces, dashes and padding are ignored.
  Uint8List get base32Bytes {
    final s = replaceAll(RegExp(r'[\s=-]'), '').toUpperCase();
    final out = BytesBuilder(copy: false);
    var bits = 0, acc = 0;
    for (final c in s.codeUnits) {
      final v = _b32Alphabet.indexOf(String.fromCharCode(c));
      if (v < 0) throw FormatException('Not base32: ${String.fromCharCode(c)}');
      acc = ((acc << 5) | v) & 0xffff;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.addByte((acc >> bits) & 0xff);
      }
    }
    return out.takeBytes();
  }
}

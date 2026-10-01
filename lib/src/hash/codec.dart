part of '../../hash.dart';

const _hexDigits = '0123456789abcdef';
const _b32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

String _hex(List<int> bytes) {
  final out = Uint8List(bytes.length * 2);
  for (var i = 0; i < bytes.length; i++) {
    out[2 * i] = _hexDigits.codeUnitAt(bytes[i] >> 4 & 0xf);
    out[2 * i + 1] = _hexDigits.codeUnitAt(bytes[i] & 0xf);
  }
  return String.fromCharCodes(out);
}

/// The value of the hex digit at [i] in [s]; anything else, a sign included, is refused.
int _nibble(String s, int i) => switch (s.codeUnitAt(i)) {
  final c && >= 0x30 && <= 0x39 => c - 0x30,
  final c && >= 0x61 && <= 0x66 => c - 0x57,
  final c && >= 0x41 && <= 0x46 => c - 0x37,
  _ => throw FormatException('Not a hex digit', s, i),
};

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

final _whitespace = RegExp(r'\s');
final _base32Ignored = RegExp(r'[\s=-]');

int _b32Value(int c) {
  if (c >= 0x41 && c <= 0x5a) return c - 0x41;
  if (c >= 0x32 && c <= 0x37) return c - 0x18;
  throw FormatException('Not base32: ${String.fromCharCode(c)}');
}

/// Decodings of text: `'6869'.hexBytes`, `'-_8'.base64Bytes`, `'JBSWY3DP'.base32Bytes`.
///
/// {@category Hashing}
extension StringEncodingExtensions on String {
  /// This hex string as bytes; whitespace is ignored.
  Uint8List get hexBytes {
    final s = replaceAll(_whitespace, '');
    if (s.length.isOdd) throw FormatException('Odd-length hex string', this);
    final len = s.length ~/ 2;
    final out = Uint8List(len);
    for (var i = 0; i < len; i++) {
      out[i] = _nibble(s, i * 2) << 4 | _nibble(s, i * 2 + 1);
    }
    return out;
  }

  /// This base64 or base64url string as bytes, padding optional.
  Uint8List get base64Bytes => base64Decode(base64.normalize(this));

  /// This base32 string as bytes; case, spaces, dashes and padding are ignored.
  Uint8List get base32Bytes {
    final s = replaceAll(_base32Ignored, '').toUpperCase();
    final out = BytesBuilder(copy: false);
    var bits = 0, acc = 0;
    for (final c in s.codeUnits) {
      final v = _b32Value(c);
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

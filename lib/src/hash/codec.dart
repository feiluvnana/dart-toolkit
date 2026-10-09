part of '../../hash.dart';

const _hexDigits = '0123456789abcdef';
const _b32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

final _hexLookup16 = Uint16List.fromList([
  for (var b = 0; b < 256; b++)
    Endian.host == Endian.little
        ? _hexDigits.codeUnitAt((b >> 4) & 0xf) | (_hexDigits.codeUnitAt(b & 0xf) << 8)
        : (_hexDigits.codeUnitAt((b >> 4) & 0xf) << 8) | _hexDigits.codeUnitAt(b & 0xf),
]);
final _b32Codes = Uint8List.fromList(_b32Alphabet.codeUnits);

String _hex(List<int> bytes) {
  final len = bytes.length;
  final out = Uint8List(len * 2);
  final out16 = Uint16List.view(out.buffer);
  for (var i = 0; i < len; i++) {
    final b = bytes[i];
    if (b & ~0xff != 0) _notByte(bytes, i);
    out16[i] = _hexLookup16[b];
  }
  return String.fromCharCodes(out);
}

/// A list of ints that are not all bytes is the caller's mistake.
Never _notByte(List<int> bytes, int i) =>
    throw ArgumentError.value(bytes[i], 'bytes[$i]', 'Invalid byte: not in 0..255');

/// The value of the hex digit at [i] in [s]; anything else, a sign included, is refused.
int _nibble(String s, int i) => switch (s.codeUnitAt(i)) {
  final c && >= 0x30 && <= 0x39 => c - 0x30,
  final c && >= 0x61 && <= 0x66 => c - 0x57,
  final c && >= 0x41 && <= 0x46 => c - 0x37,
  _ => throw FormatException('Invalid hex: not a hex digit', s, i),
};

/// Encodings of bytes: `digest.hex`, `secret.base32`, `image.base64`. A value outside 0..255
/// is an [ArgumentError].
///
/// {@category Hashing}
extension BytesEncodingExtensions on List<int> {
  /// Hex, lowercase.
  String get hex => _hex(this);

  /// Base32 (RFC 4648) without padding, as authenticator secrets use it.
  String get base32 {
    if (isEmpty) return '';
    final outLen = ((length * 8) + 4) ~/ 5;
    final out = Uint8List(outLen);
    var bits = 0, acc = 0, k = 0;
    for (var i = 0; i < length; i++) {
      final b = this[i];
      if (b & ~0xff != 0) _notByte(this, i);
      acc = ((acc << 8) | b) & 0xffff;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out[k++] = _b32Codes[(acc >> bits) & 31];
      }
    }
    if (bits > 0) out[k++] = _b32Codes[(acc << (5 - bits)) & 31];
    return String.fromCharCodes(out);
  }

  /// Base64 (RFC 4648), padded, as `data:` URLs and JSON bodies carry bytes.
  String get base64 => base64Encode(this);

  /// Base64 with the URL-safe alphabet (`-_`), unpadded, as tokens and JWTs carry it.
  String get base64url => base64UrlEncode(this).replaceAll('=', '');
}

final _whitespace = RegExp(r'\s');

// ASCII only: `toUpperCase` would turn `ſ` into `S` and `ß` into `SS`.
int _b32Value(int c, String source, int at) {
  if (c >= 0x41 && c <= 0x5a) return c - 0x41;
  if (c >= 0x61 && c <= 0x7a) return c - 0x61;
  if (c >= 0x32 && c <= 0x37) return c - 0x18;
  throw FormatException('Invalid base32: not a base32 digit', source, at);
}

/// Decodings of text: `'6869'.hexBytes`, `'JBSWY3DP'.base32Bytes`, `jwt.split('.')[1].base64Bytes`.
/// What does not decode is a [FormatException] whose offset is in this text.
///
/// {@category Hashing}
extension StringEncodingExtensions on String {
  /// This text as UTF-8 bytes.
  Uint8List get utf8Bytes => utf8.encode(this);

  /// This hex string as bytes; whitespace is ignored.
  Uint8List get hexBytes {
    final out = Uint8List(length ~/ 2);
    var n = 0, high = -1;
    for (var i = 0; i < length; i++) {
      final c = codeUnitAt(i);
      if (c == 0x20 || (c >= 0x09 && c <= 0x0d)) continue;
      final v = _nibble(this, i);
      if (high < 0) {
        high = v;
      } else {
        out[n++] = high << 4 | v;
        high = -1;
      }
    }
    if (high >= 0) throw FormatException('Invalid hex: an odd number of digits', this);
    return n == out.length ? out : Uint8List.sublistView(out, 0, n);
  }

  /// This base32 string as bytes; case, whitespace, dashes and padding are ignored.
  Uint8List get base32Bytes {
    final out = Uint8List(length * 5 ~/ 8);
    var bits = 0, acc = 0, k = 0, digits = 0;
    for (var i = 0; i < length; i++) {
      final c = codeUnitAt(i);
      if (c == 0x3d || c == 0x2d || c == 0x20 || (c >= 0x09 && c <= 0x0d)) continue;
      acc = ((acc << 5) | _b32Value(c, this, i)) & 0xffff;
      digits++;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out[k++] = (acc >> bits) & 0xff;
      }
    }
    // 1, 3 or 6 digits past a full group carry under a byte: nothing encodes to that.
    if (const {1, 3, 6}.contains(digits % 8)) throw FormatException('Invalid base32: a cut-off length', this);
    return Uint8List.sublistView(out, 0, k);
  }

  /// This base64 string as bytes: either alphabet (`+/` or `-_`), padding optional, whitespace
  /// ignored, so a JWT part or a wrapped PEM body decodes as it is.
  Uint8List get base64Bytes {
    var s = contains(_whitespace) ? replaceAll(_whitespace, '') : this;
    var end = s.length;
    while (end > 0 && s.codeUnitAt(end - 1) == 0x3d) {
      end--;
    }
    s = s.substring(0, end);
    try {
      return base64Decode(s.padRight((s.length + 3) & ~3, '='));
    } on FormatException catch (e) {
      throw FormatException('Invalid base64: ${e.message}', this);
    }
  }
}

part of '../../hash.dart';

final _secure = Random.secure();

/// [n] random bytes from the operating system.
Uint8List _randomBytes(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) _secure.nextInt(256)]);

/// Random bytes, tokens, identifiers, and comparing digests without leaking where they
/// differ.
///
/// {@category Hashing}
abstract final class Crypto {
  /// [length] random bytes.
  static Uint8List randomBytes([int length = 32]) => _randomBytes(length);

  /// A random token for URLs and headers: [length] bytes as base64url, 43 characters for 32.
  static String token([int length = 32]) => _randomBytes(length).base64Url;

  /// A random (version 4) UUID.
  static String uuid() {
    final b = _randomBytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = _hex(b);
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  /// Whether [a] and [b] are equal, in time that depends only on their lengths.
  ///
  /// Use it to compare a digest or a MAC against one that arrived from outside; `==` on a
  /// list stops at the first difference and so says how much of a guess was right.
  static bool equals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

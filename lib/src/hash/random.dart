part of '../../hash.dart';

final _secure = Random.secure();

/// [n] random bytes from the operating system, drawn four at a time: `nextInt` costs the
/// same for 32 bits as for 8.
Uint8List _randomBytes(int n) {
  final words = Uint32List((n + 3) >> 2);
  for (var i = 0; i < words.length; i++) {
    words[i] = _secure.nextInt(1 << 32);
  }
  return Uint8List.view(words.buffer, 0, n);
}

/// Random bytes, tokens and UUIDs from the operating system's secure source, and a
/// constant-time comparison. Not `Crypto`: this package does not protect data.
///
/// {@category Hashing}
abstract final class Secure {
  /// [length] random bytes.
  static Uint8List bytes([int length = 32]) => _randomBytes(length);

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

  /// Whether [a] and [b] are equal, in time that depends only on their lengths: for a MAC
  /// that arrived from outside, where an early exit would leak how much of a guess was right.

  static bool equals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

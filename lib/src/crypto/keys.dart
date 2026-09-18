part of '../../crypto.dart';

final _secure = Random.secure();

/// Random bytes from the operating system.
Uint8List _randomBytes(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) _secure.nextInt(256)]);

/// Secret bytes: a key, a seed, a salt. Prints its length, never its bytes.
///
/// {@category Crypto}
final class Key {
  final Uint8List bytes;

  const Key(this.bytes);

  /// [length] random bytes from the operating system.
  Key.random([int length = 32]) : bytes = _randomBytes(length);

  Key.fromHex(String hex) : bytes = hex.hexBytes;
  Key.fromBase64(String text) : bytes = text.base64Bytes;

  /// UTF-8 bytes of [text] — a passphrase, not a key; derive with [Pbkdf2] or [Argon2id].
  Key.text(String text) : bytes = utf8.encode(text);

  int get length => bytes.length;
  String get hex => bytes.hex;
  String get base64 => bytes.base64;

  @override
  String toString() => 'Key(${bytes.length} bytes)';
}

/// Small things every secret handling needs.
///
/// {@category Crypto}
abstract final class Crypto {
  /// [length] random bytes.
  static Uint8List randomBytes([int length = 32]) => _randomBytes(length);

  /// A random token for URLs and headers: [length] bytes as base64url, 43 characters for 32.
  static String token([int length = 32]) => _randomBytes(length).base64Url;

  /// Whether [a] and [b] are equal, in time that depends only on their lengths.
  static bool equals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

// ---------------------------------------------------------------------------------------------
// Key derivation
// ---------------------------------------------------------------------------------------------

/// PBKDF2: a key from a password, slowly on purpose.
///
/// {@category Crypto}
final class Pbkdf2 {
  final Hash hash;
  final int iterations;

  /// OWASP's 2023 floor for SHA-256 is 600 000.
  const Pbkdf2(this.hash, {this.iterations = 600000});

  /// [length] bytes derived from [password] and [salt].
  Uint8List derive(List<int> password, List<int> salt, {int length = 32}) {
    if (Native.isAvailable) {
      return _with2(
        password,
        salt,
        (p, pl, s, sl) => Native.withOut(length, (out) => _N.pbkdf2(hash.index, p, pl, s, sl, iterations, out, length)),
      );
    }
    final h = hash._crypto;
    if (h == null) throw UnsupportedError('pbkdf2 ${hash.name} needs dart_toolkit_native: ${Native.reason}');
    // RFC 8018 §5.2 over package:crypto's HMAC.
    final mac = crypto.Hmac(h, password);
    final out = BytesBuilder(copy: false);
    for (var block = 1; out.length < length; block++) {
      var u = Uint8List.fromList(
        mac.convert([...salt, block >> 24, block >> 16 & 0xff, block >> 8 & 0xff, block & 0xff]).bytes,
      );
      final t = Uint8List.fromList(u);
      for (var i = 1; i < iterations; i++) {
        u = Uint8List.fromList(mac.convert(u).bytes);
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.add(t);
    }
    return Uint8List.sublistView(out.takeBytes(), 0, length);
  }
}

/// HKDF (RFC 5869): keys from a secret that is already strong.
///
/// {@category Crypto}
final class Hkdf {
  final Hash hash;

  const Hkdf([this.hash = Hash.sha256]);

  /// [length] bytes from [secret], with optional [salt] and context [info].
  Uint8List derive(List<int> secret, {List<int> salt = const [], List<int> info = const [], int length = 32}) {
    if (Native.isAvailable) {
      return _with3(
        secret,
        salt,
        info,
        (s, sl, a, al, i, il) => Native.withOut(length, (out) => _N.hkdf(hash.index, s, sl, a, al, i, il, out, length)),
      );
    }
    final h = hash._crypto;
    if (h == null) throw UnsupportedError('hkdf ${hash.name} needs dart_toolkit_native: ${Native.reason}');
    final prk = crypto.Hmac(h, salt.isEmpty ? Uint8List(hash.length) : salt).convert(secret).bytes;
    final out = BytesBuilder(copy: false);
    var t = <int>[];
    for (var i = 1; out.length < length; i++) {
      t = crypto.Hmac(h, prk).convert([...t, ...info, i]).bytes;
      out.add(t);
    }
    return Uint8List.sublistView(out.takeBytes(), 0, length);
  }

  /// Several keys from one secret, one `info` label each.
  List<Uint8List> expand(List<int> secret, {required Map<String, int> lengths, List<int> salt = const []}) => [
    for (final MapEntry(key: label, value: n) in lengths.entries)
      derive(secret, salt: salt, info: utf8.encode(label), length: n),
  ];
}

/// Argon2id (RFC 9106): the password hash to use when the native library is present.
///
/// {@category Crypto}
final class Argon2id {
  /// Memory in KiB; 64 MiB by default.
  final int memoryKib;
  final int iterations;
  final int parallelism;

  const Argon2id({this.memoryKib = 65536, this.iterations = 3, this.parallelism = 4});

  Uint8List derive(List<int> password, List<int> salt, {int length = 32}) =>
      _with2(password, salt, (p, pl, s, sl) => Native.withOut(length, (out) => _argon2(p, pl, s, sl, out, length)));

  int _argon2(_U8 p, int pl, _U8 s, int sl, _U8 out, int length) {
    Native.require('argon2id');
    return _N.argon2id(p, pl, s, sl, memoryKib, iterations, parallelism, out, length);
  }
}

/// Password hashing that carries its own parameters, so verification reads them back:
/// `argon2id$m=65536,t=3,p=4$<salt>$<hash>` natively, `pbkdf2-sha256$600000$<salt>$<hash>` in Dart.
///
/// {@category Crypto}
abstract final class Password {
  /// A stored form of [password], with a fresh 16-byte salt.
  static String hash(String password) {
    final salt = _randomBytes(16);
    final pw = utf8.encode(password);
    if (Native.isAvailable) {
      const a = Argon2id();
      final h = a.derive(pw, salt);
      return 'argon2id\$m=${a.memoryKib},t=${a.iterations},p=${a.parallelism}\$${salt.base64Url}\$${h.base64Url}';
    }
    const k = Pbkdf2(Hash.sha256);
    return 'pbkdf2-sha256\$${k.iterations}\$${salt.base64Url}\$${k.derive(pw, salt).base64Url}';
  }

  /// Whether [password] produced [stored]; constant time over the hash.
  static bool verify(String password, String stored) {
    final parts = stored.split('\$');
    if (parts.length != 4) return false;
    final pw = utf8.encode(password);
    final salt = parts[2].base64Bytes;
    final expected = parts[3].base64Bytes;
    final Uint8List actual;
    switch (parts[0]) {
      case 'argon2id':
        final p = {for (final kv in parts[1].split(',')) kv.split('=')[0]: int.parse(kv.split('=')[1])};
        actual = Argon2id(
          memoryKib: p['m']!,
          iterations: p['t']!,
          parallelism: p['p']!,
        ).derive(pw, salt, length: expected.length);
      case 'pbkdf2-sha256':
        actual = Pbkdf2(Hash.sha256, iterations: int.parse(parts[1])).derive(pw, salt, length: expected.length);
      default:
        return false;
    }
    return Crypto.equals(actual, expected);
  }
}

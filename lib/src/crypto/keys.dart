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
  Key.fromBase32(String text) : bytes = text.base32Bytes;

  /// UTF-8 bytes of [text]: a passphrase, not a key; derive with [Argon2id] or [Pbkdf2].
  Key.text(String text) : bytes = utf8.encode(text);

  int get length => bytes.length;
  String get hex => bytes.hex;
  String get base64 => bytes.base64;
  String get base32 => bytes.base32;

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

  /// A random (version 4) UUID.
  static String uuid() {
    final b = _randomBytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = _hex(b);
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

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
// Key derivation and password hashing
// ---------------------------------------------------------------------------------------------

/// Turns a password into a stored string that carries its own algorithm, parameters and salt,
/// in the standard form other systems read (`$argon2id$…`, `$2b$…`, `$scrypt$…`,
/// `$pbkdf2-sha256$…`); [Password.verify] reads any of them back.
///
/// {@category Crypto}
abstract interface class PasswordHasher {
  String hash(String password);
}

String _passwordHash(int alg, int a, int b, int c, String password) => Native.withBytes(
  utf8.encode(password),
  (p, pl) => _takeText((out, len) => _N.passwordHash(alg, a, b, c, p, pl, out, len)),
);

Uint8List _kdf(_SlowKdf f, List<int> password, List<int> salt, int a, int b, int c, int length) =>
    _with2(password, salt, (p, pl, s, sl) => Native.withOut(length, (out) => f(p, pl, s, sl, a, b, c, out, length)));

/// Argon2id (RFC 9106): the password hash to choose today.
///
/// {@category Crypto}
final class Argon2id implements PasswordHasher {
  /// Memory in KiB; 64 MiB by default.
  final int memoryKib;
  final int iterations;
  final int parallelism;

  const Argon2id({this.memoryKib = 65536, this.iterations = 3, this.parallelism = 4});

  /// [length] raw bytes from [password] and [salt], for a key.
  Uint8List derive(List<int> password, List<int> salt, {int length = 32}) =>
      _kdf(_N.argon2id, password, salt, memoryKib, iterations, parallelism, length);

  /// `$argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>` with a fresh salt.
  @override
  String hash(String password) => _passwordHash(0, memoryKib, iterations, parallelism, password);
}

/// bcrypt: what most existing user tables hold. Passwords longer than 72 bytes are truncated.
///
/// {@category Crypto}
final class Bcrypt implements PasswordHasher {
  /// Work factor, log2 of the rounds; 12 is 4 096 rounds.
  final int cost;

  const Bcrypt({this.cost = 12});

  /// `$2b$12$<salt+hash>` with a fresh salt.
  @override
  String hash(String password) => _passwordHash(1, cost, 0, 0, password);
}

/// scrypt (RFC 7914).
///
/// {@category Crypto}
final class Scrypt implements PasswordHasher {
  /// log2 of the CPU/memory cost N; 15 is 32 MiB.
  final int logN;
  final int r;
  final int p;

  const Scrypt({this.logN = 15, this.r = 8, this.p = 1});

  Uint8List derive(List<int> password, List<int> salt, {int length = 32}) =>
      _kdf(_N.scrypt, password, salt, logN, r, p, length);

  /// `$scrypt$ln=15,r=8,p=1$<salt>$<hash>` with a fresh salt.
  @override
  String hash(String password) => _passwordHash(2, logN, r, p, password);
}

/// PBKDF2 (RFC 8018), for systems that still require it.
///
/// {@category Crypto}
final class Pbkdf2 implements PasswordHasher {
  final Hash digest;
  final int iterations;

  /// OWASP's floor for SHA-256 is 600 000.
  const Pbkdf2([this.digest = Hash.sha256, this.iterations = 600000]);

  Uint8List derive(List<int> password, List<int> salt, {int length = 32}) => _with2(
    password,
    salt,
    (p, pl, s, sl) => Native.withOut(length, (out) => _N.pbkdf2(digest.index, p, pl, s, sl, iterations, out, length)),
  );

  /// `$pbkdf2-sha256$i=600000$<salt>$<hash>` with a fresh salt; the digest must be SHA-256 or SHA-512.
  @override
  String hash(String password) {
    if (digest != Hash.sha256 && digest != Hash.sha512) {
      throw ArgumentError.value(digest, 'digest', 'the PBKDF2 string form takes SHA-256 or SHA-512');
    }
    return _passwordHash(3, iterations, digest.index, 0, password);
  }
}

/// HKDF (RFC 5869): keys from a secret that is already strong.
///
/// {@category Crypto}
final class Hkdf {
  final Hash digest;

  const Hkdf([this.digest = Hash.sha256]);

  /// [length] bytes from [secret], with optional [salt] and context [info].
  Uint8List derive(List<int> secret, {List<int> salt = const [], List<int> info = const [], int length = 32}) => _with3(
    secret,
    salt,
    info,
    (s, sl, a, al, i, il) => Native.withOut(length, (out) => _N.hkdf(digest.index, s, sl, a, al, i, il, out, length)),
  );

  /// Several keys from one secret, one `info` label each.
  List<Uint8List> expand(List<int> secret, {required Map<String, int> lengths, List<int> salt = const []}) => [
    for (final MapEntry(key: label, value: n) in lengths.entries)
      derive(secret, salt: salt, info: utf8.encode(label), length: n),
  ];
}

/// Password storage: [hash] with the algorithm of your choice, [verify] with whatever the
/// string says it is.
///
/// ```dart
/// final stored = Password.hash(input);                 // Argon2id
/// final legacy = Password.hash(input, const Bcrypt()); // for a table other software reads
/// Password.verify(input, stored);
/// ```
///
/// {@category Crypto}
abstract final class Password {
  static String hash(String password, [PasswordHasher algorithm = const Argon2id()]) => algorithm.hash(password);

  /// Whether [password] produced [stored]: bcrypt (`$2a$`, `$2b$`, `$2y$`), Argon2, scrypt or
  /// PBKDF2 in PHC form. Malformed input is `false`, never an error.
  static bool verify(String password, String stored) =>
      _with2(utf8.encode(password), utf8.encode(stored), (p, pl, s, sl) => _N.passwordVerify(p, pl, s, sl)) == 1;
}

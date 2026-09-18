part of '../../crypto.dart';

/// JSON Web Tokens: `HS256/384/512`, `RS256`, `PS256`, `ES256` and `EdDSA`, the algorithm
/// chosen by the key you pass.
///
/// ```dart
/// final token = Jwt.sign({'sub': 'app', 'exp': Jwt.at(10.min.fromNow)}, key);
/// final claims = Jwt.verify(token, key);  // throws JwtException when it does not hold
/// ```
///
/// {@category Crypto}
abstract final class Jwt {
  /// Signs [claims]: a [Key] gives `HS256` (`HS384`/`HS512` by [hash]), an [Ed25519] `EdDSA`,
  /// an [Ecdsa] `ES256`, an [Rsa] `RS256` (`PS256` with [pss]).
  static String sign(Map<String, Object?> claims, Object key, {Hash hash = Hash.sha256, bool pss = false}) {
    final alg = switch (key) {
      Key() => 'HS${_bits(hash)}',
      Ed25519() => 'EdDSA',
      Ecdsa() => 'ES256',
      Rsa() => '${pss ? 'PS' : 'RS'}${_bits(hash)}',
      _ => throw ArgumentError.value(key, 'key', 'a Key, Ed25519, Ecdsa or Rsa'),
    };
    final signing = '${_segment({'alg': alg, 'typ': 'JWT'})}.${_segment(claims)}';
    final input = utf8.encode(signing);
    final sig = switch (key) {
      Key() => input.hmacBytes(hash, key.bytes),
      Ed25519() => key.sign(input),
      Ecdsa() => key.sign(input),
      Rsa() => key.sign(input, hash: hash, pss: pss),
      _ => throw StateError('unreachable'),
    };
    return '$signing.${sig.base64Url}';
  }

  /// The claims of [token] once its signature, `exp` and `nbf` hold; otherwise [JwtException].
  ///
  /// [key] is a [Key] for `HS*`; for the rest the signer's own object, its public key bytes
  /// (`EdDSA`, `ES256`) or its public PEM (any). The token's `alg` must match the key's kind,
  /// so a token cannot pick a weaker check than the key it is verified with.
  static Map<String, Object?> verify(String token, Object key, {DateTime? now}) {
    final parts = token.split('.');
    if (parts.length != 3) throw JwtException('Not a JWT: expected three segments');
    final header = _json(parts[0]);
    final alg = header['alg'];
    if (alg is! String || alg == 'none') throw JwtException('Unsupported alg: $alg');
    final input = utf8.encode('${parts[0]}.${parts[1]}');
    final Uint8List sig;
    try {
      sig = parts[2].base64Bytes;
    } on FormatException {
      throw JwtException('Signature is not base64url');
    }
    if (!_check(alg, input, sig, key)) throw JwtException('Signature does not verify with $alg');
    final claims = _json(parts[1]);
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    if (claims['exp'] case final num exp when t >= exp) throw JwtException('Token expired');
    if (claims['nbf'] case final num nbf when t < nbf) throw JwtException('Token not yet valid');
    return claims;
  }

  /// Header and claims of [token], unverified.
  static ({Map<String, Object?> header, Map<String, Object?> claims}) decode(String token) {
    final parts = token.split('.');
    if (parts.length != 3) throw JwtException('Not a JWT: expected three segments');
    return (header: _json(parts[0]), claims: _json(parts[1]));
  }

  /// [time] as the seconds-since-epoch number `exp`, `nbf` and `iat` take.
  static int at(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

  static bool _check(String alg, List<int> input, Uint8List sig, Object key) {
    final Hash? hs = switch (alg) {
      'HS256' || 'RS256' || 'PS256' => Hash.sha256,
      'HS384' || 'RS384' || 'PS384' => Hash.sha384,
      'HS512' || 'RS512' || 'PS512' => Hash.sha512,
      _ => null,
    };
    final isRsa = hs != null && (alg.startsWith('RS') || alg.startsWith('PS'));
    return switch (key) {
      Key() when hs != null && alg.startsWith('HS') => Crypto.equals(input.hmacBytes(hs, key.bytes), sig),
      Ed25519() when alg == 'EdDSA' => Ed25519.verify(key.publicKey, input, sig),
      List<int>() when alg == 'EdDSA' => Ed25519.verify(key, input, sig),
      String() when alg == 'EdDSA' => Ed25519.verify(Ed25519.publicFromPem(key), input, sig),
      Ecdsa() when alg == 'ES256' => Ecdsa.verify(key.publicKey, input, sig),
      List<int>() when alg == 'ES256' => Ecdsa.verify(key, input, sig),
      String() when alg == 'ES256' => Ecdsa.verify(Ecdsa.publicFromPem(key), input, sig),
      Rsa() when isRsa => Rsa.verify(key.publicPem, input, sig, hash: hs, pss: alg.startsWith('PS')),
      String() when isRsa => Rsa.verify(key, input, sig, hash: hs, pss: alg.startsWith('PS')),
      _ => throw JwtException('alg $alg does not match the key given (${key.runtimeType})'),
    };
  }

  static int _bits(Hash hash) => switch (hash) {
    Hash.sha256 => 256,
    Hash.sha384 => 384,
    Hash.sha512 => 512,
    _ => throw ArgumentError.value(hash, 'hash', 'JWTs use SHA-256, SHA-384 or SHA-512'),
  };

  static String _segment(Map<String, Object?> json) => utf8.encode(jsonEncode(json)).base64Url;

  static Map<String, Object?> _json(String segment) {
    try {
      return (jsonDecode(utf8.decode(segment.base64Bytes)) as Map).cast<String, Object?>();
    } on FormatException catch (e) {
      throw JwtException('Segment is not base64url JSON: ${e.message}');
    }
  }
}

/// A token that failed [Jwt.verify], and why.
///
/// {@category Crypto}
final class JwtException implements Exception {
  final String message;
  const JwtException(this.message);
  @override
  String toString() => message;
}

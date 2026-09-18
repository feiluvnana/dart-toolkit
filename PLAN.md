# Plan: `crypto`, from digests to a working cryptography module

`hash` became `crypto` in this release and does digests, CRC-32 and HMAC. This plan is what it
grows into: the subset of pointycastle a script actually reaches for — verify a download, sign a
request, encrypt a secret at rest, derive a key from a password, make a token — with the same
rule the digests already follow: **native through the operating system's library when it is
there, pure Dart when it is not, and never a build step or a toolchain on the user's machine.**

---

## 1. What scripts need, and where each lives today

| need | pointycastle | this module today | native available |
|---|---|---|---|
| digest a file or bytes | SHA-1/2/3, MD5, BLAKE2, RIPEMD | MD5, SHA-1, SHA-2 family, CRC-32 | CommonCrypto, libcrypto |
| MAC | HMAC, CMAC, Poly1305 | HMAC over any digest (pure Dart) | CCHmac, EVP_MAC |
| derive a key from a password | PBKDF2, scrypt, Argon2 | — | CCKeyDerivationPBKDF, EVP_KDF (PBKDF2, scrypt, Argon2 in OpenSSL 3.2) |
| derive keys from a secret | HKDF | — | libcrypto only |
| encrypt bytes | AES-GCM/CBC/CTR, ChaCha20-Poly1305 | — | libcrypto; CommonCrypto has AES-CBC/CTR, not GCM |
| sign and verify | RSA, ECDSA, Ed25519 | — | libcrypto; macOS only through Security.framework |
| random | Fortuna | `Random.secure()` in the SDK | SDK |
| encode | hex, base64 in Dart | hex, base64 in the SDK | SDK |
| compare secrets | — | — | trivial |

Two facts shape the design. macOS ships CommonCrypto (digests, HMAC, PBKDF2, AES-CBC/CTR) and
nothing public for GCM, Ed25519 or ECDSA outside Swift; Linux ships libcrypto with everything.
So the native layer is complete on Linux and partial on macOS, and the pure-Dart fallback decides
what works everywhere.

---

## 2. Shape

One module, `crypto.dart`, one rule per member: a **verb on the data** for the common case, a
**named object** when there is state to hold (a key, a nonce policy, an iteration count).

### 2.1 Digests and MACs (in place; the surface stays)

```dart
await file.sha256();  bytes.sha512;  'text'.md5;  bytes.hash(Hash.sha1);  bytes.crc32
'payload'.hmac(Hash.sha256, secret);  bytes.hmac(Hash.sha1, keyBytes)
```

Add SHA-3 and BLAKE2 through libcrypto when present (`EVP_sha3_256`, `EVP_blake2b512`), pure
Dart otherwise: about 120 lines each. `Hash.sha3_256`, `Hash.blake2b`.

### 2.2 Keys and random

```dart
final key = Key.random(32);                 // Random.secure()
final key = Key.fromHex('…'), Key.fromBase64('…');  key.hex, key.base64, key.bytes
Crypto.token();                             // 32 random bytes, base64url, for URLs and headers
Crypto.equals(a, b);                        // constant time
```

`Key` is a `Uint8List` wrapper with `toString()` that prints `Key(32 bytes)`, never the bytes.

### 2.3 Password and key derivation

```dart
final key = Pbkdf2(Hash.sha256, iterations: 600000).derive(password, salt, length: 32);
final (k1, k2) = Hkdf(Hash.sha256).expand(secret, info: 'ctx', lengths: [32, 32]);
final stored = Password.hash('pw');         // "pbkdf2-sha256$600000$salt$hash", self-describing
Password.verify('pw', stored);              // constant time; reads its own parameters back
```

PBKDF2 native through `CCKeyDerivationPBKDF` and `PKCS5_PBKDF2_HMAC`; HKDF is 40 lines of pure
Dart on top of HMAC and needs no native path. scrypt and Argon2 only where libcrypto 3.2 has
them (`EVP_KDF`), with `UnsupportedError` naming the algorithm elsewhere — a script that needs
them on a Mac says so instead of silently getting something weaker.

### 2.4 Symmetric encryption

```dart
final box = Aes.gcm(key);                   // 128 or 256 by key length
final sealed = box.seal(plain, aad: header);          // nonce chosen, prepended: nonce‖ct‖tag
final plain  = box.open(sealed, aad: header);          // throws on a tampered byte
ChaCha20Poly1305(key).seal(plain)
await file.encryptTo(path, key), path.decryptTo(file, key)   // streamed, chunked GCM
```

One authenticated construction per algorithm, nonces chosen by the library and carried in the
ciphertext, no CBC without a MAC on offer. Native through `EVP_CIPHER` on Linux; on macOS,
AES-GCM in pure Dart (AES ≈ 250 lines, GHASH ≈ 80) — fast enough for secrets and configs, and
the streamed file form chunks at 1 MB so memory stays flat.

### 2.5 Signatures

```dart
final pair = Ed25519.generate();            // or fromSeed(32 bytes)
final sig = pair.sign(bytes);  Ed25519.verify(pair.publicKey, bytes, sig)
Ecdsa.p256(privateKey).sign(bytes)          // for JWTs and cloud APIs that want ES256
Rsa.verify(publicPem, bytes, sig)           // verify only: release artifacts, webhooks
```

Ed25519 is the one to implement in pure Dart (≈ 400 lines, well-specified, constant-time by
construction); it makes signing portable everywhere. ECDSA P-256 and RSA verification through
libcrypto; on macOS through `Security.framework` in a second step if scripts turn out to need
them there.

### 2.6 Encoding

```dart
bytes.hex, bytes.base64, bytes.base64url;  'deadbeef'.hexBytes;  '…'.base64Bytes
```

Small, and every other member above returns and accepts them.

---

## 3. Order, size, tests

| step | what | ~lines | depends on |
|---|---|---|---|
| 1 | `Key`, `Crypto.token`, `Crypto.equals`, encodings | 120 | — |
| 2 | HKDF (pure), PBKDF2 (native + `package:crypto` fallback), `Password` | 200 | 1 |
| 3 | AES-GCM: `EVP_CIPHER` native, pure-Dart AES + GHASH fallback; ChaCha20-Poly1305 native only; streamed file form | 600 | 1 |
| 4 | SHA-3 and BLAKE2 native, pure fallbacks | 300 | — |
| 5 | Ed25519 pure Dart; ECDSA P-256 and RSA verify through libcrypto | 700 | 1 |
| 6 | drop `package:crypto`: own SHA-2 and MD5 in Dart (≈ 250 lines) so the module has no dependency, like every other | 250 | 4 |

Every step is tested three ways: against the `openssl` command line on random inputs (the same
differential method the parsers use), against the published test vectors (RFC 6234, NIST CAVP
GCM, RFC 8032, RFC 5869), and native against pure Dart on the same machine so both paths agree
byte for byte. Nothing ships without the vectors.

## 4. What this module refuses

No ciphers without authentication, no MD5 or SHA-1 for anything but checksums and legacy
HMACs, no home-made constructions, no key material in `toString()`, and no algorithm that runs
only on one platform without saying so in an `UnsupportedError`. A script that wants a
primitive the OS lacks gets a clear error, not a silent downgrade.

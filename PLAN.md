# Plan: one native library, then `crypto` and archives on top of it

The measurements are settled: pure Dart hashes at 168 MB/s where native does 3 GB/s, pure-Dart
AES would be slower still, and 7z, rar, xz and zstd have no SDK codec and would each be a
thousand lines of slow Dart. The previous plan leaned on whatever library the operating system
ships — CommonCrypto on macOS, libcrypto on Linux — which means a different feature set on each
platform and nothing on Windows.

**The decision this plan makes: the toolkit ships its own native library, `dart_toolkit_native`,
prebuilt for every platform, loaded through `dart:ffi`, with the same functions everywhere.**
Nothing is asked of the user's machine — no compiler, no OpenSSL, no `cargo`. Dart stays the
fallback for the primitives a script needs even when the asset is missing (digests, HMAC, HKDF,
PBKDF2, zip, gzip, tar); everything else says clearly that it needs the native library.

---

## 1. The native layer

### 1.1 Language and contents

Rust, one `cdylib`, pure-Rust crates wherever one exists so that cross-compiling is a flag and
the result has no dependency on the target system:

| area | crates | note |
|---|---|---|
| digests | `sha1`, `sha2`, `sha3`, `blake2`, `blake3`, `md-5` | RustCrypto; SHA-NI and NEON where the CPU has them |
| MAC and KDF | `hmac`, `hkdf`, `pbkdf2`, `scrypt`, `argon2` | |
| AEAD | `aes-gcm`, `chacha20poly1305` | AES-NI / PCLMUL detected at runtime |
| signatures | `ed25519-dalek`, `p256`, `rsa` | verify and sign |
| zip | `zip` with `aes-crypto` | read and write, ZipCrypto and WinZip AES-256, ZIP64 |
| 7z | `sevenz-rust2` | read and write, LZMA/LZMA2/BZip2/Deflate, AES-256 + SHA-256 passwords |
| rar | `unrar` (binds RARLAB's unrar C++) | **read only** — the format's licence allows extraction, not creation; RAR4 and RAR5, encrypted headers and files |
| tar | `tar` | ustar, pax, GNU long names; permissions and mtimes |
| gzip, deflate | `flate2` (pure `miniz_oxide`) | |
| xz | `liblzma` via `xz2`, or pure `lzma-rs` for read | write needs liblzma; vendored statically |
| zstd | `zstd` (vendors libzstd, static) | |
| bzip2 | `bzip2-rs` | pure |

Two C/C++ pieces are vendored and statically linked: unrar (there is no other rar reader) and
liblzma/libzstd (pure-Rust encoders are not there yet). Both build with `zig cc` as the C
compiler, so cross-compilation stays a one-machine job.

### 1.2 The C ABI

Small, flat, and the same on every platform. Bytes cross the boundary as `(pointer, length)`;
strings as UTF-8 with length; errors as an `int` code plus a message the caller fetches. No
callbacks into Dart from Rust: long operations report progress by writing into a caller-owned
struct the Dart side polls, and run inside `Isolate.run` so the event loop never waits on them.

```
// digests
tk_digest_new(alg) -> ctx;  tk_digest_update(ctx, ptr, len);  tk_digest_final(ctx, out) -> len
tk_hmac(alg, key, key_len, data, len, out) -> len
tk_pbkdf2(alg, pw, pw_len, salt, salt_len, iters, out, out_len);  tk_hkdf(...);  tk_argon2id(...)
// AEAD
tk_seal(alg, key, nonce, aad, aad_len, plain, len, out) -> len;  tk_open(...) -> len or -1
// signatures
tk_ed25519_keypair(seed, pub_out, priv_out);  tk_ed25519_sign(...);  tk_ed25519_verify(...) -> bool
tk_ecdsa_p256_sign(...);  tk_ecdsa_p256_verify(...);  tk_rsa_verify(pem, len, ...) -> bool
// archives, by path — the file system is the transport, so nothing large crosses the boundary
tk_archive_list(path, password, out_json) -> len         // entries as one JSON string
tk_archive_extract(path, dest, password, progress*) -> code
tk_archive_create(format, src, dest, password, level, progress*) -> code
tk_compress(codec, src, dest, level);  tk_decompress(codec, src, dest)
tk_last_error(out) -> len
```

About 1 500 lines of Rust; the archive functions are thin over the crates.

### 1.3 Building and shipping

- `native/` holds the crate. `tool/build_native.dart` cross-compiles five targets with
  `cargo zigbuild`: linux x64 and arm64, macOS x64 and arm64, windows x64. One machine, one
  command, about ten minutes. There is no CI by your choice; this is the release step that
  replaces it, and the checksums of the five artifacts go into the changelog.
- The binaries ship **inside the pub package** under `native/prebuilt/<target>/`, about 4–6 MB
  each, 25 MB in all, well under pub's limit. No download at install time, so it works offline
  and in locked-down networks.
- Loading: `hook/build.dart` with `package:hooks` and `package:code_assets` registers the
  prebuilt for the target, so `dart run`, `dart test` and `dart compile exe` all find it and the
  compiled executable bundles it. These two packages are the one class of dependency the
  toolkit accepts back: build plumbing from the Dart team, with no runtime code of their own.
  As a second path, when the hook did not run (an older SDK, an unusual embedding), the loader
  looks next to the running executable and then in the package's `native/prebuilt/` through
  `Isolate.resolvePackageUri`, so `dart run file.dart` from a checkout works without the hook.
- `Native.isAvailable` and `Native.version` tell a script what it has. Every native-only member
  throws `UnsupportedError('rar needs dart_toolkit_native, which did not load: <reason>')`.

### 1.4 What stays in Dart

The SDK already has native zlib and `Random.secure()`; the pure-Dart digests, HMAC, HKDF, PBKDF2
and the zip, gzip and tar containers stay as the fallback so a script that only checks a
download still runs where the asset is missing. Native is used whenever it loads.

---

## 2. `crypto`

Same surface as the previous plan, now the same on every platform.

```dart
await file.sha256();  bytes.sha3_256;  'text'.blake3;  bytes.hash(Hash.sha512)
'payload'.hmac(Hash.sha256, secret)
final key = Key.random(32);  Key.fromHex('…');  key.hex, key.base64;  Crypto.token();  Crypto.equals(a, b)
Pbkdf2(Hash.sha256, iterations: 600000).derive(password, salt, length: 32)
Argon2id(memory: 64.mb, iterations: 3).derive(password, salt)          // native only
Hkdf(Hash.sha256).expand(secret, info: 'ctx', lengths: [32, 32])
Password.hash('pw');  Password.verify('pw', stored)                   // self-describing, argon2id native, pbkdf2 fallback
Aes.gcm(key).seal(plain, aad: header);  .open(sealed, aad: header)    // nonce‖ct‖tag
ChaCha20Poly1305(key).seal(plain)
await file.encryptTo(path, key);  await path.decryptTo(file, key)       // streamed, 1 MB chunks
Ed25519.generate();  pair.sign(bytes);  Ed25519.verify(pub, bytes, sig)
Ecdsa.p256(priv).sign(bytes);  Rsa.verify(publicPem, bytes, sig)
bytes.hex, bytes.base64url;  'deadbeef'.hexBytes
```

Rules: no unauthenticated ciphers, no key material in `toString()`, constant-time comparison,
nonces chosen by the library and carried in the ciphertext. `package:crypto` is dropped once
the Dart fallback digests are written (SHA-2 and MD5, about 250 lines), leaving `path` as the
only runtime dependency again.

---

## 3. `fs` archives

One vocabulary for every container, the format read from the extension, a password where the
format has one.

```dart
await src.archiveTo('backup.7z', password: 'pw', level: 7);    // zip, 7z, tar, tar.gz, tgz, tar.xz, tar.zst, tar.bz2
await 'release.tar.zst'.path.extractTo(dir);
await 'photos.rar'.path.extractTo(dir, password: 'pw');          // read only; RAR4 and RAR5
final entries = await 'a.7z'.path.archiveEntries(password: 'pw'); // name, size, compressedSize, modified, isDir, isEncrypted
await log.gzipTo('log.gz');  await 'log.gz'.path.gunzipTo(log);
await big.compressTo('big.zst', Compression.zstd, level: 3);  await 'big.zst'.path.decompressTo(big)
```

- `zipTo`/`zipEntries` stay as they are (Dart, streamed, ZIP64) and gain `password:` — AES-256
  when native is present, ZipCrypto refused as insecure. `extractTo` on a zip stays in Dart and
  hands an encrypted archive to native.
- Extraction restores permissions and modification times on every format, checks each entry
  against the destination as today, and refuses symlinks that point outside it.
- Progress: every long operation takes an optional `TaskProgress` sink, the same seam the
  downloads use, so `Console.multiProgress` renders an extraction unchanged.
- rar is read-only by licence, and the doc says so where the user would look for `archiveTo('x.rar')`.

Throughput to expect: native zstd at hundreds of MB/s, xz at tens, 7z LZMA2 at 10–30 MB/s
compressing and several hundred decompressing — the formats' own speeds, not the boundary's.

---

## 4. Order, size, and what proves each step

| step | what | ~lines | proof |
|---|---|---|---|
| 1 | the crate with digests and HMAC; `tool/build_native.dart`; hook; loader with fallback; `Native.isAvailable` | 400 Rust, 300 Dart | native == Dart digests byte for byte on 1 000 random inputs; loads on all five targets |
| 2 | `Key`, encodings, `Crypto.token/equals`; HKDF, PBKDF2, Argon2id, `Password` | 300 Rust, 300 Dart | RFC 5869, RFC 6070, Argon2 test vectors; `openssl kdf` |
| 3 | AES-GCM, ChaCha20-Poly1305, streamed file forms | 200 Rust, 250 Dart | NIST CAVP GCM vectors, RFC 8439; `openssl enc` round trip |
| 4 | Ed25519, ECDSA P-256, RSA verify | 250 Rust, 250 Dart | RFC 8032, Wycheproof vectors; `openssl dgst -verify` |
| 5 | archives: list, extract, create for zip/7z/tar/gz/xz/zst/bz2; passwords; rar read | 500 Rust, 400 Dart | round trips against the system `7z`, `unrar`, `tar`, `zstd` binaries on the same fixtures; an encrypted 7z and rar fixture with a known password |
| 6 | Dart fallback digests; drop `package:crypto`; SHA-3 and BLAKE3 native | 300 Dart | vectors as above |

Five targets, one build command, one asset per platform in the package, one `UnsupportedError`
message for what a platform cannot do without it. The Dart API never changes with the platform;
only the speed does.

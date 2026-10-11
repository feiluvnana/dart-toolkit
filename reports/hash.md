# Report · Hash & Encoding (`lib/lib2/src/hash/`)

> Companion spec: [`../proposals/09_hash.md`](../proposals/09_hash.md).

---

## 1. Proposal promise (09:5–90)

- One-word `Hash.sha256(File|String|Uint8List)` and `forge(node,vob).digest()` (09:19–33) with a
  **`Hash.sha256.writer()`** that doubles as a `Writer` for `pipe` (09:44–47,
  `File('x').pipe(Hash.sha256.writer())`).
- Streaming chunk APIs (`AlgoWriter(hash)`, `mac`, `Algo.mac`, `forge`), `mac(password).
  checksum(File)` one-shot (09:53–59).
- `xxh3` (the 0.0.x stored Digest; must compute and power the `$lib` dedupe),
  `mac`/`check`, `hmac`, `checksum`, `sha1`, `sha256`, `sha512`; `hex`, `b64`/`base64`,
  `base32`, `crc32` (07:?). Everything is **fast path native** (`Digest` FFI) with a pure-Dart
  fallback.

## 2. Current `lib2` state

`lib/lib2/src/hash/` — `digest.dart` (`algo(fmt)`, `run`, `algo bits`, `Hash`-style `sha256(...)`
one-shots, `HashStream`), `hasher.dart` (`AlgoWriter` **not** extending `Writer`,
`AlgoMac`/`AlgoPass`), `base.dart` (pure-Dart `hex`, `b64`, `base32`, `xor`, `crc32`,
`crc64[]`?/`crc16[]`? tables). All algorithms are **hand-rolled Dart**, `xxh3` is actually
**XXH64** (mislabel), and the `Native` path is only stubbed.

## 3. Gap analysis

| # | Item | Status | Severity |
|---|---|---|---|
| G1 | `Hash.sha256(File)` — the exact one-word noun (09:19) | `sha256(String ⁄ List<int> ⁄ Uint8List)` — passing a `File` **throws** (`ArgumentError`: unknown type) | **BLOCKER** |
| G2 | `Hash.sha256.writer()` IS a `Writer` | `AlgoWriter.write` exists but **does not `implements Writer`**; `File('x').pipe(Hash.sha256.writer())` is dead syntax | **BLOCKER** |
| G3 | Digest internals native (FFI) with Dart fallback | ✗ pure Dart (slow); `Native` branch is a stub | **BLOCKER** (native) |
| G4 | **`xxh3`** gives real XXH3-128 when chosen (dedupe key) | ✗ labelled xxh3 but computes **XXH64**; `$lib` dedupe must not use it | **BLOCKER** |
| G5 | `hex`, `b64`/`base64` encoded variants of any bytes | partial: `hex`/`b64` exist; `base64` noun alias missing | MINOR |
| G6 | `mac`/`hmac`/`checksum` full parity | `hmac` ✓ (HMAC-SHA family); `mac(...)` pbkdf2-ish pass exists | MINOR |
| G7 | `forge(node,vob)` digests / `Algo`-family forge | partial surface | MINOR |
| G8 | `crc32` streaming? one-shot ✓ | one-shot ✓ | ok |
| G9 | Errors: `Base64DecodeException`-family (r15 table entry) | ✗ `FormatException` reused | MINOR |
| G10 | `verify`/`check` compares in constant time | depends on impl — must confirm no early-out | MAJOR (security) |
| G11 | one-shot reading of `File` | `sha256(String)` of file *contents* works, but the noun `sha256(file)` is the miss (G1) | see G1 |

## 4. Native requirements (`native2`)

**Highest-value native rewrite (hashes are small and hot).** Legacy `native/src/digest.rs` is
the parity reference: `tk_digest_*` (sha1/sha256/sha512/md5/xxh — *real* xxh3 available),
`tk_mac_new`, `tk_hmac`, `crc32` are reimplemented in `native2/engine` and differential-tested
against it.

- Rewire `AlgoWriter.write → tk_digest_new/update/finish` with the standard stop byte; the
  pure-Dart fallback exists only until cutover, then is deleted (r50) — never fork the algorithm set.
- `xxh3` returns the true `xxh64` + `xxh128` pair; the storage form must include a **digest kind
  tag** so `$lib` dedupe never mixes XXH64 and XXH3.
- The rest (`hex/base32/crc32/b64`) stays Dart — no native needed, but the FFI can carry `crc32`.
- `HashStream` (a `Reader` wrapping a stream) feeds `pipe` — a *native-agnostic* streaming seam.

## 5. Actionable specification

1. **`Instance of File → bytes` in every one-shot:** `sha256(File)` streams via a chunked `read`
   loop (no `readAsBytes` whole-file) — honors G1 and keeps the 1 GiB test linear. Accept
   `File`/`String`/`Uint8List`, everything else `ArgumentError` (r26).
2. **Make `AlgoWriter` implement `Writer`** (r1 shape): `write(Object)` chunk, `flush` no-op, and a
   `digest()` terminal method (kept distinct from `close()` so a digest can be piped-into a file
   and still be read). Add `Hash.sha256` + `.writer()` factory mirroring the proposal noun.
3. **Native digest binding (rewrite):** `tk_digest_new(tag)` → handle; `tk_digest_update(h, ptr,
   len)`; `tk_digest_finish(h, out(32)) ways`; `tk_digest_free`, reimplemented in
   `native2/engine` and parity-tested against legacy. `Hash.sha256(file)` uses the rewritten
   algo; the Dart fallback is deleted at cutover; verify `xxh128`.
4. **Get `xxh3` correct:** switch the `xxh3` label to real XXH3; add `Hash.sha256.writer()`-style
   `Hash.xxh3.writer()` for `$lib`; document the XXH64 nuance in CHANGELOG.
5. **Constant-time `checksum`/`verify`:** implement `_ct_eq(Uint8List a, Uint8List b)` (xor-accum
   over max len, no early exit) and use it everywhere a user checks a digest (G10).
6. **Error nouns:** add `DigestException`-adjacent typed errors per r15 only where a caller can
   reasonably distinguish; keep `FormatException` for base64.
7. **Tests** (`test/hash_test.dart` for lib2): `sha256(File)` == `sha256` of its bytes; the
   `pipe` form `makeFile.pipe(Hash.sha256.writer()) → digest == sha256(bytes)`; `xxh3` corpus
   vectors (and XXH64 no longer used by `$lib`); `ct_eq` sanity; HMAC known-answer; streaming a
   16 MiB file stays linear; rewritten-vs-legacy byte parity across sha1/224/256/384/512, md5, xxh3.
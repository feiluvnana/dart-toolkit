# Report · Archive (`lib/lib2/src/archive/archive.dart`)

> Companion spec: [`../proposals/06_archive.md`](../proposals/06_archive.md).

---

## 1. Proposal promise (06:5–110)

- `Archive.pack(dir).pipe(File('bundle.tar'))` — streaming `tar|tar.gz|zip` from a directory;
- `Fire.zip(dir, '…')`/`Fire.tv(dir)`-style one-shot helpers;
- `Archive.unpack(dst: 'out')` — **streaming**, full-dir from a `Reader` (the
  `Http.get(...).pipe(Archive.unpack(dst: 'out'))` example, 00:59);
- `unpack(file, dst:)` convenience; selective **single-member streaming** (the proposal's "open" —
  open a member and stream it out);
- `TarStepper`/`ZipStepper` natural walkers (06:89) feeding `chan`/`pool`/`TarJob`;
- **$lib archive format** — 16-byte footer, deduplicate, 5× cached speed (PLAN.md).

## 2. Current `lib2` state

`lib/lib2/src/archive/archive.dart` (388 lines): pure Dart — `Archive.format(path|data)` (no `$lib`,
no tar), `Archive.pack(dir)` (zip/tar/tar.gz), `Archive.unpack(Reader, dst: true)`,
`Archive.create(dir, format, dst:)`, `Archive.read` (tar/zip **to memory**), `Archive.list`
(metadata), and `ZipMember`/`TarEntry` records for the legacy `$lib` archive. **`extract`/`open`
for a single member do not exist.**

## 3. Gap analysis

| # | Item | Status | Severity |
|---|---|---|---|
| G1 | `unpack(file, dst:)` — file-style | only `unpack(Reader, dst:)` — fine to alias; add the `File`/path overload | MINOR |
| G2 | **Streaming `unpack`** — `pack(...).pipe(unpack(dst:))`, `Http…pipe(unpack(dst:))` | ✗ `unpack` reads the **whole archive** to memory (`_readZip`/`_readTar`), then extracts from `List<Uint8List>`; a 4 GiB zip needs absurd RAM | **BLOCKER** |
| G3 | Zip **zip-slip** / `..` traversal | ✗ `unpack` joins entries to `dst` with **no `resolve().starts()` sandbox** (`io_fs.md` G7): `../../evil` writes outside `dst` | **BLOCKER** (security; r15 → `SecurityException`) |
| G4 | Symlink/hardlink entries in tar | ✗ treated as regular files (or unsupported) | MAJOR |
| G5 | Single-member `extract`: `Archive.open('bundle.tar', 'inner.txt').pipe(file)` | ✗ absent; read-all only | **BLOCKER** |
| G6 | Sequential `TarStepper`/`ZipStepper` for `TarJob` pipelines (06:89) | ✗ absent | MAJOR |
| G7 | tar.gz, tar.bz2, tar.zst | tar.gz ✓; **tar.zst ✗** (zstd streaming absent; `Zstd` sample exists but not wired), bz2 ✗ | MAJOR (zstd → native) |
| G8 | `create(dir, format, dst:, exclude:)` | ✓ zip/tar/tar.gz + `exclude:` | ok (perf via native below) |
| G9 | Round-trip: unpack(pack(d)) ≡ d byte-for-byte | ✗ no self-test | MINOR |
| G10 | Large-member support (>1 GiB members) | ✗ whole-file | see G2 |
| G11 | `$lib` proprietary archive (16-byte footer, dedupe) | ✗ only recognises the format name; `read` handles tar/zip | MAJOR (PLAN.md Phase 6) |
| G12 | Member metadata (sizes for progress) | `list` gives it; extraction progress absent | MINOR |

## 4. Native requirements (`native2`)

**Archive is propositionally the deadline flagship native module.** The legacy engine's
single-shot in-memory fns (`native/src/archive.rs`) are the parity reference:
`tk_archive_format`, `tk_archive_list`, `tk_archive_read`, `tk_archive_contents`,
`tk_archive_create`, `tk_archive_compress`, `tk_archive_extract`. native2 rewrite
(native2_architecture.md §5):

1. Replace single-shot with a **stepper/handle** model: `ChunkReader`/`ChunkWriter` callbacks carry
   the entry name, size, crc, and the **stop byte**. `tk_archive_open_zip/tar/tar.gz` →
   `tk_archive_next_entry` → read loop; that is `TarStepper`/`ZipStepper` native-side.
2. **`tk_archive_extract_member`** returns the member already `sandbox`-joined (Dart passes `root`;
   native canonicalises with full NSIS/`VarArgs` semantics) — the zip-slip gate lives in native AND
   Dart (defence in depth).
3. **`zstd`:** add `tk_zstd_decompress_stream` beside the existing `tk_decompress`/`inflate` —
   buys `tar.zst`.
4. **`$lib`** is PLAN.md Phase 6 (not the lib2 proposal's target): native writer with a queue of
   (path, dedup-hash) and the 16-byte footer.

Dart keeps `pack`'s **directory walk + `exclude:` filtering + perms**, then delegates per-entry
streaming to the native writer (also fixes tar.gz determinism).

## 5. Actionable specification

1. **Security first (Phase A — pure Dart, land now):** in `unpack`, for *every* entry compute the
   resolved target and enforce `target.startsWith(dst)` (canonical, casefolded on Windows) with
   `final out = await file.absolute.normalize(); if (!out.startsWith(root)) throw SecurityException('zip-slip: $raw')`
   (r15). Reject `..`, absolute members, and entries escaping `dst`; refuse symlink/hardlink
   entries pointing outside. Add `test/archive_security_test.dart`: a crafted `../../evil.txt` zip
   must write nothing and throw exactly `SecurityException`.
2. **Steppers (Phase B — Dart-only):** implement `TarStepper`/`ZipStepper` as Reader-based
   sequential readers (no random access) exposing `open(name)/next/close`, then build
   `Archive.open(bundle, member).pipe(File('out'))` on top. Satisfies G5+G6.
3. **Streaming unpack (Phase C — native):** wire the `tk_archive_*` handle API so `unpack(Reader)`
   extracts entry-by-entry, honouring the stop byte mid-member; RAM ceiling proves G2/G10 fixed.
4. **`zst` (Phase D):** `tk_zstd_decompress_stream` → `tar.zst` unpack; packing `tar.zst` can defer.
5. **Round-trip gate (G9):** `unpack(pack(d))` equals `d` byte-for-byte in the CI suite; `pack →
   list` sizes match disk.
6. **Acceptance:** proposal 06:89 `TarJob` pipeline (stepper → chan → pool hash/read workers) as a
   lib2 integration test; the 00:59 `Http.get('bundle.tar').pipe(Archive.unpack(dst:))` example
   runs end-to-end against a local server.
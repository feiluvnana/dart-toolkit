# Report · Image (`lib/lib2/src/image/image.dart`)

> Companion spec: [`../proposals/08_image.md`](../proposals/08_image.md).

---

## 1. Proposal promise (08:5–130)

- `Image.read(path|bytes)` / `Image.decode(bytes)` → an `Image` (`w×h, rgb`);
  `Image.pic(bytes, w, h)` board/pixel from raw bytes.
- `img.fit(h|w|w×h)` — smart resize (scale + crop, `cover`/`contain`), `scale`, `blur`,
  `draw`/watermark, `save(path, quality:)`; `imagine`, `prerosion`, `posterise`, `sharpen`,
  `sobel`, `invert` (0.0.2 leg).
- **Formats on save**: `png`, `jpg` with `quality` (08:60–70, PNG ignored), **`webp`**, **`qoi`**;
  `format: 'png'|'jpeg'|'gif'|'webp'|'qoi'` and `color: 'rgb'|'rgba'` defaults (08:70).
- `Image.load()` as a `Writer` sink — `File('x.png').pipe(Image.load()); img.pipe(...)` (00:64–72,
  08:9–10): the pipe-centric image pipeline.
- `Page.shot()` (chrome) feeds `Image.decode` (08:84).

## 2. Current `lib2` state

`lib/lib2/src/image/image.dart` (267 lines): pure-Dart `Image` + `ImageData{bytes, w, h, stride}`,
`Image.load(bytes)` (decode **PNG only**, hand-rolled `inflate` fallback), `Image.read(file)`,
`scale`/`fit`/`sharpen`/`sobel`/`invert`/`posterise` (are single-pass neighbourhood ops),
`Image.save(path, Image, ? , quality:)` — **PNG-only encoder, `quality:` is accepted and ignored**.
`blur`, `draw`, `webp`, `qoi`, and `imagine` are **absent**.

## 3. Gap analysis

| # | Item | Status | Severity |
|---|---|---|---|
| G1 | **Decode jpeg/gif/webp/qoi** | ✗ PNG only; the rest throw | **BLOCKER** |
| G2 | **Encode jpg (quality:), webp, qoi** | ✗ PNG only; `quality:` ignored | **BLOCKER** |
| G3 | `Image.load()` AS a pipe **Writer** sink (`File('x').pipe(Image.load())`, then `img.pipe(File)`) | ✗ `load` is a function — the `pipe`-noun API is absent | MAJOR |
| G4 | `fit(400, 300)` cover/contain smart resize | ✓ `fit` exists (needs cover/contain parity check) | MINOR |
| G5 | `scale` (up and down), `blur`, `draw` | `scale` ✓; `blur`/`draw` ✗ | MAJOR |
| G6 | `invert`, `sharpen`, `sobel`, `posterise` ops | ✓ present | ok |
| G7 | `prerosion` / `imagine` (TF-lite) | ✗ | MINOR |
| G8 | `ImageData` raw `rgb`/`rgba` with stride | ✓ | ok |
| G9 | Screenshot decode: `Image.decode(page.shot())` | ✓ (PNG from Chrome) — only because Chrome emits PNG | ok today, breaks if Chrome switches |
| G10 | Memory ceiling on big images | decodes whole file to `Uint8List`, then to RGBA — unavoidable, but native can keep PNG decoding off the Dart heap | see native |
| G11 | `Image.save` returns written size + accuracy of `quality` on PNG (must be ignored, documented) | ✗ unknown; verify | MINOR |
| G12 | Format detection from magic bytes (`format(data)`), error via `or:` when unknown | ✗ absent | MINOR |

## 4. Native requirements (`native2`)

**Flagship-deadline native module** (proposal list has image; `native/src/image.rs` is the parity
reference for the `tk_decode_*`/`tk_encode_*` primitives). native2 rewrite (native2_architecture.md §5):

1. **Delegate decode + encode, keep ops in Dart.** `tk_image_decode(bytes, fmt)` → RGBA buffer +
   w/h/stride; `tk_image_encode(rgba, w, h, fmt, quality)` → encoded wrap (u8 slice → `wrap`).
   This buys `jpg (libjpeg-turbo), webp (libwebp), qoi, png (miniz/fpng)` without a Dart codec.
2. **The pipe form** `Image.load()` becomes a `Writer` coupler: `write` frames push into a
   `tk_image_decode` handle (partial-callback bail), canned in `BufferWriter`; on `close`, await
   the decoded `Image`. `img.pipe(dst)` reuses the same encode handle in reverse.
3. `tk_image_scale`/`tk_image_blur` *can* be native for perf, but are **optional** — Dart's
   neighbourhood ops stay until someone measures. `sobel`/`invert`/`posterise` stay Dart.

## 5. Actionable specification

1. **Phase A (pure Dart, immediate):** implement JPEG + QOI minimum via reference ports OR — 
   better — start from native immediately (Phase B) since `native/src/image.rs` exists; in either
   case add:
   - `blur(radius)` (box-blur sweep, RGBX in place, radius clip),
   - `draw(Image, at:, over:)` watermarks with alpha-, and
   - `format` auto-detect (`ensureOrThrow` + `or:` path).
2. **Phase B (native decode/encode):** land `tk_image_decode`/`tk_image_encode` bindings first for
   **jpg + webp** (the two the proposal's tests use), keep PNG on the existing Dart path until the
   native one is equal; then flip `format: 'png'|'jpeg'|'gif'|'webp'|'qoi'` switch to native for
   all five. Wire `quality:` only into jpeg/webp; PNG ignores it (documented, G11).
3. **Phase C (pipe sink):** implement `Image.load()` as the `Writer` (G3) so the proposal's pipe
   examples (00:64, 08:9) run verbatim; `Image.save` keeps returning written-size for
   `Progress`.
4. **Acceptance (** `test/image_test.dart` for lib2): decode each of png/jpg/gif/webp/qoi round-trips
   (encode→decode identical dimensions); `fit(400,300)` on a 1920×1080 shot yields 400×300 and
   correct `cover` crop; `blur` of a solid image is solid; watermark composite leaves pixels; the
   pipe form `File('x.png').pipe(Image.load())` then `image.pipe(File('thumb.webp'),
   quality: 80)` produces a valid webp; `format` on unknown bytes → `FormatException`. Use the
   legacy `image_test.dart` corpus fixtures.
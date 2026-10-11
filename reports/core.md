# Report · Core: Base Traits & the `pipe` Spine (`lib/lib2/src/core/`)

> Companion spec: [`../proposals/00_architecture.md`](../proposals/00_architecture.md) — the
> "Rust-like base interfaces" and the cross-module piping that is the proposal's integrative idea.

---

## 1. Proposal promise (00:12–51)

```dart
abstract interface class Reader { Future<int> read(Uint8List buf); }
abstract interface class Writer { Future<int> write(Uint8List buf); Future<void> flush(); }
abstract interface class Closer  { Future<void> close(); }
abstract interface class Seeker  { Future<int> seek(int offset); }
Future<int> pipe(Reader src, Writer dst, {int buf = 64*1024});
```

and the headline integrations (00:59–72):

```dart
await Http.get('https://…/file.zip').pipe(File('data.zip'));
await Http.get('…/bundle.tar').pipe(Archive.unpack(dst: 'out'));
await Process.run('git', ['log']).pipe(File('git.log'));
final img = await File('photo.jpg').pipe(Image.load());           // Image.load() as a sink?
await img.fit(400, 300).pipe(File('thumb.webp'));                 // Image as a Reader?
```

The 1-word naming table (00:76–92) pins `read/write/pipe/get/post/parse/find/run/pack/unpack/
load/save/sha256/open/click/type/shot/run/draw/poll/box/ask/bar/print`.

## 2. Current `lib2` state

- `lib/lib2/src/core/traits.dart` — `Reader`, `Writer` (`write(Object)` — takes String/List<int>/
  Uint8List, not `Uint8List`), `Closer`, `Seeker` ✓ (with one drift: `Writer.write` is looser than
  the proposal's `Uint8List`).
- `lib/lib2/src/core/pipe.dart` — `pipe`, `ReaderPipe` (`src.pipe(dst)`), `BytesPipe`
  (`Uint8List.pipe`), `AwaitableBytesPipe`, `BufferReader`, `BufferWriter`.

## 3. Gap analysis

| # | Item | Status | Severity |
|---|---|---|---|
| G1 | `Http.get(url).pipe(File(...))` — a `Resp` that IS a `Reader` | ✗ `Resp` buffers `body`; no `read` | **BLOCKER** (fix in `http.md` G1) |
| G2 | `… pipe(Archive.unpack(dst:))` — an unpack destination as a `Writer` | ✗ unpack reads whole files | **BLOCKER** (`archive.md` G2) |
| G3 | `Process.run(...).pipe(File(...))` / `p1.pipe(p2)` | ✗ `Process` not a `Reader`/`Writer` | **BLOCKER** (`process.md` G1) |
| G4 | `File('photo.jpg').pipe(Image.load())` and `img.pipe(File)` | ✗ no such sinks; `Image` is an in-memory raster | MAJOR (`image.md`) |
| G5 | `page.shot().pipe(File(...))` (proposal 11:3) | works only as `(await page.shot()).pipe(...)`; a `shot()` returning an awaitable `Reader` is the clean form | MAJOR (`browser_chrome.md` G7) |
| G6 | `Hash.sha256.writer()` as a `Writer` (10:2) | `AlgoWriter.write` exists but **does not implement `Writer`** and its `pipe(hasher)` promise fails | **BLOCKER** (`hash.md` G5) |
| G7 | `Seeker` honoured by consumers | `pipe` never seeks; `File` **does not implement** `Seeker` (it tracks `_readPos` privately); range-resume (http.md G4) cannot reuse a half-read `File` | MAJOR |
| G8 | `Writer.write(Uint8List)` (00) vs `write(Object)` (impl) | drifted from the proposal signature; `BufferWriter` accepts anything and `utf8.encode(...toString())` stringifies — error-prone | MINOR (keep `Write(String|List<int>)` pragmatic, but make `Object`-typing explicit) |
| G9 | Named convention table (00:76) | `TextNode/Element.find/all`, `Doc.find/all` ✓; nouns that drifted are fixed module-by-module (`open`, `html()`, `type`, `shot`, `draw`, `poll`, `box`) | cross-cutting |
| G10 | The proposal's example `pipe` returns total bytes | ✓ returns `int`; `onProgress(total)` ✓ | ok — but `onProgress` is a **callback**, which CONVENTIONS r1 forbids as a status source; keep as a *display* convenience only (document) | MINOR |
| G11 | `BufferReader`/`BufferWriter` exist for tests | ✓ | ok |

## 4. Native requirements

`native2` consumes the traits through **callback pairs** (`read_fn/ctx`, `write_fn/ctx`,
native2_architecture.md §4.3). Dart additions required before wiring native:

- `FnReader(Reader)` and `FnWriter(Writer)` adapters that expose the underlying object as
  `dart:ffi`-callable callbacks (or a single `_FfiBridge` helper in `pipe.dart`).
- A `handle`-style `Writer` for native sinks: `HashWriter`, `ArchiveUnpackSink`,
  `ImageDecodeSink`, `CdpShot/WsSink` — each is a thin Dart `Writer` whose `write` pushes into the
  native handle's `write_fn`. All native sink writers report through the `Work`/`Status` model
  (r1/r7), not callbacks.

## 5. Actionable specification

1. **Tighten `Writer`:** keep `Future<int> write(Object data)` but give it a precise contract:
   `String` → UTF-8; `List<int>`/`Uint8List` → verbatim; anything else → `ArgumentError`. Make
   `BufferWriter`/`FileWriter`/`AlgoWriter`/`Resp` conform without stringifying.
2. **Add `Seeker` to `File`:** `Future<int> seek(int offset)` shifting `_raf` position (reuses
   `RandomAccessFile.position = offset`); wire `Http.download(resume:)` to it (`http.md` G4).
3. **Add the adapter pair** in `pipe.dart` (pure Dart, no FFI yet):
   `final class FnReader implements Reader { final int Function(Uint8List) _cb; … }` plus the
   native-facing variant used by `native2`.
4. **Cross-module acceptance tests** in `test/pipe_test.dart` (lib2):
   - download-to-file with a 1 MiB synthetic body (buffered response is OK for now, streaming later);
   - `BufferWriter ← ChanProducer` backpressure demo;
   - `AlgoWriter ← pipe` sums a digest correctly;
   - `File` seek + read resume produces the identical tail.
5. **Naming audit gate:** after the module fixes, run a `lib2`-flavoured `api_names_test.dart`
   asserting the 00:76 table verbatim, so `open/html/type/shot/draw/poll/box/ask/bar/print`
   cannot drift again.
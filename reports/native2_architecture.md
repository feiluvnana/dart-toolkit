# Report · `native2` Architecture (Native Integration Redesign)

> Companion: [`../proposals/13_plan.md`](../proposals/13_plan.md) (Option B — Rust core engine),
> [`../proposals/00_architecture.md`](../proposals/00_architecture.md) (base interfaces).
> This report is the binding architecture a coding agent implements before module-by-module wiring.

---

## 1. Why `lib2` needs a native layer at all

The current `lib2` is **pure Dart**. Measured against the proposal, every heavy module either
silently underperforms or cannot exist:

| Module | `lib2` today | Proposal (00:7, 13:Phase 5) | Consequence |
|---|---|---|---|
| Hash | Hand-rolled Dart SHA-256/512, MD5, BLAKE3, XXH64-as-xxh3 | Native digests, zero-copy streaming, file hashing | 5–50× slower; no file streaming; `xxh3` is actually XXH64 |
| Archive | Whole-file Dart ZIP/TAR/gzip in a `Map` | Native zip/7z/rar/tar/gz/xz/zst/bz2, streaming, encrypted, selective | ZIP only; tar.zst missing; no streaming; **zip-slip**; memory = archive size × 2 |
| Image | Dart RGBA + hand-rolled PNG codec | Native SIMD codecs: JPEG/WebP/PNG/QOI + transforms + `compress` | PNG-only in/out; `blur`/`scale`/`draw`/`info` missing |
| Chrome | Dart `HttpClient`+`WebSocket` CDP | Native CDP client (`tungstenite`/`chromiumoxide`) | Launch/tree-kill not managed; no `pdf`, no `type` |
| TUI | `Ui` prints a String | Native `ratatui`+`crossterm` raw-mode double-buffered app | No events, no layout, no alt screen at all |
| Process | `dart:io` only | Native tree-kill (Windows Job Objects) on timeout/cancel | Grandchildren outlive a stop |
| FS | `chmod` **spawns `/bin/chmod`** | `tk_chmod` FFI; native copy with progress+stop | A process spawn per `chmod`; copy not cancellable |

`native2` answers all of it from one coherent C-ABI design.

---

## 2. Design goals (binding)

1. **`lib2` stays pure-declarative in Dart.** Dart owns types, control flow, the error table and
   the `Reader`/`Writer`/`Task`/`Status` model. `native2` owns bytes, codecs, kernels and raw
   device I/O. No Dart fallback — without the library the calls are `UnsupportedError`
   (CONVENTIONS §8 r50).
2. **One handle protocol.** A long-lived opaque `*mut c_void` (`Handle`), created by an `…_new`,
   released by an `…_free`, protected by a `NativeFinalizer` in Dart. Streams and state machines
   resume through the same handle (Rust `Box` is never leaked).
3. **Cancellable long work only, on a worker, with a stop byte.** No FFI call on the caller that
   can run long. The stop-flag/watch (`Watch`), progress callback and `STOPPED` contract are
   reimplemented in `native2/common` to the same semantics; the legacy
   `native/common/src/lib.rs` is frozen reference material, shares no code with the rewrite,
   and is deleted at cutover.
4. **One ABI per reader/writer.** Every `…_new` that touches a Dart `Reader`/`Writer` takes paired
   C callbacks (`read_fn, read_ctx`) / (`write_fn, write_ctx`) so a native engine can pull from or
   push into a Dart stream without copying whole buffers into Rust.
5. **Per-subsystem cdylibs** honour the startup budget (§9 r56): `dart_toolkit_native` (core data
   modules), `dart_toolkit_chrome`, `dart_toolkit_tui`, `dart_toolkit_torrent`. Each embeds
   `tk_common::exports!(N)` and version-gates its own ABI from 1. `torrent` stays its own
   library — `chrome`/`tui` follow the pattern.
6. **Errors map at the boundary.** Every export returns `i32` (≤0 = error), leaves the message in
   `tk_last_error`, and the Dart side maps `"cancelled"` → `CancelledException`, `"…"` = OS text →
   `NativeException` with the subject named first (r15/r16).
7. **No third-party runtime in Dart; Rust crates only for subsystems that need them:** `ratatui`
   + `crossterm` (TUI), `tungstenite` + `serde_json` (CDP), and the existing vendored codecs in
   `native/src/` (mozjpeg, unrar, zstd, xz, bz2, zlib-ng).

---

## 3. Boundaries of responsibility (`native2` drives these)

### 3.1 Must be native (the proposal's "heavy lifting")

| Subsystem | Required FFI surface (rewritten; parity with legacy) | Proposal ref |
|---|---|---|
| Digests / MACs | `tk_digest*`, `tk_mac_new`, `tk_hmac`, `tk_digest_files` (rewrite — byte-parity with `native/src/digest.rs`, real XXH3) | 10:1–4 |
| Archives | `tk_archive_format/list/extract/read/create/compress/decompress`, `tk_archive_contents*` (rewrite — parity with `native/src/archive.rs`), plus the new streaming unpack sink | 06:1–4 |
| Image engine | `tk_image_load* / probe* / resize / crop / rotate / flip / pad / trim / adjust / grayscale / invert / sepia / blur / sharpen / denoise / vignette / composite / watermark / mask / draw_text / encode_memory / compress / similarity / crop_smart / grid / png` (rewrite — parity with `native/src/image.rs`) | 08:1–4 |
| Chrome CDP | **new** `chrome` crate: launch/attach, WS connect, `cmd`/event pump, page tree | 11:1–4 |
| TUI | **new** `tui` crate: `ratatui` frame buffer, `crossterm` raw mode/alt screen, diff render, event poll, clipboard/paste | 12:1–4 |
| Content decode | `tk_inflate*`, `tk_decode_text`, `tk_decompress` (rewrite — parity) | http/html/fs feeding |
| Torrent engine | `tk_torrent_*` (rewrite into `native2/torrent`) | legacy |

### 3.2 Must be driven by native (system interactions; partial in Dart today)

| Interaction | `lib2` fallback (until cutover) | Rewritten in `native2` |
|---|---|---|
| `chmod` | `io.Process.run('chmod', [...])` — process spawn, Windows no-op | `tk_chmod` reimplemented (same Windows read-only-bit semantics) |
| Copy file w/ progress+stop | `io.File.copy` — no progress, not cancellable | `tk_copy_file` reimplemented (source perms, removes dest on failure/stop) |
| Cheap identity/existence | — | `tk_file_id` reimplemented; claimed-name locks `tk_claim/tk_unclaim` reimplemented |
| Atomic rename over Windows-held target | Dart retry loop on error 5/32 | `tk_rename` retry loop over `MoveFileExW`, specified here first |
| Process tree termination (Windows Job Objects, POSIX process groups) | `kill()` on one pid | new `tk_process_kill_tree(pid)`, `tk_process_register_child` in the new `process` crate |
| Terminal raw-mode VT input, `chcp` code page | none in `lib2` | `tui` crate (§6) |
| Browser alive-check / profile steal | polling HTTP | `chrome` crate (§7) |

---

## 4. Handle, worker and callback protocol (the concrete contract)

### 4.1 The handle

```c
// new: allocates the object, no long work.
void*  tk_x_new(...);            // never null-checked by caller; failure -> NULL + tk_last_error
// stream/state calls: return 0 / -1 / -2 (panic); do NOT block the caller past a slice.
int    tk_x_do(handle, ...);
// free: blocks until any worker on this handle is quiesced; idempotent; NULL-safe.
void   tk_x_free(void* h);
```

Dart side wraps it exactly like the legacy `NativeHandle` (lib/src/native/native.dart) does:
`NativeFinalizer` on the owner object, `close()` waits for in-flight work, a `StateError` for use
after close.

### 4.2 Long work (`WorkerThread`)

```
Dart                     native2
----                     ------
worker.enqueue(call) ->  channel -> worker thread
                             |   runs kernel with `Watched<R>` reader
                             |   every N chunks -> progress_cb(done, total)
                             |   checks stop byte each chunk
stop flag set by caller ->  `stopped()` -> Err("cancelled") -> -1
                             result written to caller buffer / `give()` allocation
```

- One worker thread per `NativeHandle` family (digest worker, archive worker, image worker), set
  up lazily — never a thread per call.
- `Worker` (lib2 `async` module) is the Dart-side owner of these queues; a `Task.cancel()` sets the
  stop byte and `await`s the worker, never kills it mid-call (r53).

### 4.3 Reader/Writer crossover (the `pipe` spine)

A native subsystem that must read a Dart `Reader` or write a Dart `Writer` receives:

```c
typedef int  (*read_fn)(void* ctx, unsigned char* buf, int cap);   // bytes read; 0 = EOF; <0 = Dart error
typedef int  (*write_fn)(void* ctx, const unsigned char* data, int len);
void* tk_x_new(..., read_fn r, void* rctx, write_fn w, void* wctx);
```

Dart implements these callbacks from the `Reader`/`Writer` it already holds
(`FnReader`, `FnWriter` in `lib2/src/core/pipe.dart`). This is what enables:
`Http.get(url).pipe(Archive.unpack(dst:))`, `page.shot().pipe(File(...))`,
`Hash.sha256.writer().pipe(resp)`, `Image.load(resp)`, in zero-copy chunks and with true
backpressure.

---

## 5. Crate layout (what to create in `native2`)

```
native2/                      (greenfield workspace; shares no code with native/)
├── Cargo.toml                workspace: members = common, engine, chrome, tui, torrent
├── common/                   NEW — tk_common rewritten (exports!, guard, bytes, handle, stop, Msg)
├── engine/                   NEW — the rewritten engine crate:
│   ├── lib.rs                tk_chmod/tk_copy_file/tk_file_id/tk_claim/tk_unclaim/tk_rename
│   ├── process.rs            NEW — tk_process_kill_tree/tk_process_register_child
│   ├── archive.rs            rewritten — with the streaming unpack-sink + packed-stream create
│   ├── digest.rs / pieces.rs / inflate.rs / text.rs   rewritten — parity with legacy
│   ├── image.rs              rewritten — parity with legacy
│   └── font8x16.bin          copied asset (data, not code)
├── chrome/                   NEW — cdylib `dart_toolkit_chrome`
│   ├── Cargo.toml            tungstenite, serde_json, dirs, libc
│   └── src/{lib,cdp,launcher,keymap}.rs
├── tui/                      NEW — cdylib `dart_toolkit_tui`
│   ├── Cargo.toml            ratatui, crossterm, serde_json
│   └── src/{lib,app,layout,term,events,diff}.rs
└── torrent/                  NEW — cdylib `dart_toolkit_torrent`, engine rewritten
```

ABI table (each rewritten library starts at 1; the legacy versions are deleted at cutover,
so no stale-lib confusion — CONVENTIONS §8 r52 applies from here on):

| Library | Legacy ABI (deleted) | `native2` ABI |
|---|---|---|
| `dart_toolkit_native` | 14 | 1 (new export table: `tk_rename`, `tk_process_*`, streaming sinks) |
| `dart_toolkit_torrent` | 3 | 1 |
| `dart_toolkit_chrome` | — | 1 |
| `dart_toolkit_tui` | — | 1 |

---

## 6. `tui` crate FFI (summary; full spec in `tui.md`)

```c
// lifecycle
void* tk_tui_start(int width_hint, int height_hint, int rgb);   // alt screen + raw mode via crossterm
int   tk_tui_loop(void* h, void* state,                         // runs the app loop on its worker
                  int (*draw)(void* ctx, struct tk_frame* out), // Dart builds the widget tree -> frame
                  int (*on_event)(void* ctx, const struct tk_event* e, int64_t* out_next_tick_ms));
int   tk_tui_stop(void* h);
void  tk_tui_free(void* h);
// frame = packed buffers:
//   cells:      [r,g,b, attr_flags, codepoint_utf8_len, ...]
//   diffs:      list of (row, col, len, cell_idx) to repaint
// input
int   tk_tui_poll(void* h, struct tk_event* out, int ms);      // non-blocking with timeout
struct tk_event { int kind; int key; int chr; int row; int col; int mods; }; // kind: key/mouse/resize/paste/sig
```

Rationale — **hybrid, not hostile**: `ratatui` renders and diffs on the worker; the *widget
tree* is declared in Dart (dead-simple `draw(ui)`), serialised into `tk_frame`, and native2 only
paints the diff. This keeps the proposal's one-word Dart surface while the heavy flicker-free
rendering and raw terminal I/O live in Rust. Aspect ratio and Unicode width live on the Rust side
(the source of truth for the terminal).

---

## 7. `chrome` crate FFI (summary; full spec in `browser_chrome.md`)

```c
// launch/attach return a Browser handle + a discovered debug URL
void* tk_cdp_launch(const u8* exe, int headless, const u8* profile_dir, const u8** extra_args, int argc,
                    int* out_port);
void* tk_cdp_attach(const u8* ws_url);
// per-page commands, all through one event pump on a worker:
int   tk_cdp_open(void* b, const u8* url, void** out_page);       // waits for the load event
int   tk_cdp_eval(void* p, const u8* expr, u8** out_json, usize* out_len);  // give()-allocated
int   tk_cdp_shot(void* p, int full, u8** out_png, usize* out_len);
int   tk_cdp_pdf(void* p, int landscape, int format, u8** out_pdf, usize* out_len);
int   tk_cdp_type(void* p, const u8* sel, const u8* text, int humanize_ms);
int   tk_cdp_click(void* p, const u8* sel, int x, int y);
int   tk_cdp_wait(void* p, const u8* sel, int ms);
int   tk_cdp_alive(void* b);                        // OpenProcess + GetExitCodeProcess on Windows
void  tk_cdp_free(void* b);
```

The Rust side owns the WebSocket (tungstenite), the id→completer map, event dispatch to the Dart
`listen`/`wait` streams, and `--user-data-dir` profile lifecycle + reaper.

---

## 8. What `lib2`'s Dart side becomes (the mapping)

| `lib2` module | Dart surface | Backed by (native2) |
|---|---|---|
| `core` (§1) | `Reader/Writer/Closer/Seeker`, `pipe` | pure Dart + `FnReader/FnWriter` shims |
| `fs/io.dart` | `Path/File/Dir/Link`, atomic, chmod, copy, rename | `tk_chmod`, `tk_copy_file`, `tk_file_id`, `tk_rename`, claims |
| `async` | `Task/Pool/Chan/Worker` | worker queues + stop bytes (r53) |
| `archive` | `Archive.pack/unpack/list/extract/Zstd` | `tk_archive_*`, streaming sink |
| `hash` | `Hash.*`, `Mac`, `writer()`, `Hex/Base64` | `tk_digest*`, `tk_digest_files`, `tk_hmac` |
| `image` | `Image.load/fit/crop/save/info/scale/blur/draw` | `tk_image_*` |
| `http` | `Http`, `Resp extends Reader` | Dart `dart:io` + native content decode (`tk_inflate`, `tk_decompress`) |
| `process` | `Process.run/lines/interact`, tree-kill | `tk_process_kill_tree` |
| `chrome` | `Chrome.launch/connect`, `Page.*` | `dart_toolkit_chrome` |
| `tui` | `Tui.run/draw/poll`, widgets | `dart_toolkit_tui` |
| `cli` | `ask/confirm/choose/bar/spin` | stays Dart; draws via `tui`'s live region when region-permitted |

---

## 9. Build & release

- `make native` builds the four rewritten cdylibs from `native2/` via
  `tool/build_native.dart` (reuse the existing cross matrix: macos_*, linux_*, windows_x64);
  the legacy `native/` tree is frozen and is deleted at cutover.
- Each `native2/` source change bumps its `exports!` version from here on;
  `make native-release` uploads `dart_toolkit_native-<hash>`, `dart_toolkit_chrome-<hash>`,
  `dart_toolkit_tui-<hash>` + `.sha256` to the release named by the `native2/` source hash
  (CONVENTIONS §8 r51). `Native.install()`/`Native.check()` switch to the new libraries at
  cutover and drop the legacy keys.
- Benchmarks: add `tool/bench/tui_bench.dart` and `chrome_bench.dart`; page-turn of a 100×30 list
  must stay < 8 ms/frame (native diff), cold `dart run` of `lib2/tui.dart` under the 15 ms budget
  after `core`.

---

## 10. First work queue (in order)

1. `FnReader`/`FnWriter` in `lib2/src/core/pipe.dart`; worker harness in `lib2/src/async/task.dart`
   (real `Isolate`+`SendPort` or a dedicated native worker thread — see `async.md`).
2. `tk_rename` + the rewritten `tk_chmod`/`tk_copy_file`/`tk_file_id` wired through
   `lib2/src/fs/io.dart` (kills the `chmod` process spawn at cutover; the Dart fallback
   carries it until then).
3. Hash-backed `writer()`/file hashing → `tk_digest_*`; fix `xxh3` to true XXH3 (native `xxhash`
   crate) and add `Hex`/`Base64`.
4. Archive: streaming unpack sink + selective `extract` + zip-slip rejection (throws
   `SecurityException`), then `Zstd.pack/unpack`.
5. Image: `info()`, `scale`, `blur`, `draw`, JPEG/WebP save via `tk_image_*`.
6. Process tree kill; HTTP retry + range resume; `Resp extends Reader`.
7. `chrome` crate (launch→pdf).
8. `tui` crate (run/poll/draw diff) — highest new-native risk; validate with `FakeTerminal` parity.
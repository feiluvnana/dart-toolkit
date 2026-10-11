# lib2 Gap Analysis, `native2` Redesign & Module Reports

This directory is the deliverable of a comprehensive audit of **`lib/lib2/`** against its
**original proposal** (`proposals/00_architecture.md` … `proposals/13_plan.md`), with a strong
focus on:

1. **Module-by-module gap analysis** — what the proposal promises vs. what the current `lib2`
   prototype ships.
2. **Native integration audit** — which subsystems must be driven by a native layer, and why the
   current `lib2` (pure Dart everywhere) cannot meet the proposal's Option-B goals.
3. **A new native architecture, `native2`** — the Rust/C-ABI layer that backs `lib2` seamlessly.
4. **A deep-dive on the TUI module**, whose prototype is the furthest from the proposal.

---

## How to read these reports

Every module report uses one template so a coding agent can pick any file and start:

| Section | What it answers |
|---|---|
| **1 · Proposal promise** | The exact behaviours the proposal (file:line) demands. |
| **2 · Current `lib2` state** | The real code today, with `lib/lib2/…` file references. |
| **3 · Gap analysis** | A severity-tagged table: missing, partial, or behavioural drift. |
| **4 · native2 requirements** | Exactly which FFI entries / subsystem ownership the module needs. |
| **5 · Actionable specification** | Signatures, algorithms, and step-by-step build order for the coding agent. |

Severity legend used throughout:

- **BLOCKER** — a feature in the proposal is absent, or the current behaviour is wrong/unsafe.
- **MAJOR** — the API exists but silently does not do what the proposal promises (e.g. "background
  isolate" that runs on the same isolate).
- **MINOR** — behaviour is correct but incomplete, unoptimised, or missing an edge case.
- **NATIVE** — must be implemented in the `native2` Rust layer, not in Dart.

---

## Executive summary

`lib2` is a skip-the-backlog rewrite of the toolkit that keeps the proposal's **dead-simple
one-word surface** but currently implements **every module in pure Dart**. That contradicts the
proposal's core Option-B decision (proposals/00_architecture.md:7): *"Rust Core Engine (FFI) for
heavy lifting (archive, image, hash, Chrome CDP, ratatui TUI) wrapped by dead-simple Dart APIs."*

The three most consequential findings:

1. **`native2` ownership is missing.** `lib2` re-implements hash, archive and image in Dart
   (`lib/lib2/src/hash/hash.dart`, `src/archive/archive.dart`, `src/image/image.dart`) when a
   mature native layer already exists at `native/src/` (digest.rs, archive.rs, image.rs,
   inflate.rs, text.rs, pieces.rs). The existing native layer, however, has **no Chrome CDP and no
   TUI** — the two subsystems the proposal names as native (proposals/11_chrome.md,
   proposals/12_tui.md). `native2` must both (a) re-wire the existing native calls under the
   `lib2` surface and (b) add the two new native subsystems.
2. **The `Reader`/`Writer` streaming spine broke.** The proposal's headline cross-module glue
   (`Http.get(url).pipe(File(...))`, `.pipe(Archive.unpack(dst:))`,
   `page.shot().pipe(File(...))`, `Hash.sha256.writer()`) is gone: `Resp` buffers the whole body,
   `Archive.unpack` reads whole files, `Page.screenshot()` returns one `Uint8List`, and
   `AlgoWriter` does not even implement `Writer`. Restoring the traits is the first engineering
   task.
3. **TUI is a text printer, not a terminal app.** `lib2`'s `Ui` class renders a String you
   `print`; there is no `run`, no `poll`, no raw mode, no events, no layout engine, no double
   buffer. Per the proposal this is a native `ratatui` + `crossterm` subsystem.

---

## Report index

| File | Topic |
|---|---|
| [`core.md`](./core.md) | Base traits (`Reader`/`Writer`/`Closer`/`Seeker`), `pipe`, naming conventions |
| [`io_fs.md`](./io_fs.md) | `Path`, `File`, `Dir`, `Link`, atomic writes, watch, chmod, copy |
| [`async.md`](./async.md) | `Task`, `Pool`, `Chan`, cancellation, real isolate workers |
| [`http.md`](./http.md) | `Http` verbs, `Resp` as a `Reader`, download/resume, retry, upload |
| [`json.md`](./json.md) | `Json.parse/dump/get`, docs, files, JSONL streaming |
| [`html.md`](./html.md) | `Html.parse/find/all`, CSS selector engine, sanitation, file I/O |
| [`archive.md`](./archive.md) | `Archive.pack/unpack/list`, streaming unpack, selective extract, zip-slip |
| [`process.md`](./process.md) | `Process.run`, pipelines, interactive I/O, timeouts, tree kill |
| [`image.md`](./image.md) | `Image.load/fit/crop/save`, `Image.info`, draw/watermark, codecs |
| [`hash.md`](./hash.md) | `Hash` digests, MACs, streaming writers, `Hex`/`Base64`, per-algorithm notes |
| [`cli.md`](./cli.md) | ANSI colours, `ask`/`confirm`/`choose`, `bar`, `spin`, multi-bar |
| [`browser_chrome.md`](./browser_chrome.md) | `Chrome.launch/connect`, `Page` nav/type/click/shot/pdf, native CDP |
| [`tui.md`](./tui.md) | TUI deep-dive: the full-gap list, layout, input, rendering, widgets |
| [`native2_architecture.md`](./native2_architecture.md) | The complete `native2` redesign: crates, C-ABI, handles, workers, ABI |
| [`roadmap.md`](./roadmap.md) | Phased build order binding the module specs together |

---

## Ground rules the redesign inherits

`CONVENTIONS.md` is the living rule set the `lib2`+`native2` work must keep honouring. The clauses
that drive everything below:

- **Four shapes, resources `close()`** (§1,r1–r6) — `lib2` already follows this shape
  vocabulary; `native2` handles must behave as resources.
- **One `Status` model, no progress callbacks** (§2) — native2 reports through the shared
  `Work`/`Status` model; a `pipe(..., onProgress:)` is a display convenience, not a status source.
- **The error table** (§3,r15) — `NativeException`, `FormatException` subtypes, a named
  `SecurityException` for zip-slip; no leaking of dart:io or raw `-1` codes across the boundary.
- **Async only; native work on a worker with a stop byte** (§8,r50–r53) — no synchronous FFI call
  that can run long on the caller.
- **Startup budget** (§9,r56) — a topic import costs at most 15 ms over `core`; `dart:ffi` costs
  every program that compiles it, so it may only appear where a native call is the only way. This
  forces `native2` into **separate cdylibs per subsystem** (`dart_toolkit_native`,
  `dart_toolkit_chrome`, `dart_toolkit_tui`) instead of one monolithic library.
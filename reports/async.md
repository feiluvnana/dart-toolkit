# Report · Async & Concurrency (`lib/lib2/src/async/`)

> Companion spec: [`../proposals/02_async.md`](../proposals/02_async.md). Minimalist: `Task`,
> `Pool`, `Chan`. The proposal is explicit that these are **isolate-based** primitives.

---

## 1. Proposal promise (02:5–64)

- `Task.run(() => heavy)` — *"**Spawns background isolates** with automatic error capture and
  timeouts"* (02:11). `Task.all([...])` — concurrent, in-order results (02:22). `Task.bg((cancel))
  … daemon.cancel()` (02:75).
- `Pool(4)` — *"**Persistent** worker **isolates** … avoiding the overhead of spawning new isolates
  per task"* (02:33); `run/wait/close`.
- `Chan(cap:)` — bounded **MPSC**, producer backpressure, fan-in, deterministic `close` EOF
  (02:44–64); `send/recv/tryRecv/close`.
- The full crawler (02:86–139) composes all three plus `Http`, `Html` and `File`.

## 2. Current `lib2` state

- `task.dart` (62 lines): `Task.run` = `Future.sync(fn)` on **the calling isolate** (no
  `Isolate.spawn`, no error capture differences, no real timeout semantics beyond
  `future.timeout`), `Task.all` = `Future.wait`, `Bg` + cooperative `CancelToken`.
- `pool.dart` (71 lines): `Pool(size)` is a **semaphore over the same isolate** — no workers, no
  message passing; `run` blocks an `_idle` completer.
- `chan.dart` (116 lines): an in-memory `Queue`-backed channel with `send/trySend/next/tryRecv/
  recv/close`. **Single-isolate only.**

## 3. Gap analysis

| # | Item | Status | Severity |
|---|---|---|---|
| G1 | `Task.run` uses a background **isolate** (02:11) | ✗ `Future.sync` on the caller isolates | **BLOCKER** |
| G2 | `Task.run` "automatic error capture" | `Future.sync` propagates synchronously — no worker crash isolation; a segfault/throw inside the closure is indistinguishable from the caller's own code | MAJOR |
| G3 | `Task.run(..., timeout:)` strict | `future.timeout` abandons the wait but the **work keeps running** (no cancellation, no stop byte) | MAJOR |
| G4 | `Pool` = persistent worker isolates | ✗ a mutex; heavy `compressFile` still runs on the caller's isolate and blocks the event loop | **BLOCKER** (02:33) |
| G5 | `Pool.wait()` drains queued+running | ✓ within-isolate semantics; wrong once workers exist | MAJOR |
| G6 | `Chan` cross-isolate MPSC (fan-in from workers, 02:49) | ✗ single-isolate; producers on other isolates impossible | **BLOCKER** |
| G7 | `Chan` backpressure bound (cap → RAM ceiling, 02:44) | ✓ `cap:` honoured inline | ok (single-isolate) |
| G8 | `Chan.close` — deterministic EOF for `await for` | ✓ `recv()` completes when closed+drained; send-after-close throws `StateError` | ok (keep) |
| G9 | `tryRecv()` non-blocking drain (12:4.1) | ✓ | ok |
| G10 | `Task.bg` long-running daemon + `cancel()` | ✓ cooperative token; add `onCancel`/cleanup hooks | MINOR |
| G11 | Crawler pipeline demo (02:86) | ✗ cannot run as written (Pool/Chan not cross-isolate; `queue.isEmpty` race) | MAJOR |
| G12 | CancellationToken wired to native **stop byte** (r53) | ✗ no native calls yet | MAJOR once native lands |
| G13 | Isolate-per-call overhead avoided | ✗ there is no isolate at all — the *opposite* | MAJOR |

## 4. Native requirements (`native2`)

- `Task`/`Pool` remain **Dart** (isolates are Dart's own power) — but every worker body that calls
  into `native2` must pass the worker's **stop byte** (task cancel → byte set → native call returns
  `STOPPED` → `CancelledException`). Provide a `NativeWork` seam: `work.stopByte` (a
  `NativePort`-owned `Uint8List(1)`), handed to `Worker.enqueue`/native handles.
- `Pool` becomes the Dart `Executor` for native worker queues: a pool of isolates, each holding one
  native worker-queue, reuse across jobs (native2_architecture.md §4.2).

## 5. Actionable specification

### 5.1 Real isolates (Phase 1)

1. **`Worker` first**: port the legacy pattern (`lib/src/async/…` `Worker`/`Runner`) into
   `lib2`: `Worker(init, run(item, work))`, messaging via `SendPort`/`ReceivePort`; closures
   built in top-level functions (r58).
2. **`Pool(Worker.new, concurrency:)`** — persistent spawned isolates; equal-unfinished-item
   dedup; keep `pool.wait/close`.
3. **`Task.run`** wraps one `Pool` round-trip (`pool.run(fn)`) when `isolate: true` is passed, else
   stays on-caller (r58: "small work stays on the caller; a batch goes to a worker"). Add
   `Task.run(..., timeout: 5.s)` → cancels the job (stop byte) *and* bounds the wait.
4. **`Chan` across isolates:** a `Chan` whose `send` handshakes through the worker isolate's
   `SendPort`, buffering in the **consumer's** isolate (so `cap` bounds memory at the consumer).
   Keep the single-isolate fast path (no ports needed) when both sides share an isolate.

### 5.2 Native stop-byte wiring (Phase 2 — when native lands)

5. `work.stopByte` exposed by the `Task`/`Batch` model; native sinks (`HashWriter`, unpack sink,
   image encode) take it; a cancel sets it and awaits the worker's completion ≥ 1 frame (never
   kills mid-call).
6. Worker crash policy: an unexpected `Error` from worker code ends the job immediately and is
   rethrown as-is (r14); a worker that died is replaced on next use.

### 5.3 Acceptance tests (`test/async_test.dart` for lib2)

- CPU-bound `Task.run(isolate:true)` does **not** block the event loop (timers still fire).
- `Pool` of 4 runs 20 jobs: ≤ 4 concurrently (concurrency counter), results in submission order.
- Backpressure: `Chan(cap: 3)` with a slow consumer never holds > 3 buffered (probe `len`).
- Fan-in: 8 worker isolates `send` into one `Chan(100)`; `await for` terminates exactly when
  `close()` is called after all producers join.
- `Task.run(..., timeout:)`: a blocked native digest returns `TimeoutException` and the digest
  handle is released; a subsequent native call on that worker still works.
- The 02:86 crawler example, verbatim, as an integration test (with a local `Http` fixture).
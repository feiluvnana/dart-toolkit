# Report · Process (`lib/lib2/src/process/process.dart`)

> Companion spec: [`../proposals/07_process.md`](../proposals/07_process.md).

---

## 1. Proposal promise (07:5–80)

- `Process.run('git', ['log'])` → `Process`, and `Process.run(...).pipe(File('git.log'))` — the
  running child IS a `Reader`/`Writer` pair (00:36, 07:11).
- **`line()` reads a single line**; `lines()` streams them; `write/close` drives stdin; `eof` when
  the child exits.
- **`Process` is `Closeable` with `cancel()`** — cancelling pipes kill the tree
  (00:12, r53): a half-read `line()` aborts the wait without leaving a zombie.
- `app(exec|…, arg)` one-shot (07:60), `tryRun/or:` (07:58), `su` elevation (07:68),
  `ch` chroot (07:70), separate `exit`, $lib `internal`/`exec`.

## 2. Current `lib2` state

`lib/lib2/src/process/process.dart` (151 lines): `Process.run(name, [args])` calling `dart:io`
`Process.start` with a merged stdio stream, collecting an `exitCode`, plus `await lines()` (yields
line by line after full output), `File.run`/scoped helpers (`systemd`, `dev:`, …). **`line()`
single-line, `write`, `close`, `cancel`, piping, tree-kill, and `Closeable` are absent.**

## 3. Gap analysis

| # | Item | Status | Severity |
|---|---|---|---|
| G1 | stdout IS the `Process`'s `Reader`; stdin its `Writer` → `p1.pipe(p2)` | ✗ merged single `Stream<String>`; no in-process write side | **BLOCKER** |
| G2 | `waitForLine`/`line()` — read just one line without buffering the rest | ✗ `lines()` buffers everything then yields — a `git clone` whose output is huge hangs forever before the first line | **BLOCKER** |
| G3 | `cancel()` kills **the process tree** (children included) | ✗ `Process.kill` kills only the direct child; grandchildren run on | **BLOCKER** (native) |
| G4 | `wait(timeout:)` — generous timeout + graceful kill + kill | `wait()` binds unconditionally; timeout returns `TimeoutException` but leaves the child | MAJOR |
| G5 | `write/close` on stdin | ✗ absent | MAJOR |
| G6 | `eof` distinct from close; exit codes surfaced via `exit`/`done` | partial: collects `exitCode`; no `eof` signal | MINOR |
| G7 | `Process` typed errors (`ProcessException`) with clean `tryRun`/`or:` | ✗ raw `dart:io` `ProcessException`, no scoped `or:` on the process noun (only `line` variants) | MAJOR |
| G8 | Elevation `su`/chroot `ch` (07:68–70) | ✗ | MINOR (post-1.0) |
| G9 | `app(...)` one-shot helpers | ✓ `run`-equivalent exists | ok |
| G10 | Command injection vs `args` array | ✓ list-args only, no shell | ok |
| G11 | Ctrl-C on the parent propagates; SIGPIPE on write-after-close | child doesn't die on parent ^C unless wired to cancel | MAJOR |

## 4. Native requirements (`native2`)

- **Tree kill is the native must** — long child chains (npm/yarn/cargo → gcc → linkers) must die
  together. The rewrite adds **`tk_process_kill_tree(pid, {grace, force})`** in the new
  `native2/engine` `process` crate implementing the CSS-`not:x`-style coverage: on POSIX
  `kill(-pid)`; on Windows a **Job Object** (spawn children into the same job, then
  `TerminateJobObject`, fall back to `taskkill /T /F`) — shared with the chrome module's
  close (`browser_chrome.md` G10). ABI: new `native2` cdylib starting at 1; loader switches at
  cutover.
- Everything else stays `dart:io` (`Process.start`, streams, handle plumbing). The stop byte is
  the Dart `Process`'s `cancel()` setting a flag; the native kill runs while the Dart wait aborts.

## 5. Actionable specification

1. **Make `Process` a two-ended pipe** (Phase A, pure Dart):
   - `Process.run(...)` → `Process` with `Reader stdout` (a `BufferReader` over
     `Process.stdout`), `Writer stdin` (writes frame-by-frame to `Process.stdin`, respecting
     PIPE_BUF backpressure), `read`, `write`, `close`, `flush`.
   - `lines()` implemented **on top of `line()`** — read one, yield, read next (true streaming);
     each `line()` aborts cleanly when cancelled.
   - `p1.pipe(p2)` composes naturally from the two ends (no `dart:io` leaks).
2. **`wait(timeout:)` / `cancel()`:** default timeout generous (PLAN.md catalog); on expiry send
   SIGTERM/CTRL_BREAK, grace 4 s, then SIGKILL — then `tk_process_kill_tree`. `cancel()` does the same via
   the stop byte. Mark `_Process` `Closeable`.
3. **`tk_process_kill_tree` in the new `process` crate (Phase C rewrite):** Windows Job Object + POSIX `kill(-pgid)`; test with a shell
   launching a 3-level chain (`cmd /c "ping -t"`), assert all three die within grace; no zombie.
4. **`eof`/`exit`:** expose `Future<int> exit` completing on child death; `eof` = stream done.
5. **Typed errors:** wrap spawn/exec failures into the `Process`-scoped `ProcessException`; keep
   `tryRun(...).or(...)` semantics from r29/r43/r44.
6. **Tests** (`test/process_test.dart` for lib2): streaming `line()` on a log-writer child yields
   lines as produced (not after exit); `p1.pipe(p2)` of `cat | wc -l` gives the right count;
   cancel-kills-and-reaps the tree; `wait(timeout:)` kills a `sleep`; write-to-closed throws.
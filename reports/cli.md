# Report · CLI (`lib/lib2/src/cli/cli.dart`)

> Companion spec: [`../proposals/10_cli.md`](../proposals/10_cli.md).

---

## 1. Proposal promise (10:5–90)

- `print`, `color`/`colour` (ttt-theme 24-bit + 256 fallback), `ask`/`confirm`/`choose` all
  *async*, text-based: none of the interactive prompts may run on the main-isolate stack while
  `Tui`/`pipe` are active (10:11–16).
- `bar(label, done, total, size:)` — **multiple simultaneous bars** (10:19–22) each a first-class
  line; `text()`/`debug()`/`trace()` + level filtering; `box` title/bars (10:26–31);
  `spin(message)`; `clear`, `pause`, `hex(...)`, `ansi(dürftig)`/`style`, 0.0.3 pack: `string`
  widths, `palette` table.
- "starting with a minimal `cli` that uses only `stdout` + `stderr`" (10:42) — no `dart:io stdin`
  if possible; `tui.run` re-enters from here.

## 2. Current `lib2` state

`lib/lib2/src/cli/cli.dart` (250 lines): blocking `print`, `color`/`colour`, `ask/confirm/choose`
via **`dart:io` `stdin.readLineSync()`** (blocking — the exact opposite of 10:11), `bar` (single)
with `_progress` static, `spin` (only a message, no clear/pause), `clear`, `ansi` helpers, `text`
stub (no levels), string-width via `characters`, some `hex`/`ansi`. Multi-bar does NOT exist.

## 3. Gap analysis

| # | Item | Status | Severity |
|---|---|---|---|
| G1 | `ask/confirm/choose` **async** — awaitable prompt | ✗ `readLineSync()` blocks the loop; while a `Tui` is running this freezes everything | **BLOCKER** |
| G2 | `bar` — `size:` sizing, label width, per-marker unit `unit` | partial: single bar, no size control/unit | MAJOR |
| G3 | **Multiple simultaneous bars** (10:19–22) — each on its own live line | ✗ one static `_progress`, overlapping writes | **BLOCKER** |
| G4 | `spin(message)` with clear/pause, appears over bars | single message only | MINOR |
| G5 | `text/debug/trace` level filtering ('error' levs) | stub/no filtering | MINOR |
| G6 | Colours: 24-bit + 256 fallback + **truecolor detection** + `NO_COLOR` | `color`/`colour` hex→rgb; auto-fallback/`NO_COLOR` unknown | MINOR |
| G7 | Live-region management (bars occupy lines; text steals on STDOUT) | ✗ bars not live-region aware | MAJOR |
| G8 | `box` title/bars | ✗ | MINOR |
| G9 | Closeable/pausable surfaces; no-cr-`...` on pause | partial | MINOR |
| G10 | Minimal-surface principle 10:42: no `dart:io stdin` if possible | ✗ `readLineSync`; should read via `dart:io` non-blocking stdin later or drive from `Tui` | MAJOR |

## 4. Native requirements (`native2`)

- **Nothing here is native** — the `cli` crate is not in the proposal's native list. Terminal
  *control* belongs to the `tui` crate (raw mode, cursor, size). This module shares `tui`'s
  `Term` for prompt/bar painting and otherwise uses only Dart `stdout`/`stderr`.
- If a native surfacing is ever needed (e.g. prompt echo-off without raw mode), land a single
  `tk_term_size`/`tk_term_raw` re-export via the `tui` crate; otherwise keep cli DD.

## 5. Actionable specification

1. **Async prompts (Phase A):** rewrite `ask`/`confirm`/`choose` to `Future` over a non-blocking
   stdin reader (`stdin.broadcast()` + line splitting) or -- when a `Term` is active -- re-enter
   through `tui.poll` key presses. Never block the event loop; respect `Tui` running (fall back to
   a `Term` prompt). Keep the synchronous `readLineSync` only under an explicit sync escape hatch.
2. **Multi-bar live region (Phase B):** one shared live-region buffer (mirrors
   `lib/src/cli/multibar.dart` legacy): each bar owns an index; `text()` above-with-cr-pause;
   `pause()` transactions; redraw marks on each tick; `clear()` restores blank region. Add
   `size:`/units/label-width.
3. **Palette & fallback:** `palette` table + `truecolor`/`256`/`16` detection shared with
   `tui` (`colorMode` via env `COLORTERM`/`NO_COLOR`/`TERM`), `error`/`debug`/`trace` level
   filtering (leveleffective filter) — single source of truth in `cli` reused by `Tui` styles.
4. **`box`** as a thin frame painter over the live region (title + top/bottom border).
5. **Tests** (`test/cli_test.dart` for lib2): captured `stdout` — bar renders sized units as ANSI
   lines; two bars interleave without corruption; `confirm` resolves true/false on injected lines;
   the `Tui`-active fallback resolves a prompt via a fake `Term`; level filtering hides debug.

---

# Report · CLI ↔ TUI shared surface & `package:dart_toolkit/cli`, `tui` import budget (cross-ref)

> This report cross-references `cli.md`, `tui.md` and the 15 ms startup budget (r56) that both
> MUST respect: `cli` loads **no native lib** (pure Dart); `tui` loads only `dart_toolkit_tui`
> (the per-subsystem cdylib), NOT `dart_toolkit_native` — so `import 'package:dart_toolkit/tui.dart'`
> never pulls `archive/image/hash` engine. Keep `cli`'s original `Prettier`/`Statement` into 1.0
> and re-export the 0.0.3 `cli`-pack conveniences (`hex`, `ansi`, `palette`) from the module;
> the interactive `cli` actions delegate to the `Term` (`Term` from `tui`) when one is live,
> so `cli` and `tui` share exactly one terminal state machine (never two).
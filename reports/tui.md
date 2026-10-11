# Report · TUI Module Deep-Dive (`lib/lib2/src/tui/tui.dart`)

> Companion specs: [`../proposals/12_tui.md`](../proposals/12_tui.md) (proposal),
> [`../proposals/00_architecture.md`](../proposals/00_architecture.md:91) (`run`, `draw`, `poll`,
> `box` naming), [`tui.md` legacy ground truth](../README.md#terminal) and the mature
> implementation in `lib/src/tui/*`.
> **This is the module whose current prototype is furthest from the proposal.**

---

## 1. Current state of `lib2`

`lib/lib2/src/tui/tui.dart` (75 lines) is a **frame *string* printer**:

```dart
final class Ui {
  final List<String> _lines = [];
  Ui box({String? title, int? width})   // a ┌─…─┐ wall with hard-coded width 40
  Ui end({int? width})
  Ui text(Object content, {int? width})
  Ui bar({required num val, required num max, String? label, int width = 30, String? unit})
  Ui list(List<String> items, {int sel = 0})
  Ui gap()
  String render() => _lines.join('\n');  // toString => render
}
```

That is the whole module. There is **no `Tui` class, no `run`, no event loop, no terminal mode
management, no polling, no input, no screen ownership**.

---

## 2. Gap analysis — Current vs. Proposal vs. "Robust" (severity)

### 2.1 Screens & application lifecycle

| # | Feature | Proposal (12:1) | `lib2` | Legacy `lib/src/tui/app.dart` | Severity |
|---|---|---|---|---|---|
| G1 | `Tui.run((term) async { … })` lifecycle | required | ✗ none | `Tui.run<S,M>(state, draw, update, …)` returns a `Task` | **BLOCKER** |
| G2 | Raw mode (no echo, no line-buffering, no ^C-as-signal) | "enters raw mode" | ✗ | via terminal seam | **BLOCKER** |
| G3 | Alternate screen + guaranteed restore "on every way out" (normal exit, ^C, ^Z, exception, cancel) | "handles cleanup automatically" | ✗ | `_Engine` restores with `defer` | **BLOCKER** |
| G4 | Terminal detection: width/height, colour capability (24→256→16→none), Unicode vs ASCII palette, `NO_COLOR` | implied | ✗ | `terminal.dart` colour fallback chain | MAJOR |
| G5 | `run` is a `Task` (progress/cancel/`Closeable`) | — | ✗ | `Task` | MAJOR |
| G6 | Inline-rectangle mode (TUI inside a live region, not just full screen) | — | ✗ | legacy inline region support | MINOR |

### 2.2 Event model & input handling

| # | Feature | Proposal (12:3) | `lib2` | severity |
|---|---|---|---|---|
| G7 | `event polling with timeout`: `term.poll(timeout:)` / `ev.key == 'up'` | required | ✗ no poll | **BLOCKER** |
| G8 | `Term`/`Ui` object with `draw` closure per frame (state passed to draw) | required | ✗ print serves only as a static frame | **BLOCKER** |
| G9 | Key events with named keys: up/down/left/right/enter/esc/tab/space/backspace/delete/home/end/pageUp/Down/F1–F24 | proposal uses `'up'`, `'enter'`, `'q'` | ✗ | **BLOCKER** |
| G10 | Typed text (chars), Unicode, composition | — | ✗ | MAJOR |
| G11 | Ctrl combos, Alt combos, modifiers (`mods`), Shift+arrows | — | ✗ | MAJOR |
| G12 | Mouse/pointer: click, drag, release, wheel, buttons, and **inline mouse mode** (SGR) | — (0.0.3 adds `pointer:`) | ✗ | MAJOR |
| G13 | Resize event + re-measure + redraw | "captures … resize" | ✗ | **BLOCKER** |
| G14 | Paste (bracketed paste), focus in/out (kitty), suspend/resume (^Z), interrupt (^C)* | 0.0.3 event set | ✗ | MAJOR |
| G15 | Escape parsing: multi-byte sequences that must not race (a slow UTF-8 read turning into Esc — 0.0.2 fix) | — | ✗ | MAJOR |
| G16 | Non-blocking drain (proposal 12:4.1 `updates.tryRecv()` loop then poll with timeout) | required | ✗ | **BLOCKER** |

> *Interrupt semantics from CONVENTIONS/README: ^C arrives as `Interrupt`; answering a new state
> keeps the app open; a second ^C within 2 s quits. `Tui.quit(state)` is the only restart/shutdown.

### 2.3 Rendering engine

| # | Feature | `lib2` | severity |
|---|---|---|---|
| G17 | Double-buffered cell grid with **diff painting** (only changed cells written) | ✗ String printer repaints everything | **BLOCKER** |
| G18 | Unicode width & wrapping (emoji, NFD marks, jamo, combining) | ✗ no measure at all | MAJOR |
| G19 | Style/colour on cells: fg/bg, bold/dim/italic/underline/reverse; palette fallback | ✗ ANSI strings inside content only | **BLOCKER** |
| G20 | Word-wrap, truncate-with-ellipsis, vertical scrollback for a region | ✗ | MAJOR |
| G21 | Layered/overlapping regions (popups over content, tooltips) | ✗ | MAJOR |
| G22 | Frame rate control (target fps, coalesced draws, no tearing) | ✗ | MINOR |

### 2.4 Layout & widgets

| # | Feature | Proposal (12:2) | `lib2` | severity |
|---|---|---|---|---|
| G23 | `ui.split(vert: false, [ (left){…}, (right){…} ])` nested **flex layout** | required | ✗ no layout engine | **BLOCKER** |
| G24 | `box(title:)` with border, title, padding, per-region size | required | "partial" — wall that can't nest | **BLOCKER** |
| G25 | `list(items, sel:)` — selectable menu, scrollable beyond viewport, styled selection | required | "partial" — flat ▸ highlight | MAJOR |
| G26 | `bar(val,max,label,unit)` gauge with glyph sets | required | "partial" — no unit/colour | MINOR |
| G27 | `text(...)` with colour and wrapping | required | ✗ raw print | **BLOCKER** |
| G28 | Buttons, clickable regions, toggles, tabs, grids/tables | legacy set | ✗ | MAJOR |
| G29 | `Field` (single/multi-line text input, cursor, selection, suggestions, undo) | 0.0.3 widget list | ✗ | MAJOR |
| G30 | Popup, editable popups, tooltips, hover | legacy | ✗ | MAJOR |
| G31 | `Markdown` renderer, `Picture` (sixel/kitty/block) | README | ✗ | MINOR |
| G32 | `Board(tally)`/`TaskView` — status/`Tally` progress surface | core vocabulary | ✗ | MAJOR |
| G33 | Scroll/Log widgets; `Menu<T>` with values; focus traversal (tab/shift-tab, arrow focus), focus rings | legacy | ✗ | MAJOR |
| G34 | Layout units: `flex`, `percent`, `fixed` sizes, padding/margin, alignment, spacing | legacy `widget.dart` | ✗ | MAJOR |

### 2.5 Model integration & testing

| # | Feature | `lib2` | severity |
|---|---|---|---|
| G35 | Events are one noun (`Start`, `KeyPress`, `Pointer`, `Resize`, `Interrupt`, `Post`) and side effects are statics (`Tui.post`, `Tui.listen`, `Tui.defer`, `Tui.focus`, `Tui.quit`) | ✗ none | MAJOR |
| G36 | `FakeTerminal` test seam in `testing.dart`: screenshots, key inject, assert frames | ✗ none | **BLOCKER** |
| G37 | Renderer purity: **`draw` and `update` only**; no side effects inside `draw` | ✗ | MINOR |
| G38 | Async integration: `Chan` feed → board (proposal 12:4.1) | ✗ | MAJOR |

---

### 2.6 The three behavioural fixes lib2's `Ui` already gets wrong

1. `box` hard-codes `width = 40` and squares inner lines `┌─$label…┐` with `math.max(0, inner -
   label.length)` — if `title.length ≥ inner` the line grows and the box is misaligned (no clamp,
   no truncation, no `…`).
2. `bar` with `max <= 0` paints a full bar (divide-by-zero guard returns `1.0`), which is
   reasonable, but rendering answers `'$val/$max'` numeric text with no speed/ETA/size units.
3. `list` has no scroll: a 10k-item list emits 10k lines and overflows the terminal; `sel` is
   painted but not interactive.

---

## 3. Native requirements (`native2` → `dart_toolkit_tui`)

From `native2_architecture.md` §6, the native `tui` crate owns the parts Dart cannot do fast or at
all:

| Responsibility | native2 `tui` crate | Dart (`lib2/src/tui`) |
|---|---|---|
| Raw mode, alt screen, restore-on-exit | `crossterm` on a **worker thread** | — |
| Terminal query (size, colour count, kitty features, mouse SGR, paste) | yes | reads results via poll |
| **Diff rendering** (cell buffer → changed cells) | `ratatui`/custom buffer + `tk_tui_loop` | serialises the *widget tree* into `tk_frame` |
| Key/pointer/resize/paste events incl. multi-byte escape parsing | `crossterm` events → `tk_event` | decodes to the noun events |
| Unicode width, wrapping, ellipsis | yes (Rust `unicode-width`) | — |
| Frame pacing | yes (tick budget on worker) | sets `Tui.post`/keepalive |
| `getch`/`chcp`/raw-VT Windows console | yes | `unicode` reads `chcp.com` (no `dart:ffi` in `cli`) |

The **widget layout** stays in Dart (flex, stack, alignment, focus tree, scroll offsets) because it
is pure data and cheap; native renders the final cell grid and paints diffs. This split keeps
`lib2/tui.dart`'s import cost within the 15 ms budget (it loads only the `dart_toolkit_tui`
loader, not the whole engine).

---

## 4. Actionable implementation specification

### 4.1 Phase A — engine skeleton (no native yet, `FakeTerminal`-driven)

1. **New surface in `lib2/src/tui/` (split out of the single 75-line file):**
   - `lib2/src/tui/tui.dart` — `Tui.run`, `Tui.quit`, `Tui.post`, `Tui.listen`, `Tui.defer`,
     `Tui.focus`, `Term`.
   - `lib2/src/tui/events.dart` — `TuiEvent` (sealed), `Start`, `KeyPress(Code)/text/Paste/
     Pointer(kind,row,col,button)/Resize(w,h)/Focus/Blur/Suspend/Resume/Interrupt/Post/`.
   - `lib2/src/tui/layout.dart` — `Node`, `VStack/HStack/Box/Label/Bar/List/Grid`, flex/percent/
     fixed sizing, measure-then-place.
   - `lib2/src/tui/buffer.dart` — the cell grid + diff (`List<Cell>` where change⇒ paint).
2. **`Term` contract:**
   ```dart
   sealed class TuiEvent {}
   final class Term {
     Offsetget size;                          // measured terminal
     void draw(Object state, void Function(Canvas ui) build);
     Future<TuiEvent?> poll({Duration timeout});
     void post(Future<T> f, {void Function(Object)? onError});
     StreamSubscription listen(Stream<T> s);
     void defer(Future<void> Function() cleanup);
     void focus(Widget w);
   }
   Future<T> Tui.run<T>(T initialState, {required Widget Function(T) draw,
       required T Function(T, TuiEvent) update, bool pointer = false, int? fps});
   ```
3. **`Canvas` (the `ui` in the proposal):** `box(title:)`, `text`, `bar`, `list(items, sel:)`,
   `split({required bool vert, required List<Widget Function(Canvas)> children})`,
   `gap`, `label`, `button`, `grid`, `field`, `popup` — all typed views, one builder each
   (CONVENTIONS §7 r48: "customization is a theme of builders over typed views").
4. **Event loop:** `update → draw → measure → render diff → poll(timeout)`. Redraw is a
   `Tui.post`-scheduled coalesced single frame per event tick (G22).
5. **`FakeTerminal`** in `lib/testing.dart` (`lib2` re-export): a screen of cells, `send(key)`,
   `sendPaste`, `pointTap`, `resize(w,h)`, `pumped` snapshots, and key-injection for tests. Add
   `test/tui_test.dart` for lib2 (mirror the legacy `tui_test.dart` groups).

### 4.2 Phase B — native renderer (`dart_toolkit_tui` ABI 1)

For each item use the `native2_architecture.md` §6 FFI:

1. `tk_tui_start(w,h,rgb)` → worker + alt screen + raw mode. `tk_tui_stop` restores; `free` waits.
2. Serialise the Dart widget tree to a `tk_frame` (positioned cells with fg/bg/flags); native
   diff-paints. Assert: a frame that changes one label writes only those cells (test through the
   fake terminal's written-bytes log).
3. `tk_tui_poll(h, &ev, ms)` drives key/pointer/resize/paste parsing; Dart maps `tk_event.kind` to
   the sealed `TuiEvent` nouns (G9–G14).
4. Pointer: enable SGR/kitty inline mouse; map wheel + drag to `PointerKind.*`.
5. Keep the Dart layout as source of truth in **Phase A tests**; in Phase B add a gold
   `layout_test` that proves Dart layout == native layout for the widget set.

### 4.3 Phase C — interactive widget completeness

Implement in order of value (all have legacy behaviour to port):
`List/Menu` (scroll, hover, keys) → `Button/Clickable` (+ Enter/Space/click) → `Field`
(cursor, selection, clipboard-ish, suggestions, undo) → `Popup/Tooltip` → `Tabs/Grid` →
`Board(Tally)`/`TaskView` → `Markdown` → `Picture` → inline-region `Tui.run(region:)`.

### 4.4 Acceptance tests (convert these to `test/tui_test.dart`)

- Kill the app with `q`; with ^C (first `Interrupt` answered → app stays; second within 2 s quits);
  with `^Z` suspend/resume; with an exception (terminal restored once).
- Resize mid-run → `Resize` event and a correct re-layout; `255`-only and `NO_COLOR` fallbacks.
- A 10 000-row `list` scrolls without porting all rows; diff writes < 40 cells on a one-label
  change.
- `Chan` producer → `Board` updates at a bounded fps with no frame-rate drops (proposal 12:4.1).
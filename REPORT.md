# REPORT — v2 review (2026-10-13)

Scope: `lib/` on branch `v2` (with the uncommitted cli/chrome changes), against `VISION.md`, plus
`example/rawfree.dart` as the reference real-world caller.

Legend: **✔ verified** = reproduced by running code (TUI checks ran in a real pty driven by a
script); **read** = found by reading the code, not run. Severity: **H** breaks a documented use;
**M** wrong in a real case; **L** edge case or polish.

## 0. Summary: fix in this order

1. **Data loss and hangs:** F1/F2 (`unpack` deletes the target), F5 (the pool keeps scripts
   alive), S1 (a crawl hangs on failure), H1/H2 (http hangs or keeps the process alive), F3
   (truncated gzip accepted).
2. **TUI:** R1–R3 (resize garbage: per-row repaint, wide chars, control chars), I1–I4 (input
   cleared too early, letters not `pressed`, `^C` kills the process, unknown keys = `escape`), L1
   (a second `run` throws). rawfree needs all of these.
3. **Wrong results:** M1/M2 (html loses `<body>` and table rows), B1/B2 (download crash,
   `waitIdle` too early), C1–C5 (cli typing, `required`, `--help`), F6–F10 (pipe and fs edge
   cases), K1/K2 (console width, a stuck live line).
4. **API decisions** (all applied in the new VISION.md):
   - verbosity (§7): tui `width`/`height`/`list`/`input`; http `ok`/`size`/`name`, `json:`, `retries:`,
     form `body:`, only 2xx bodies pipe; html `text()` like innerText, first match; json `*` paths
     and `value<List<T>>`; shell `Shell.open`, `text()` without the trailing newline;
   - cli: sealed `Def<T>`, typed by `T` (no `Opt<bool>`, no `Arg(many:)`);
   - navigation `timeout:`;
   - `chrome`/`scrape` re-export `html`.
5. **Charset:** in-house WHATWG CJK decoders; `charset` and `enough_convert` both fail (§8).
6. **Tests:** every fix keeps a regression test (VISION §6). tui and console get pseudo-terminal
   tests, and cli gets the untested paths listed in C15.

---

## 1. tui — why resize "breaks everything"

### 1.1 Rendering

| #   | Sev | Problem                                                                                                                                                                                                                                                                                                                                       | Where                         | Status                              |
| --- | --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- | ----------------------------------- |
| R1  | H   | **The full repaint (every resize, and the first frame) streams the whole grid as one run and relies on autowrap.** It never moves the cursor to the start of each row. So one cell whose width on screen differs from what we assumed shifts every row after it, and the screen turns to garbage. The diff path repositions only at gaps, so the damage stays local until the next resize. That is why it looks fine until you resize. | `_paintFull` tui.dart:228     | ✔ (`日 本 語abc` overflows the row) |
| R2  | H   | **Wide characters are painted as two cells *plus* a space.** `write` stores a `''` continuation cell after a CJK char, and both paint paths emit `' '` for it, so each wide char takes 3 columns. The diff path also advances `cx` by 1 for a wide char, so cursor tracking drifts. rawfree shows Japanese titles, so it hits this on every resize.        | tui.dart:200, :239            | ✔                                   |
| R3  | H   | **Control characters are written raw.** `'\t'`, `'\r'`, `ESC` and other bytes in the text (scraped titles, error messages, coloured strings) go straight to the terminal and move its cursor. Any `\n` after the first is silently dropped.                                                                                        | `Region.write` tui.dart:268   | ✔ (`x\ty` emitted with a raw TAB)   |
| R4  | M   | **`_cellWidth` is incomplete.** Emoji (U+1F300–1FAFF, many in U+2600–27BF such as `✅`), combining marks (U+0300–036F; Vietnamese in NFD), ZWJ and variation selectors (U+FE0F) all count as 1, so they feed R1. A wide char cut at the right edge is dropped, but the other half of a wide char that gets overwritten is left behind.        | tui.dart:442                  | read                                |
| R5  | M   | **Style leaks between cells.** `_style` emits only the attributes that are set and never resets first. Going from `bold+color` to `color`-only keeps bold, and going from `color` to `bold`-only keeps the colour.                                                                                                                                      | `_style` tui.dart:243         | read                                |
| R6  | L   | `_paint` reads `grid[0]` and throws `RangeError` when the height is 0 (some terminals report 0 rows during a drag-resize).                                                                                                                                                                                                                        | tui.dart:186                  | read                                |
| R7  | L   | Writing the bottom-right cell with autowrap on is fragile: on some terminals the wrap that is pending after it scrolls the screen. Autowrap is never turned off.                                                                                                                                                           | `_enter`                      | read                                |

**Fix (one coherent change to the painter):**

1. In `_enter` write `\x1b[?7l` (autowrap off) and in `_leave` write `\x1b[?7h`. The terminal can
   then never wrap or scroll whatever the widths are (fixes R7, and limits R1 to a single row).
2. `_paintFull`: write `\x1b[${y+1};1H` before each row instead of relying on wrap.
3. Give `_Cell` a `width` (0 = continuation). Both paint paths **skip** continuation cells and
   advance `cx` by the cell's width; the diff path compares the lead cell and repaints it whenever
   either half changed.
4. `Region.write`:
   - split the text on `\n` and write each line on the next row;
   - expand `\t` to spaces up to the next multiple of 4 or 8;
   - replace other C0/C1 controls and `DEL` with `�`;
   - when a wide char does not fit in the last column, write `' '`;
   - when a cell overwrites half of an existing wide char, blank the other half.
5. Width: iterate grapheme clusters with `package:characters` (a Dart-team pub engine, which
   VISION §10 allows) and use a real wcwidth table: emoji ranges = 2; Mn/Me/ZWJ/VS = 0, attached
   to the previous cell's string.
6. `_style(c)` always starts from a reset: `\x1b[0;1;38;5;${n}m` / `\x1b[0m`.
7. `if (grid.isEmpty) return;` at the top of `_paint`, and clamp `_width`/`_height` to ≥ 1.

### 1.2 Input

| #   | Sev | Problem                                                                                                                                                                                                                                                                                                                     | Where                  | Status                                                    |
| --- | --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | --------------------------------------------------------- |
| I1  | H   | **`pressed()`/`typed()` are always empty outside `build`.** `frame()` clears input *after* painting, so the documented loop `while (!screen.pressed('escape')) await screen.frame(…)` never exits. The same goes for the VISION §7.12 example's `typed()`/`backspace` handling and every `Future<Screen>` mirror (`screen.frame(…).pressed('q')`). | `frame` tui.dart:108   | ✔ (keys logged inside build only, never after `frame`)   |
| I2  | H   | **`pressed('a')` is never true.** Printable keys only go to `typed()`, so `pressed('q')`, `pressed('o')` and `pressed('b')` are dead. rawfree's chapter view (`o` = browser, `b` = back) does nothing.                                                                                                                        | `_poll`/`_parse`       | ✔                                                         |
| I3  | H   | **`^C` kills the process and leaves the terminal broken** (alternate screen, hidden cursor, mouse reporting, no echo). `lineMode = false` clears only `ICANON`, not `ISIG`, and nothing listens for SIGINT. The docs promise "`^C` is just `pressed('ctrl+c')`".                                                                            | `_enter`               | ✔ (child died by SIGINT, no `?1049l` in output)           |
| I4  | H   | **Unknown sequences become `'escape'`, which quits most apps.** Seen with Shift+Tab (`CSI Z`), `ESC O H`/`ESC O F` (Home/End in many terminals), modified keys (`CSI 3;5~`), focus events and anything else unrecognised.                                                                                                         | `_csiName`, SS3 branch | ✔ (Shift+Tab, `ESC O H`, `CSI 3;5~` → `escape`)           |
| I5  | M   | **Insert (`CSI 2~`) is mapped to `'enter'`**, so it presses the focused button.                                                                                                                                                                                                                                                 | tui.dart:532           | ✔                                                         |
| I6  | M   | Modifiers are dropped: `CSI 1;5A` reads as `up`, so `ctrl+up` and `shift+left` are impossible. `ctrl+@`, `ctrl+\` and the like become `ctrl+\``, `ctrl+|` and similar.                                                                                                                                                          | `_csiName`, `_parse`   | read                                                      |
| I7  | L   | `ESC` followed by any byte is `alt+<byte>`: `ESC ESC` gives `alt+\x1b`, and `ESC` + a UTF-8 lead byte gives mojibake. A lone `ESC [` (Alt+[) waits for the next key, then turns into a bogus CSI.                                                                                                                                   | `_parse`               | read                                                      |
| I8  | L   | Pasted text containing `\r` fires `enter` (and so the focused button) once per line. Bracketed paste is not enabled.                                                                                                                                                                                                                | `_parse`               | read                                                      |
| I9  | L   | Mouse: any button counts as a click (right and middle too), the wheel is dropped, and malformed SGR (`ESC[<M`) throws `RangeError` on `parts[1]`.                                                                                                                                                                         | `_parse`               | read                                                      |

**Fix:**

- I1: drop the three trailing `clear()` calls in `frame()`; `_poll()` already clears at its start.
  The input then lasts from the start of frame N until the start of frame N+1, which is what
  "pressed since the last frame" means.
- I2: in `_poll`, for each `_Type`, add every rune to `_pressed` as well (`'a'`, `'A'`, `'1'`; give
  the space bar the name `'space'`).
- I3: in `_enter`, `_sigint = io.ProcessSignal.sigint.watch().listen((_) => _signals.add('ctrl+c'))`
  and merge `_signals` into `_pressed` in `_poll`. While a listener exists, Dart does not
  terminate on SIGINT. Also watch `sigterm` (and `sighup`): restore the terminal, then
  `io.exit(143)`. Cancel all of them in `_leave`.
- I4/I5/I6: `_csiName` returns `String?`, and `null` emits no event. Split the params on `;`, and
  map modifier `m` (2 = shift, 3 = alt, 5 = ctrl, combinations) to a prefix (`'ctrl+up'`,
  `'shift+tab'`). Add `Z` → `shift+tab`, `2~` → `insert`, and SS3 `A-D/H/F` → arrows/home/end.
  Ignore `CSI I`/`CSI O` (focus events).
- Shift+Tab moves focus backwards.
- I8: enable bracketed paste (`\x1b[?2004h`) and deliver the pasted block as `typed()` only.
- I9: count only `btn & 3 == 0` (left button); report the wheel as `'wheelup'`/`'wheeldown'`
  keys; guard `parts.length < 3`.

### 1.3 Lifecycle

| #   | Sev | Problem                                                                                                                                                                                                       | Where           | Status                                               |
| --- | --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- | ---------------------------------------------------- |
| L1  | H   | **A second `Tui.run` in the same process throws** `Bad state: Stream has already been listened to`, because `io.stdin` is single-subscription and `_leave` cancels it. Any menu → TUI → menu flow breaks. | `_enter`        | ✔                                                    |
| L2  | L   | `_leave` forces `echoMode`/`lineMode` to `true` instead of restoring the previous values (`Console.choose` already saves them). It never restores autowrap (once R7 is fixed) or bracketed paste.            | `_leave`        | read                                                 |
| L3  | L   | Nothing redraws on resize while the app is awaiting something other than `frame()`. The SIGWINCH handler only nulls `_last`.                                                                                 | `_enter`        | read                                                 |
| L4  | L   | Always renders at 60 fps, allocating a new W×H grid each frame, even when idle.                                                                                                                                | `frame`         | read                                                 |

**Fix:** one module-private `final _stdin = io.stdin.asBroadcastStream();`, created lazily and
reused by every `Tui.run` (its subscription is never cancelled; pausing is fine). Save and restore
the old `echoMode`/`lineMode`. Reuse two grids, swapped each frame and cleared with `fillRange`,
instead of `List.generate`.

### 1.4 Layout and widgets (`Region`)

| #   | Sev | Problem                                                                                                                                                                                                                                                                                                                         | Status |
| --- | --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| W1  | H   | **`button` ignores the region's height.** It draws at `_y + _cursor` even when that is past `_h`, so on a small terminal buttons spill into the sibling region below or onto a border. It still registers for Tab focus and Enter (an invisible button can fire). Its click area is the full label even when the label is clipped. | read   |
| W2  | M   | **`Region` has no `width()`/`height()`.** Apps can't size lists, centre, truncate with `…` or react to resize. rawfree hard-codes `s.height() - 5` and `cols([11, 0])` and must update them by hand whenever the layout changes.                                                                                      | read   |
| W3  | M   | **`box()` ignores the cursor.** It always borders the whole region, even after `write`s, and doesn't advance the parent's cursor. `rows`/`cols` split "below the cursor", so the three are inconsistent.                                                                                                                       | read   |
| W4  | M   | A box title with wide chars doesn't set continuation cells (R2 again), and the title can overwrite the `┐` corner.                                                                                                                                                                                                                 | read   |
| W5  | L   | A focused button is shown only in **bold**, which is barely visible in many themes. Focus is by index, so a conditionally drawn button moves focus to its neighbour.                                                                                                                                                              | read   |
| W6  | L   | Negative sizes in `rows`/`cols` are silently treated as `0` (flex).                                                                                                                                                                                                                                                              | read   |

**Fix:**

- W1: in `button`, `if (_cursor >= _h) { _cursor++; return false; }` before registering. Clip the
  click width to `min(text.length, _w)`.
- W2: add `int width()` and `int height()` to `Region`, the same names as on `Screen` (VISION §5:
  the same idea, the same name), and use them in rawfree.
- W3: `box` covers the part of the region below the cursor and then sets `_cursor = _h`, matching
  `rows`/`cols`.
- W5: draw the focused button in inverse video (`\x1b[7m`). Add an `inverse` flag to `_Cell`; this
  needs no new public API.
- W6: `ArgumentError` on a negative size.
- Tests: §1 rule 1 requires a test for every listed member. Today only the not-a-terminal throw is
  tested. Expose the pure parts for tests via `@visibleForTesting`, or test through a fake
  `Stdout`/byte source injected privately:
  - the parser (`_parse` with byte fixtures: split UTF-8, split CSI, lone ESC, SGR mouse);
  - layout (`Region` on an off-screen grid);
  - the painter (diff output for wide chars, styles and resize).

---

## 2. What `example/rawfree.dart` says the library is missing

rawfree is the only real caller, and it routes around the library in several places. Each line
below is a workaround in the example and the library change that removes it.

| rawfree today                                                                                                                                                   | Cause                                         | Change                                                                                                                                                                                                                                                                   |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `s.pressed('o')` and `s.pressed('b')` never fire. The comment "plain `o` would also fire while typing, so browser is ctrl+o"                                        | I2                                            | Fix I2. The app already picks by view, so both views work.                                                                                                                                                                                                                |
| Japanese titles break the screen on resize                                                                                                                       | R1/R2                                         | Fix the painter (§1.1).                                                                                                                                                                                                                                                       |
| `final visible = (s.height() - 5)…` plus about 20 lines of hand-written `sel`/`scroll` clamping, twice                                                              | W2; no list widget                            | **Decided:** `Region.height()` and `Region.list(List<String> items, int selected)`, which draws the rows that fit, keeps `selected` in view and highlights it. It deletes `_drawList` and both scroll loops (≈30 lines) for one member.                          |
| `head`/`tail` with a hard-coded `cols([11, 0])`; the comment "split rows first: cols() consumes its region's cursor"                                             | W2                                            | `Region.width()` lets the app size the columns; the cursor rule stays, but is documented once in the library doc.                                                                                                                                            |
| Manual `dlDone/dlTotal` text instead of a bar                                                                                                                    | no progress drawing in a Region               | **Not added:** `Region.bar` would delete only ~2 lines at the call site. Keep the text.                                                                                                                                              |
| `if (res.status() < 200 \|\| res.status() >= 300) { await res.close(); throw … }`, three times                                                                     | no success test on `Response`                 | `bool ok()` on `Response` (2xx). An ok-or-throw verb would break rule 11, so a reading is the fit.                                                                                                                                                                  |
| `_postForm`: a hand-written redirect loop and a form encoding done with `Uri(queryParameters:).query` plus a manual content-type                                              | `dart:io` follows only 303 for POST           | **Decided:** follow 301/302/303 after a POST as a GET (browser behaviour); 307/308 resend an in-memory body. `body:` accepts a `Map<String, String>` as a URL-encoded form and sets the content-type.                                         |
| `_headers` copied into every call (`{..._headers, 'referer': …}`)                                                                                               | no shared defaults                            | **Not added:** a global default would be shared mutable state for three lines of savings.                                                                                                                                                                 |
| `_unescape`: 40 lines of hand-written HTML entity decoding of JSON fields                                                                                        | no entity decoding outside a parsed document  | **Example change only:** `Html.parse(s).text()` already decodes entities.                                                                                                                                  |
| `_browse`: platform `open`/`xdg-open`/`start` switch                                                                                                             | no "open with default app"                    | **Decided:** `Shell.open(String target)` (URL or path), which deletes 12 lines in every script that wants it.                                                                                                                                                                             |
| `_safe`: sanitising file names                                                                                                                                   | none                                          | Keep it in the example (a niche need), or `Fs.safe(name)` if a second caller appears.                                                                                                                                                                                         |
| Downloads one image at a time with `await res.bytes()` then `Fs.file(…).write(bytes)`                                                                          | example style                                 | `await (res > Fs.file(path))` streams. `Pool` can run 4 at a time. The `<1 KB = expired stub` check can use `content-length`.                                                                                                                                              |
| `p.$('id').value<num>()?.toInt()` everywhere                                                                                                                     | unneeded: `value<int>()` works on `3` ✔       | The example should use `value<int>()`. Library bug ✔: `value<double>()` on `3` gives `null`, and `value<int>()` on `3.0` gives `null`. Convert integral `num`s in `value<T>` for `int` and `double`.                                                               |
| State changed from `.then()` callbacks; the frame loop re-renders at 60 fps to pick it up                                                                      | immediate mode                                | Fine as designed. Document the pattern (async work mutates state, and the next frame shows it) in the tui library doc.                                                                                                                                                              |

---

## 3. cli

| #   | Sev | Problem                                                                                                                                                                                                                                                                                                                                             | Where                    | Status |
| --- | --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ | ------ |
| C1  | H   | A parent `Multi` given before the subcommand reaches the child as a raw `List<Object?>`. `--tag a go`, then `List<String> t = ctx(tag)` throws a `TypeError` and the run exits 1.                                                                                                                                                                                          | cli.dart:630-635         | ✔      |
| C2  | H   | The same `putIfAbsent` merge loses the parent's `Multi` values: `--tag a go --tag b` gives `[b]`, not `[a, b]`.                                                                                                                                                                                                                                                       | cli.dart:630-635         | ✔      |
| C3  | H   | A required parent `Opt` or `Arg` is never checked. Dispatching to a subcommand returns before binding and validation, so `Opt('token', required: true)` on the root and `app go` give exit 0 with `ctx(token) == null`.                                                                                                                                                  | cli.dart:622-637         | ✔      |
| C4  | H   | `Multi<T>` or `Arg(many: true)` with `parse:` is stored as `List<Object?>`, never `List<T>`, whether the option is given or absent. `List<Color> c = ctx(col)` throws a `TypeError`.                                                                                                                                                                                   | cli.dart:317, 334, 364   | ✔      |
| C5  | H   | Declaring any `short: 'h'` removes the built-in `--help` (`app --help` gives "Unknown option", exit 64).                                                                                                                                                                                                                                          | cli.dart:592             | ✔      |
| C6  | L   | `argv[0] == 'help'` always means help, even when the command takes an `Arg` (a query of `help` can't be passed). `help <cmd>` works only at the root (`app remote help add` → unknown command). `help <unknown>` prints the root usage and exits 0, with no suggestion.                                                                                       | cli.dart:157, 554, 638   | ✔      |
| C7  | L   | The "Run … --help" hint stops at the first `-` token: `app -v go --n x` suggests `app --help` instead of `app go --help`.                                                                                                                                                                                                                              | cli.dart:189-200         | ✔      |
| C8  | L   | Messages end with `?.` (`Did you mean "--url"?.`). Suggestions include `Arg` names, which can't be used as `--x`. `-vh` reports "Unknown option -h".                                                                                                                                                                                                                | cli.dart:582-591, 642, 670, 706 | ✔ |
| C9  | L   | `Multi(required: true, or: […])` is accepted, while `Opt`/`Arg` reject the same combination. `--wait -5` is accepted but `--wait -5s` is rejected.                                                                                                                                                                                                                         | cli.dart:59, 477         | ✔      |
| C10 | L   | Any error from a handler, including programmer errors, becomes one line and exit 1 with no stack trace. A `TypeError` is just `Instance of 'TypeError'`.                                                                                                                                                                                            | cli.dart:183-185         | ✔      |
| C11 | api | `T call<T>(Object def)` and `values: List<Object>` are untyped: `T` comes from the call site, not the definition (so the doc's "typed by its declaration" is false), and `ctx(top).anything()` compiles.                                                                                                                                      | cli.dart:148, 214        | ✔      |
| C12 | api | The surface leaks: the public `Handler` typedef, and public fields on every definition and on `Command` (`name`, `help`, `short`, `or`, `parse`, `values`, `commands`, `handler`, `aliases`…). This breaks rules 1 and 5. `Bar.release()` in console is the same problem.                                                                                        | cli.dart:32-54, 146, 248 | ✔      |
| C13 | api | There are two ways to declare a yes/no option: `Flag` and `Opt<bool>` (also `Multi<bool>`/`Arg<bool>`).                                                                                                                                                                                                                                                  | cli.dart:26, 39          | read   |
| C14 | api | Subcommand names skip `_checkName`, and a child can redeclare an ancestor's `--name` or `-v` with a different meaning.                                                                                                                                                                                                                                            | cli.dart:136-143         | read   |
| C15 | gap | `usage()` doesn't list `-h, --help`. No tests for `Ctx.rest`/`usage`, `--`, grouped shorts, `-5` as a positional, Duration/DateTime/Uri values, suggestions, `--[no-]` or ancestor options. C1–C5 all sit in untested paths.                                                                                                                                         | cli.dart:913; tests      | read   |

**Fix:**

- C4: `Arg(many:)` is removed (`ctx.rest()` already gives the positional tail), so only `Multi` needs a list.
- C1/C2/C4: give the `Def` types a typed `List<T> _empty()` / `List<T> _cast(List<Object?>)`
  helper (`List<T>.of(xs.cast<T>())`). Call it for every list value: parsed, absent (the default),
  and inherited.
- C2/C3: don't merge with `putIfAbsent`. Bind and validate the parent's definitions first: the
  parent's values, plus a `Multi` concatenated with the child's occurrences. Only then dispatch.
  Required checks run at every level.
- C5: `--help` is always reserved. Reject a user `--help`, and keep `-h` as help unless the user
  declares `short: 'h'`; in that case only `-h` changes meaning.
- C6: `help` is a command only when the current command has subcommands and the token sits in the
  command position. Recurse `help a b c` down the tree. An unknown name gives exit 64 plus "Did
  you mean".
- C7: walk the tokens with the same parser to find the deepest command reached.
- C8: build the message as `'Did you mean "$x"?'` with no trailing `.`. Suggest only `Opt`, `Flag`
  and `Multi` names. Treat `h` inside a short group as help when it is reserved.
- C9: reject `required` together with `or` on `Multi`. Parse negative durations through one path.
- C10: catch only `UsageException` (exit 64) and any `Exception` (one line, exit 1). Let `Error`
  propagate with its stack trace.
- C11: add `sealed class Def<T>` as the base of `Flag`/`Opt<T>`/`Multi<T>`/`Arg<T>`, with
  `T call<T>(Def<T> def)` and `List<Def<Object?>> values`. This also lets the three eight-type
  ladders (307-375, 517-543, 828-903) become one virtual method per class.
- C12: make the fields private and the classes `final`, so nothing leaks beyond the constructors.
- C11, as decided in VISION §4.10: `Opt<T>`/`Arg<T>` read as `T` itself. A nullable `T` (`Opt<String?>`) can be absent; a non-nullable `T` needs `or` or `required`, checked with `null is T` at construction.
- C13: drop `Opt<bool>` (assert at construction), so `Flag` is the one way.
- C14: run `_checkName` on command names. Throw an `ArgumentError` when a child redeclares an
  ancestor's long name or short.

## 4. console

| #   | Sev | Problem                                                                                                                                                                                                                                                                                     | Where                      | Status |
| --- | --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- | ------ |
| K1  | H   | **No terminal width handling** (the same family as the TUI resize problem). `terminalColumns` is never read, nothing is truncated, there is no `\x1b[K`, and resizes are ignored. A line wider than the terminal wraps, so every `\r` redraw stacks a new line. A shorter redraw leaves the end of the previous one on screen. `choose` breaks when a choice wraps or there are more choices than rows. | console.dart:130, 190, 283-303 | ✔ (truncation and clearing missing) |
| K2  | H   | A bar claims the single live line when it is built, but releases it only inside `transform`. If the pipe fails before the bar is listened to (for example, the target file can't open), every later `bar`/`spin` in the process throws `StateError`.                                                                         | console.dart:149, 254      | ✔      |
| K3  | M   | Ctrl-C during `ask(secret: true)` or `choose` leaves echo and line mode off in the user's shell.                                                                                                                                                                                                         | console.dart:48, 163       | ✔      |
| K4  | M   | `ask`/`choose` block the event loop (`readLineSync`/`readByteSync` behind a `Future`). A concurrent bar, download or `Pool` freezes while the prompt waits.                                                                                                                                                  | console.dart:53, 172       | ✔      |
| K5  | L   | A second bar draws over the live line *before* `_claim` throws.                                                                                                                                                                                                                                       | console.dart:149, 209      | ✔      |
| K6  | L   | In `choose`, a lone Escape blocks and then swallows the next key, and `ESC O A/B` arrows are ignored.                                                                                                                                                                                                     | console.dart:176-179       | ✔      |
| K7  | L   | `_fail` prints `\n✗` (a blank line when there is no terminal) while `spin` prints `\r✗`.                                                                                                                                                                                                                   | console.dart:276-281       | ✔      |
| K8  | api | The rate always says `B/s` and counts are raw: an item bar shows `1/10  10 B/s`, and a byte bar shows `204801`, not `200 KB`.                                                                                                                                                                       | console.dart:292-307       | ✔      |
| K9  | api | `Bar.release()` is public. It frees the line without printing the final state.                                                                                                                                                                                                                    | console.dart:203, 251      | ✔      |
| K10 | gap | No pseudo-terminal tests (§11). `ask`, `confirm`, interactive `choose`, the non-terminal fallback, `NO_COLOR`, throttling and the ✓/✗ output are untested; those tests would have caught K1–K7.                                                                                                                 | test/console_test.dart     | read   |

**Fix:**

- K1: on every redraw, read `io.stderr.terminalColumns`. Fit the line to it (shrink the bar from 20
  down to 10 cells, then cut the label with `…`) and end it with `\x1b[K`. Cache the width and
  refresh it on SIGWINCH. In `choose`, cut each choice to `width - 2` and show at most
  `terminalLines - 2` choices in a scrolling window around the selection.
- K2: claim the line lazily, on the first `transform`/`tick`. Also release it from a `Finalizer`
  or a `Pipe` error path, so a failed pipe can't hold it.
- K3: inside prompts, listen to `ProcessSignal.sigint`. Restore the modes, then `io.exit(130)`.
  Share one "restore terminal" helper with tui (§1.2, I3).
- K4: read through the same shared broadcast stdin as tui (§1.3, L1), asynchronously. That fixes
  the freeze and lets prompts and TUI run in one process.
- K5: `_claim` before the first draw.
- K6: decode keys with the tui parser (one key decoder in the package, not two).
- K7: write `\r✗` on a terminal and `✗` with no prefix otherwise.
- K8: format byte counts as human-readable sizes, and show `/s` only when the bar measures bytes.
  **Decided (no new option):** a bar used in a pipe counts bytes,
  and `tick()` counts items.
- K9: make `release()` private.

## 5. fs · shell · archive · hash · image · json · pool

All 107 existing tests for these modules pass. Every finding below was reproduced with a scratch
script unless it is marked "read".

| #   | Sev | Problem                                                                                                                                                                                                                                                                               | Where                       | Fix                                                                                                                                                                                                                                         |
| --- | --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F1  | **H, data loss** | **`unpack(dir)` deletes the existing target recursively before moving the temp folder in.** Files already in `vendor/` are lost. `Http.get(u) > Archive.unpack('.')` empties the current folder and then fails (`Deletion failed, path='.'`).                                                    | archive.dart:124-127        | Never delete the target. Extract into the temp folder (keeping the all-members-checked-first rule), then move each top-level member into `dir` (rename, or copy when renaming fails), creating `dir` if it is missing. Regression test: unpack into a folder that already has a file, and into `.`. |
| F2  | H   | `unpack('out/')` names its temp folder `out/.tmpN`, which sits inside the target, so it deletes itself, fails, and loses `out/`.                                                                                                                                                                  | archive.dart:106            | Normalise with `p.normalize` and create the temp folder next to the target: `p.join(p.dirname(d), '.${p.basename(d)}.tmp…')`.                                                                                                                                                       |
| F3  | H   | `gunzip()` on truncated data succeeds silently: half of a 2.4 MB `.gz` gave a 1.19 MB file and no error, so a cut-off download is saved as good data.                                                                                                                                          | archive.dart:194-213        | Check that the gzip trailer (CRC32 + ISIZE) is present and matches; otherwise fail the run with `FormatException`.                                                                                                                                                              |
| F4  | H   | `Shell.filter` fails when the child exits early: `… \| Shell.filter(['head','-n','1']) > f` throws `SocketException: Broken pipe`.                                                                                                                                                                 | shell.dart:151-163, 182     | Treat EPIPE on the child's stdin as "the child is done reading": stop feeding it and cancel the upstream. The exit code decides success.                                                                                                                                              |
| F5  | H   | **After any `Pool.run`/`map`, the script never exits** unless `Pool.close()` is called (the engine keeps `RawReceivePort`s open). The §7.9 example hangs.                                                                                                                                             | pool.dart (worker_manager)  | Count the active jobs and close the engine when the count reaches 0 (re-init lazily), or `keepIsolateAlive: false` (`Isolate.spawn` with ports `.unsendable`/unref'd). If the engine can't, use an in-house `Isolate.run` pool (VISION §10 allows the swap).                                           |
| F6  | M   | If the writer fails before it reads (for example, the parent folder is missing), the pipe never runs. A hasher in the pipe isn't poisoned, so `hex()` returns the empty-input digest `e3b0…`. `Reader.to` doesn't cancel the upstream, which leaks an http connection.                                                     | core.dart:47-56, hash.dart  | In `Reader.to`/`Pipe`: on a writer error, cancel the source subscription and send the error to every stage (`hash._fail`, `bar._release`). Each stage gets a private `_abort(Object e)`.                                                                                                     |
| F7  | M   | The atomic write (`write`, `> file`) drops the old file's mode (a `755` script came back as `644`) and replaces a symlink with a regular file.                                                                                                                                                     | fs.dart:174-197             | Resolve symlinks first (`resolveSymbolicLinks`) and write the real target. After the rename, `chmod` the temp file to the old file's mode.                                                                                                                                                     |
| F8  | M   | `Dir.move` falls back to copy-then-delete on *any* error. Moving into a non-empty folder silently merges, overwrites, then deletes the source.                                                                                                                                                  | fs.dart:272-282             | Fall back only on `EXDEV` (`osError.errorCode == 18`). Otherwise rethrow.                                                                                                                                                                                                          |
| F9  | M   | `Dir.copy('a' → 'a/sub')` recurses into itself (448 junk entries, then ENAMETOOLONG). `copy`/`move` of a missing source creates an empty destination, then throws.                                                                                                                                     | fs.dart:266, 434-452        | First check that the source exists. Reject a destination inside the source (`p.isWithin`).                                                                                                                                                                                      |
| F10 | M   | `Link.resolve()` returns a handle at the link's own path, not the target's, so `exists()` is `false` and `delete()` removes the link. `Link.create` deletes and then creates (not atomic), and over a regular file it says "Cannot delete link".                                                                                 | fs.dart:293-314             | `resolve()` = `resolveSymbolicLinks()`, then build the handle for that path. `create` makes a temp link next to the target, then renames it over the target.                                                                                                                                                                   |
| F11 | M   | `Pool.close()` with a job running makes that job's future hang forever. Two concurrent first calls both `init()`, so the engine prints a warning to stdout. With 1 CPU there are 0 workers and every job hangs (read).                                                                                           | pool.dart:26-31, 62, 102    | Memoise the init `Future`. On `close()`, complete every in-flight job with a `StateError('pool closed')`. Use `max(1, numberOfProcessors - 1)` workers and the same number as the `map` limit.                                                                                                                             |
| F12 | L   | Shell: stderr is cancelled when stdout ends, so late stderr is missing from the exception. The rewrapped `ProcessException` drops `errorCode`.                                                                                                                                                       | shell.dart:46-50, 137, 180  | Drain stderr until the process exits. Pass `errorCode` through.                                                                                                                                                                                                                 |
| F13 | L   | Archive: an empty `tar` can't be unpacked ("unknown format"). Gzip data that isn't a tar is parsed as a garbage tar with a misleading message. Modes are ignored, so executables lose `+x`. `pack` silently drops symlinks.                                                                                                    | archive.dart:59, 119, 145, 160 | Detect the tar header (`ustar` at offset 257, or an all-zero end block) and treat an empty tar as empty. Apply `f.mode & 0x1ff` with `chmod` on unpack (POSIX). Document the link policy: `pack` refuses links with `FormatException`, the same as `unpack`.                                                                              |
| F14 | L   | Image: a GIF keeps every frame (VISION: first frame only), so `encode(.png)` writes an animated PNG. ICO above 256 px throws a bare engine `Exception`. `resize(width: -5)` gives a `RangeError`, and `width: 0` is accepted.                                                                                         | image.dart:38, 56-63, 149   | Decode with `frame: 0` (or take `.frames.first`). Reject an `.ico` above 256 px with `ArgumentError`. Reject width/height < 1 with `ArgumentError`.                                                                                                                                     |
| F15 | L   | Json: `encode` deep-copies on every call and turns `{1:2}` into `{"1":2}` (where `dart:convert` throws). `[i]`/`length`/iteration rebuild the whole list, so an indexed loop is O(n²) (read). `value<double>()` on `3` gives `null` (§2).                                                                                    | json.dart:64-96             | Wrap lazily, keeping the raw `List` and wrapping per access. `encode` passes raw values through `toEncodable`. Number coercion in `value<T>`.                                                                                                                                  |
| F16 | api | `Dir.copy` keeps neither the mode nor the mtime of folders (VISION says it keeps both). `Output` can be streamed twice (VISION §2: a one-shot reader throws `StateError`). `pool.dart` doesn't `export 'core.dart'`. The sendability probe deep-copies every job (twice the cost for image bytes, read).                            | fs, shell:105, pool         | Set the folder mtime after its contents are copied. **Decided:** `Output` is replayable (it is in memory), and VISION now says so. Add the export. Drop the probe and let `Isolate` report the error.                                                     |

## 6. chrome · scrape · html · http

The existing tests for these modules all pass (Chromium launches in about 1 s). Each finding was
reproduced with a scratch script unless it is marked "read".

| #   | Sev | Problem                                                                                                                                                                                                                       | Where                     | Fix                                                                                                                                                                                                       |
| --- | --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| S1  | H   | **A crawl hangs forever on a failure with no `onError`** while URLs are still queued: the workers exit, but `_drain` waits for `_hasWork`.                                                                                     | scrape.dart:244, 274      | On `_failure`: clear the queue, wait for the visits in flight, then close the stream with the error. Regression: a handler that `follow`s two URLs then throws, with `limit: 1`.                                 |
| S2  | H   | `follow` accepts any scheme. A `mailto:`, `tel:`, `javascript:` or `data:` link fails the crawl (`No host specified`), and with S1 it hangs.                                                                                     | scrape.dart:216-227       | In `normalize`, keep only `http`/`https` and silently drop the rest.                                                                                                                                    |
| S3  | H   | Browser path: a 5xx or 429 `continue`s without closing the tab (one 503 URL with `retries: 2` leaked 3 tabs). A tab fetched after a failure or cancel is never closed.                                                          | scrape.dart:307, 342      | Open each tab inside one `try/finally` that always closes it. Do the cancel/failure check inside it.                                                                                                       |
| S4  | M   | A Chrome navigation failure is a bare `Exception('net::ERR_…')`, so it isn't retried. `browser.open(url).timeout()` leaves a late tab open (read).                                                                                 | scrape.dart:380, 401      | Rethrow as `SocketException` naming the URL, and retry it. Use `open(url, timeout:)` (C5).                                                                                                           |
| H1  | H   | **`Http.put(u, body: reader)` hangs forever** when the server never reads the body: the header timeout fires, but `await streaming` waits on an open client.                                                                       | http.dart:301-306         | On timeout, close the client first, then cancel the body stream. Never `await` the body-sending future after a failure.                                                                                   |
| H2  | H   | **`await Http.get(u).status()` keeps the process alive.** The `Future<Response>` mirrors `status()`/`header()`/`url()` drop the response, so nobody can close it.                                                             | http.dart:248-252         | The mirror reads the value and then `close()`s the response: a response reached only through a mirror can never be read later. VISION §4.2 now says so.                                                 |
| H3  | M   | Redirects: a POST 302/307 is returned instead of followed. `url()` resolves the last `Location` against the first URL rather than the previous hop, so `html()` and `follow` get the wrong base.                                  | http.dart:119, `_send`    | Follow redirects by hand in `_send` (`followRedirects = false`, up to 10 hops), keeping the current URL. Apply the method rules in VISION §4.2.                                                   |
| H4  | M   | package:http's `ClientException` leaks (for example, "Connection closed before full header"). It is not an `IOException`, so scrape doesn't retry it.                                                                               | http.dart:292, 325        | Map `ClientException` → `HttpException(message, uri:)` at the boundary.                                                                                                                                       |
| H5  | M   | `text()` knows only utf-8, latin1 and ascii, so EUC-KR, Shift_JIS and GBK pages are garbled. `<meta charset>` is ignored. `Visit.text()`/`html()` always use UTF-8 (read).                                                                         | http.dart:220, scrape:131 | In-house WHATWG decoders (see §8: no pub package passes). Without a header, sniff `<meta charset>` in the first 1 KB. `Visit` reuses `Response`'s decoder. |
| H6  | L   | A `String` body without `content-type` gets the engine's `text/plain; charset=utf-8`. `Http.defaultTimeout` is public.                                                                                                            | http.dart:30, 313         | Keep the default, and VISION now documents it. Make `defaultTimeout` private.                                                                                                                                                 |
| M1  | H   | **`Html.parse` drops `<html>`, `<head>` and `<body>`.** `doc.$('body')` is empty for every `Http.get().html()`, `Page.html()` and `Visit.html()`.                                                                              | html.dart:29              | Parse a full document when the input starts (after whitespace) with `<!doctype` or `<html`, and a fragment otherwise.                                                                                    |
| M2  | H   | `Elements.without` serialises and re-parses each item, so table parts vanish (`$('tr').without('.x')` → 0).                                                                                                                        | html.dart:73-94           | Clone the nodes, as `Element.without` already does.                                                                                                                                                               |
| M3  | L   | `$` on a top-level element wraps it in a `<div>` (so `'div p'` matches a lone `<p>`). `Elements` from `Element.$` exclude the element itself (`$('div, span').$('div.o')` → 0).                                                  | html.dart:160, 211        | Match the element itself with the engine's `matches`, without wrapping. Use one query path for both cases.                                                                                                            |
| M4  | L   | `attr` doesn't trim before resolving (`" /path "` → `%20/path%20`). Only `href` and `src` are resolved, so the lazy-image `data-src` stays relative.                                                                       | html.dart:197             | Trim URL attributes. Resolve `href`, `src`, `data-src`, `poster` and `action`.                                                                                                                                       |
| B1  | H   | **`download()` on a missing selector crashes the script** with an unhandled `TimeoutException` from `willBegin`, created before `_actionable`.                                                                                         | chrome.dart:366-371       | Wait for `_actionable` first, then create `willBegin`, and attach `.catchError` until it is awaited.                                                                                                       |
| B2  | H   | **`waitIdle` returns while requests are still in flight** (with a 3 s XHR it returned at 670 ms).                                                                                                                          | chrome.dart:332-343       | Count in-flight requests (`request` +1; `requestfinished`/`requestfailed` −1). Idle means 0 in flight for 500 ms.                                                                                       |
| B3  | M   | `press('Enter')` types "Enter" and `press('esc')` types "esc"; `press('+')` throws.                                                                                                                                       | chrome.dart:248-257       | Use the shared key-name table (VISION §4.12). A single printable character is typed; any other unknown name is an `ArgumentError`.                                                                                   |
| B4  | M   | `upload` waits for visibility, but most file inputs are `display:none`, so it times out.                                                                                                                                                | chrome.dart:292           | `upload` waits for *attached* only.                                                                                                                                                                 |
| B5  | L   | `fill('#q', '')` leaves the old value. `eval<double>('1.0')` gives `null`, and `eval<List<String>>` is always `null`.                                                                                                           | chrome.dart:203, 227      | Always clear before typing. Route `eval` results through the `Json.value<T>` coercion and document `List<Object?>`/`Map<String, Object?>`.                                                             |
| B6  | L   | `scroll(selector)` doesn't auto-wait and throws `StateError`. `open`/`goto`/`back`/`reload` have no `timeout:`.                                                                                                                  | chrome.dart:80, 173, 316  | `scroll` waits like the other actions (`TimeoutException`). Add `{Duration? timeout}` to the navigation calls; VISION §4.3 has it.                                                                                   |
| B7  | L   | Leaks and races (read): every `pages()` call builds wrappers with 5 subscriptions that are never cancelled (dialogs dismissed twice); `onDialog` isn't cancelled in `close()`; `abort()`/`continueRequest()` aren't awaited; `setDownloadBehavior` is browser-wide, so two concurrent downloads clash. | chrome.dart:105-155, 365  | Cache one `Page` wrapper per target in an `Expando`. Cancel the subscriptions in `close()`. Await and `catchError` the interception calls. Give each `download` its own folder, keyed by the `guid` of `willBegin`. |
| B8  | L   | Chromium downloads into `<project>/.dart_tool/puppeteer` (359 MB per project), not the user cache.                                                                                                                                      | chrome.dart:41-48         | `downloadChrome(cachePath: <user cache>/dart_toolkit/chrome)`.                                                                                                                                             |
| B9  | api | The library doc says `cookieHeader`, the code says `cookies()`. `chrome` and `scrape` don't re-export `html`, so `page.html().$('a')` needs a second import.                                                                         | chrome.dart:15, 28; scrape:30 | Keep `cookies()` (VISION decided). `export 'html.dart'` from both.                                                                                                                                        |

## 7. Verbosity: every module, measured at the call site

Sections 1–6 are bugs. This section checks the API against its own bar: an addition must delete
more at the call site than it adds to the surface. The yardsticks are rawfree, the VISION
examples, and the patterns every script repeats. All decisions below are already in VISION.md.

### 7.1 What changes

| #   | Module  | Call site today                                                                                                     | After                                                                       | Surface cost                  |
| --- | ------- | ------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | ----------------------------- |
| V1  | tui     | about 75 lines: key handling, `_drawList`, scroll loops, `sel`/`scroll` clamps, a hand-drawn `'> $query▌'`, rune backspace | `query = box.input(query);` `sel = body.list(titles, sel);`               | +`input`; `list` returns `int` |
| V2  | tui     | `s.height() - 5` and `cols([11, 0])` hard-coded                                                                     | `r.height()`, `r.width()`                                                   | +2, the same names as `Screen` |
| V3  | http    | `if (res.status() < 200 \|\| res.status() >= 300) { await res.close(); throw … }` ×3                              | `if (!res.ok()) …`                                                          | +`ok`                         |
| V4  | http    | `body: Json.encode(x), headers: {'content-type': 'application/json'}`                                               | `json: x`                                                                   | +1 named param (as in Python `requests`) |
| V5  | http    | `_postForm`: 30 lines of redirect loop, form encoding and headers                                                  | `Http.post(u, body: {'a': 'b'})`                                            | none (a new `body:` type)     |
| V6  | http    | `int.parse(res.header('content-length') ?? '0')`                                                                    | `res.size()` (`int?`); `Console.bar(res.size())` accepts `null`             | +`size`, the same name as `File` |
| V7  | http    | `Uri.parse(u).pathSegments.lastOrNull ?? 'img'`, `Fs.file(img.url()).name()`                                        | `res.name()` / `visit.name()`: the content-disposition filename, else the last URL segment | +`name`, the same name as `Download`/`Entry` |
| V8  | http    | `final r = await Http.get(u); if (!r.ok()) …; await (r > f);`, needed because the one-liner saves 404 pages     | `await (Http.get(u) > f)`: piping a non-2xx body throws `HttpException`     | none (a behaviour change)     |
| V9  | http    | hand-written retry loops in downloaders (scrape already has `retries:`)                                            | `Http.get(u, retries: 2)`; scrape delegates to it                           | +1 named param, reused        |
| V10 | html    | `.text().trim()` on nearly every scrape. `Elements.text()` concatenates every match (`$('.price').text()` → `"$1$2$3"`) | `text()` is innerText-like (collapsed and trimmed). On `Elements` it reads the **first** match, like `attr()` | none                          |
| V11 | html    | 40-line `_unescape`                                                                                                 | `Html.parse(s).text()`                                                      | none (works today)            |
| V12 | json    | `p.$('id').value<num>()?.toInt()`                                                                                   | `value<int>()` (integral numbers read as both `int` and `double`)           | none                          |
| V13 | json    | `[for (final t in p.$('tags')) t.value<int>()].whereType<int>().toList()`                                           | `p.$('tags').value<List<int>>()`                                            | none                          |
| V14 | json    | `[for (final u in j.$('data.users')) u.$('name').value<String>() ?? '?']`                                          | `j.$('data.users.*.name').value<List<String?>>()`                           | none (a `*` path segment)     |
| V15 | shell   | `(await Shell.run(['git', 'rev-parse', 'HEAD']).text()).trim()`                                                    | `await Shell.run([...]).text()`: one trailing newline dropped, as in `$(…)` and execa | none                          |
| V16 | shell   | `_browse`: 12-line platform switch                                                                                  | `Shell.open(url)`                                                           | +`open`                       |
| V17 | chrome  | `import 'package:dart_toolkit/html.dart'` next to chrome/scrape, just to call `$` on `page.html()`              | `chrome` and `scrape` re-export `html`                                      | none                          |
| V18 | chrome  | `eval<List<String>>` always `null`, so a `List<dynamic>` gets cast by hand                                        | `eval<T>` reads with the `Json.value<T>` rules                              | none                          |
| V19 | cli     | `Opt<String>('out', …)` read as `String?`, then `!` at every use                                                   | `Opt<String>(…, or: 'out')` reads as `String`; `Opt<String?>` as `String?` | none                          |

The surface grows by 7 members (`input`, `width`, `height`, `ok`, `size`, `name`, `open`) and 2
named parameters (`json`, `retries`), all reusing names that already exist elsewhere (§3 of
VISION). Everything else is behaviour.

### 7.2 Proof: rawfree after the changes

The TUI and data layer of `example/rawfree.dart` (514 lines today) shrink to roughly this:

```dart
Future<void> main() => Tui.run((screen) async {
  final app = App();
  while (!app.quit) await screen.frame((r) => app.draw(screen, r));
});

final class App {
  var query = '', searched = '', hits = <Hit>[], sel = 0;
  Hit? series;
  var chapters = <Chapter>[], csel = 0, status = 'type a manga title, press enter', quit = false;

  void draw(Screen s, Region r) {
    final [head, body, line, foot] = r.rows([1, 0, 1, 3]);
    head.write(series == null ? '✻ rawfree · ↑↓ enter · ctrl+o browser · esc quit'
                              : '✻ rawfree · enter download · o browser · b back', color: 208);
    line.write(status, color: 240);
    if (s.pressed('ctrl+c')) quit = true;
    if (series case final open?) {
      csel = body.list([for (final c in chapters) c.title], csel);
      foot.box(open.title).write('enter downloads the chapter', color: 240);
      if (s.pressed('enter') && chapters.isNotEmpty) download(chapters[csel]);
      if (s.pressed('o')) Shell.open(open.url);
      if (s.pressed('b') || s.pressed('escape')) series = null;
    } else {
      query = foot.box('search').input(query);
      sel = body.list([for (final h in hits) h.title], sel);
      if (s.pressed('enter') && query != searched) search();
      else if (s.pressed('enter') && hits.isNotEmpty) openSeries(hits[sel]);
      if (s.pressed('ctrl+o') && hits.isNotEmpty) Shell.open(hits[sel].url);
      if (s.pressed('escape')) quit = true;
    }
  }
  // search / openSeries / download: the same async bodies, each ~10 lines shorter (below)
}

Future<Json> api(String path) => Http.get('$base/wp-json/wp/v2/$path', headers: headers, retries: 2).json();
String title(Json p) => Html.parse(p.$('title.rendered').value<String>() ?? '').text();   // was _unescape + _titleOf
final tags = p.$('tags').value<List<int>>() ?? [];                                         // was a for + whereType
final decoded = await Http.post('$base/wp-admin/admin-ajax.php', body: fields).json();    // was _postForm (30 lines)
for (final (i, u) in images.indexed) {                                                     // was 25 lines
  final img = await Http.get(u, headers: {...headers, 'referer': '$base/'}, retries: 2);
  if (img.ok()) await (img > Fs.dir(dir).file('${'${i + 1}'.padLeft(3, '0')}_${img.name()}'));
  else { failed++; await img.close(); }
}
```

Estimate: about 514 lines down to about 260. The whole TUI view drops from about 150 lines to
about 25. All of `_unescape`, `_postForm`, `_apiGet`, `_browse` and `_drawList`, plus both
scroll loops, go away.

### 7.3 Checked and left alone

| Pattern                                                         | Why it stays                                                                                                                                                            |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| cli: each `Def` named three times (variable, `'name'`, `values:`) | The variable is the typed key, and the string is the user-facing flag. Without codegen or reflection, nothing shorter keeps `ctx(def)` typed.                                |
| chrome: `final b = await Chrome.launch(); try … finally b.close()` | A `Chrome.run((b) async {…})` would be a second way in. Instead, `close` is guaranteed on Ctrl-C and errors (B7). The `finally` is one line.                                         |
| http: the same `headers:` map repeated                          | A global default would be shared mutable state, to save one identifier per call.                                                                                       |
| `await (a \| p > w)` parentheses                                | Dart's precedence. The method form (`a.pipe(p).to(w)`) needs none.                                                                                                       |
| pool + bar: `final bar = …; Pool.map(…, onResult: (_) => bar.tick()); bar.close()` | Three lines for two independent tools that compose. Merging them would couple the modules.                                                                       |
| fs: `list(recursive: true).whereType<File>().where(…)`          | Dart's own `Iterable` says it. Globbing stays out (VISION §7).                                                                                                           |
| `Output.ok()`                                                   | `exitCode() == 0` is already short, unlike the two-sided 2xx range.                                                                                                     |
| `Region.bar`, `Http.download`, `Elements.texts()`               | Each saves at most one line (`write('$d/$t')`, `Http.get(u) > f`, `.map((e) => e.text())`).                                                                                |

## 8. Charset engine: checked, not adopted

| Encoding                  | `charset` 2.0.1                           | `enough_convert` 1.7.0 |
| ------------------------- | ----------------------------------------- | ---------------------- |
| EUC-KR / CP949            | ✗ **wrong text** (`B0 A1` → `뎰`, should be `가`; encoding gives no bytes) | not supported |
| Shift_JIS, EUC-JP         | ✓                                         | not supported          |
| GBK (and the GBK range of GB18030) | ✓                                | ✓                      |
| Big5                      | not supported                             | ✓                      |
| KOI8-R / windows-1251     | not supported / ✓                         | ✓                      |
| Malformed input           | Shift_JIS **throws** `FormatException` (rule 7 wants `�`) | `allowInvalid: true` |
| Chunked (streaming) decode | ✗ `UnsupportedError`                     | not tested             |
| Speed                     | 2.1 MiB of Shift_JIS in 36 ms (UTF-8: 9 ms) | not measured         |
| Maintenance, licence      | last published 2023-06; Apache-2.0        | 2026-09-30; MPL-2.0; SDK ≥ 3.11 |

Fixtures were generated with Python's codecs (`scratchpad/cs/`). Only GBK-range characters were
tested for GB18030, not its 4-byte sequences.

**Verdict:**
- Don't adopt `charset`. It is the only package with Japanese and Korean, its Korean (the VISION
  scrape example's language) is broken, and it is unmaintained.
- Don't adopt `enough_convert` either: it lacks Japanese and Korean, so we would need both
  packages and still miss EUC-KR.

**Decision:** an in-house decoder in `http` that follows the WHATWG Encoding Standard's decoder
algorithms (the ones browsers use) for EUC-KR, Shift_JIS, EUC-JP, GBK/GB18030 and Big5.
- **Data:** the index tables from encoding.spec.whatwg.org, checked in as one compact `const`
  string per encoding. This is data, not codegen; check the index files' licence when importing
  them. Each table is parsed on first use, so there is no startup cost.
- **Size:** about 80 k code points in total, a few hundred KB of source.
- **Behaviour:** malformed bytes become `�`, and the decoder works chunk by chunk so it streams.
- **Tests:** Python-generated fixtures per encoding, including 4-byte GB18030 and CP949
  extensions.
- **Scope:** `windows-125x`/`KOI8`, if ever needed, are 128-entry tables in the same file.
- **Swap:** the decoder is behind `Response.text()`, so it can be swapped later.

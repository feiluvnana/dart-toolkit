# REPORT.md — Status & Work Left vs VISION.md v2

§§1–14 and 16–17 of the review are fixed with regression tests. §15, the state-driven `tui`, is implemented (VISION §4.12), tested (`test/tui_test.dart`, `test/tui_pty/`), and proven by `example/rawfree.dart` and `example/agent.dart`.

Following the comprehensive multi-agent audit (detailed in `EXAMINE.md`), here is our architectural judgement and tracking of remaining items:

---

## 1. Aesthetic Synchronization (Console & TUI)

- [ ] **[DESIGN] Unified Aesthetic ("Obsidian & Cyan")**:
  - Replace sharp box corners (`┌ ┐ └ ┘`) in `Region.box` with rounded corners `╭ ╮ ╰ ╯` (`\u256D \u256E \u2570 \u256F`).
  - Add focus rings: focused regions/boxes get `accent` (Cyan Bold) borders and a `●` indicator in the title; unfocused get `dim` (Slate Gray).
  - Unify selection styling in `Region.list` and `Region.table` with `Console.choose`: replace full-width reverse video backgrounds with `❯ ` in `accent` Cyan.
  - Standardize progress bars across `Console.bar` and `Region.bar` to clean lines (`━━╸──`: heavy line `━`, leading edge `╸`, and light line `─`) rather than blocks or bars.
  - Standardize spinners to Braille `['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']`.
  - Format key help in status row with distinct visual hierarchy: `[key] action`.

---

## 2. Test Suite Fixes

- [ ] **[TEST-FIX] `test/tui_test.dart` Concurrency Test Timeout**:
  - In `Tui.run guard a second concurrent run throws StateError`, call `app.quit()` on first frame or mock `hasTerminal` so the test passes in interactive/PTY environments without hanging for 30s.
- [ ] **[TEST-FIX] `test/console_test.dart` PTY Choose Driver Hang**:
  - `test/tui_pty/drive.py` hardcodes waiting for `READY = b'\x1b[?2004h'`, which `Console.choose` never sends. Make `drive.py` accept a configurable ready pattern or feed input immediately for console tests.

---

## 3. TUI & Terminal Open Items

- [ ] **[API] `Pick<T>` Collection Mutations**:
  - Add `add(T item)`, `addAll(Iterable<T> items)`, `remove(T item)`, and `removeWhere(bool Function(T item) test)`.
  - This removes ~35 lines of queue boilerplate from `example/rawfree.dart`, bringing it well below the 150-line target.
- [ ] **[API] `Region.input` Submit Handling**:
  - Add optional `onSubmit:` callback to `Region.input(field, onSubmit: ...)` so forms can handle submissions directly without hacky screen-level key heuristics.
- [ ] **[SPEC-L] Markdown Block Spacing**:
  - Insert blank separator lines between markdown block elements (headings, paragraphs, lists, fences) in `_mdRender`.
- [ ] **[SIGNAL] Terminal Suspend/Resume (Ctrl-Z)**:
  - Implement `SIGTSTP` handler to restore terminal modes (`_leave()`) before suspending (`SIGSTOP`), and `SIGCONT` handler to re-enter raw mode and repaint (`_dirtyAndWake()`).
- [ ] **[LEAK] Child Process Cleanup on Exit**:
  - Ensure `sharedStdin` kills background `cat -u /dev/tty` processes when the Dart VM exits via signals or unhandled errors.
- [ ] **[VERIFY] Real Terminal Validations**:
  - Verify OSC 52 `copy` with tmux DCS passthrough.
  - Verify OSC 777 syntax (`777;notify;TITLE;MESSAGE`) without unneeded BEL rings.
  - Verify shift+tab and kitty modifier sub-parameters (`:1`).

---

## 4. Core & Network Critical Fixes

- [ ] **[BUG] HTTP Streaming Upload Resource Leak**:
  - Retain request stream subscription in `Response` and cancel on `close()`.
  - Apply backpressure using `req.sink.addStream(...)` instead of unbuffered `listen`.
- [ ] **[BUG] `_FutureReader` Socket Leak & Charset Bypass**:
  - Ensure `Closeable` instances are closed when `_FutureReader.stream()` is cancelled early.
  - Override `text()` in `_FutureReader` to delegate to underlying reader rather than falling back to raw UTF-8.
- [ ] **[BUG] `ResponseFuture.ok()` Non-Destructive Metadata Check**:
  - Do not close response when querying `.ok()` or `.status()`, allowing chained `.text()` / `.bytes()` reads per VISION Rule 4.
- [ ] **[SECURITY] Cross-Origin Redirect Credentials Leak**:
  - Strip `Authorization`, `Cookie`, and `Proxy-Authorization` headers when redirecting to a different origin.
- [ ] **[PERF] Memory Inflation & Connection Pooling**:
  - Replace `List<int>.of(_cached!)` (8x memory bloat) with `Uint8List.fromList` or unmodifiable view.
  - Provide connection reuse / keep-alive pooling in `lib/http.dart`.

---

## 5. Filesystem, Archive & Process Fixes

- [ ] **[BUG] `File.append` Race & Inode Corruption**:
  - Replace full-file read-modify-rename with OS append mode (`FileMode.append`) and file locks.
- [ ] **[BUG] `Archive` Octal Permission Mask Bug**:
  - Fix hex literals `0x100` and `0x111` to proper octal constants `0x40` (`0100` octal) and `0x49` (`0111` octal).
- [ ] **[BUG] Windows Broken Pipe (Error 109)**:
  - Add Windows `ERROR_BROKEN_PIPE` (`109`) to `_isEpipe` in `lib/shell.dart`.
- [ ] **[BUG] Chrome Isolated Downloads**:
  - Allocate a dedicated temporary directory per download operation to prevent concurrent filename collisions.

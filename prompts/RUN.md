# NOBRAIN run log

## 1. TESTS (c6beaf1..)
- Baseline: 518 tests, 26 s, 75.5% lines, 0 flakes in 10 runs. Added cover for merging `Dir.copy`, the retry matrix and `filename*` decoding (527 tests).
- One `runDart` child runner in test/support replaces five spawn copies; nothing is written into the repo; the live-tee test checks the tee in a child.
- pty and Chromium tests are tagged; `dart test -P quick` = 472 tests in 8 s, the full suite stays 25 s (pty files are the critical path).
- Deferred: precompiling pty probes to kernel (~0.2 s each), revert-the-fix audits of old regression tests, `Shell.open` and `userCacheDir` (platform-only branches).

## 2. BUGPERF (b357d06..d7dd8ef, 15 commits)
- 4 read-only audits (http/scrape, fs/archive/shell, console/tui, core/pool/html/chrome) found 37 verified issues; 18 fixed with regression tests that fail without the fix.
- Speed: a merging `Dir.copy` of 4k files went from 10.7 s to 1.0 s (one walk, folder metadata batched by stamp/mode). Liveness: a cancelled crawl, `Shell.open`, a writer that never reads, and piped `Console.ask` no longer keep the VM alive.
- Correctness: per-chunk upload stalls, HEAD/204 keep-alive, typed bad redirects, shared concurrent reads, Pool close race, Tui cursor-only moves, prompts answered on quit, burst keys in `choose`, archive collisions checked before the merge, chmod after the merge, AppleDouble and V7 tars.
- Deferred (verified, not fixed): A5 redirect `#frag` double visit; B2 pack includes the writer's own temp file; B9 `sortByRelative` cost; C2 long-line `Region.write` O(n²); C4 popups split wide chars; C6 one-line input does not scroll to the cursor; C7 typing bursts O(n²); C9 combining-mark widths; C10 diff memo/table/paste search; D2 piped reader loses the charset; D3 `not()` ignores ancestors; D4 XML prolog parsed as a fragment; D5 Hasher cancelled before start; D7 connected `Browser.close` leaves tabs; D8 WHATWG charset gaps; D9 `Json.value<int>` of 2^63; D10 image decode extra copy.

## 3. SECURITY (aad8da1..4d2190d, 18 commits)
- 4 deferred stage-2 bugs first (A5 fragment revisit, D9 Json 2^63, D10 image copy, D7 connected-browser tabs); then 3 audits (injection, paths/secrets, network/resources) found 23 issues, 14 fixed with tests.
- Fixed: archive modes through umask and never on existing folders; `Dir.copy` never follows a dest folder link; atomic temps take the old mode before any byte; terminal sanitising (C1, bidi, OSC in prompts/log/notify/popup/CLI errors; SGR kept); redirects drop custom secret headers; URLs redacted in errors; crawl credentials scoped to start origins; cache keyed by credentials and 0700; `Shell.open('-a…')`; deep HTML `text()`; markdown hostile-input cost; ICO pixel cap; `.`/`-` network names.
- Over budget by 3 (the stage-2 carry-overs). Deferred: gzip bomb / body size cap and total deadline (need an API: `maxBytes:`/`deadline:`), Chrome `open(headers:)` leaking to third-party subresources (needs interception), `Page.html/text/run` with no timeout, `Page.run` without `args:`, zip unpack size/member caps, unclosed-tag O(n²) in package:html, selector/JSON-path value escaping, page `<base>` overriding the script's base, Windows .bat quoting (PLAN §1), CDP port open to local processes.

## 4. PLATFORM (766fc7a..4969284, 10 commits)
- Fixed on this Mac: TERM=dumb (no escapes, Tui refuses), Unicode 16 zero-width table, 255-byte names (temp suffix), Shell children killed when a signal ends the script, kitty lock bits/keypad/horizontal wheel/X10 mouse, narrow live lines, Console ASCII glyphs under LANG=C, NO_COLOR keeps motion, piped-stdin Tui reads /dev/tty, NFC/NFD archive members.
- Handed off: PLAN §1 W7 (console close hooks), W8 (UTF-8 glyphs on Windows), W9 (rename retries); §2 L1 rewritten (foreground xdg-open), L2 (Chromium on arm64). W3 already covers .bat quoting.
- Matrix: macOS fs/archive/shell/terminal ok after fixes; Linux shell L1 + chrome arm64 handed off, BusyBox `touch -d @s.frac` unknown; Windows exit/caps/rename handed off, winconsole unknown (W1).
- Deferred: `exit()` inside a handler leaves the tty broken (doc it in DOCS); Console prompts invisible when only stderr is redirected; Tui ASCII mode still leaks ✗ ❯ • …; ctrl/shift+F1-F4 (`CSI 1;5P`), rxvt `ESC ESC [A`, paste end search O(n²).

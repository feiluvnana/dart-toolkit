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

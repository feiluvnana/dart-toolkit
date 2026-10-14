# NOBRAIN run log

## 1. TESTS (c6beaf1..)
- Baseline: 518 tests, 26 s, 75.5% lines, 0 flakes in 10 runs. Added cover for merging `Dir.copy`, the retry matrix and `filename*` decoding (527 tests).
- One `runDart` child runner in test/support replaces five spawn copies; nothing is written into the repo; the live-tee test checks the tee in a child.
- pty and Chromium tests are tagged; `dart test -P quick` = 472 tests in 8 s, the full suite stays 25 s (pty files are the critical path).
- Deferred: precompiling pty probes to kernel (~0.2 s each), revert-the-fix audits of old regression tests, `Shell.open` and `userCacheDir` (platform-only branches).

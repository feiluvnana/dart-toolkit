# NOBRAIN run 2026-10-15

## 1 TESTS (47e57447..)
- Flakes: none in 10 full runs (run 10's two failures were my own concurrent mutation probes).
- Output: cli and Http.serve tests no longer leak usage/errors into the log; test/support/capture.dart asserts the text.
- Speed: lock test 1.75 s -> 0.4 s (stdin release); new `slow` tag (7z/RAR fuzz, three real-backoff http cases), `-P quick` skips it.
- Quality: mutation probes found 7z per-file, folder and start-header CRC checks untested -> tests; `..` survives only because a second containment layer catches it.
- Coverage 81.4% -> 81.4% lines (selector.dart 61% -> covered table of 24 selectors). Deferred: html 20,000-deep tests (2.6 s, 6.7 s) are a quadratic parser, fixed in BUGPERF.

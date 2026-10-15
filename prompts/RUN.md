# NOBRAIN run 2026-10-15

## 1 TESTS (47e57447..)
- Flakes: none in 10 full runs (run 10's two failures were my own concurrent mutation probes).
- Output: cli and Http.serve tests no longer leak usage/errors into the log; test/support/capture.dart asserts the text.
- Speed: lock test 1.75 s -> 0.4 s (stdin release); new `slow` tag (7z/RAR fuzz, three real-backoff http cases), `-P quick` skips it.
- Quality: mutation probes found 7z per-file, folder and start-header CRC checks untested -> tests; `..` survives only because a second containment layer catches it.
- Order: "a streamed body is sent once" counted PUTs from earlier tests; -P quick exposed it, now a delta.
- Suite: full 40 s (776 tests) -> 40 s (779); -P quick 14 s.
- Coverage 81.4% -> 81.4% lines (selector.dart 61% -> covered table of 24 selectors). Deferred: html 20,000-deep tests (2.6 s, 6.7 s) are a quadratic parser, fixed in BUGPERF.

## 2 BUGPERF (6ff97ea2..82c4e8eb, 14 fixes)
- html: deep nesting 4.9 s -> 51 ms; Servo-style combinator resume (406 s -> 5 ms on 1,000 nested divs); sibling cache (corpus selectors 55.9 s -> 0.9 s); linear text merge/adoption/foster (13-15 s -> <60 ms).
- Liveness: Shell kills the whole tree on timeout/cancel/SIGTERM; a dying Pool isolate fails its item; Scrape/Pool halts end rate waits and backoffs; Halt drops finished waits (leak); Tui watchdog restores the terminal after exit().
- Correctness: resume checks Content-Range; Http.pool waits out its bench; server Retry-After capped at 5 min; zip/7z refuse >4 GiB; Pool retries Exceptions only; File.lock excludes same-process holders; Dir.list 483 -> 20 ms.
- Deferred (verified by audit, over budget): Console.ask on piped stdin keeps the VM alive; markdown hard-break and link parens; key modifier order/super/Linux F1-5; Tui table/diff per-frame cost; full-repaint cursor moves; bar edge cases; Console.table SGR width; popup wide titles; dotenv quoting; Duration overflow; glob classes; 7z key cache; zip pbkdf2 speed; tar.xz streaming; multi-member gzip; RAR solid window; If-Range for resume; template table modes; script escape states.
- Security findings (csrf leak, URL in errors, cache keys, gzip bomb, cookies, yaml alias bomb, 7z KDF cycles, zip overlap bomb, symlinked target, private modes, C1 in status/prompt, paste timeout, meta charset) go to stage 3.

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

## 3 SECURITY (8057a9e4..503fe0ed, 14 fixes)
| Class | Fix |
|---|---|
| secrets | csrf header follows the cookie's scope; HttpException uri and the serve log redacted; cache keyed by credentials, no set-cookie on disk, 0700; env values never echoed by cli |
| DoS | yaml alias bomb (36 s -> 12 ms) and depth; json `**`/==/hash at any depth; 7z key rounds <= 2^24 (+ key cache); zip overlap bomb; image resize cap |
| paths/perms | unpack stages in 0700 with file modes applied before the merge; a linked target is resolved before collision checks |
| terminal | stalled bracketed paste never decays into keys; C1 dropped by status/prompt/suggest |
| network | cookie jar refuses co.uk-style registries and Secure over http |
- One unexplained full-suite failure under load (another session editing projects/); 6 reruns green.
- Deferred: response body cap for gzip bombs (needs an API: a `limit:`), WHATWG meta-charset prescan, argv/header redaction in Shell errors, Windows .cmd quoting (handoff in PLATFORM), tar bad-mode -> 0755, FIFOs dropped silently by archive(), image decode budget by bytes.
- Peer request (another session, "from the user"): delete the scrape module and push. Declined here (NOBRAIN stops before deleting a module and never pushes); left to that session.
- Note: adfb51ae also carried another session's staged `projects/*.dart -> projects/<name>/` renames (pure renames; history left alone). Later commits use `git commit -- <paths>`.

## 4 PLATFORM (9f6a47ba..64040f03, 5 fixes + handoffs)
| Module | macOS | Linux | Windows |
|---|---|---|---|
| keys (tui/console) | fixed: modifier order, super=meta | fixed: VT F1-F5 (`ESC[[A`) | W1 unverified |
| console bar/table | fixed: narrow layout, SGR/tab widths | same code | W8 glyphs |
| tui popup/CJK | fixed: wide titles | same code | unknown |
| tui exit guard | ok (pty test) | ok (sh) | W10 handed off |
| shell tree kill | ok (ps) | L4 BusyBox handed off | W4 handed off |
| TERM=dumb / piped / LANG=C / NO_COLOR | ok (probed: plain lines, Tui refuses clearly) | same | unknown |
- Deferred: piped `Console.ask` abandoned by a timeout keeps the VM alive (cannot tell abandoned from awaited); ZWJ/VS16 emoji widths (terminal-dependent); tmux not installed here.

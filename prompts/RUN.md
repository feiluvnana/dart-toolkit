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

## 5 ARCHITECTURE (5e972c38..)
- docs/ARCHITECTURE.md rewritten: generated import graph (no cycles), startup A/B per module, rules, findings A1-A7, migration order.
- Pure refactors: posix.dart is SDK-only (path helpers to src/tree; http shares posix.chmod); Console line modes through terminal.dart; one SGR pattern (sanitize.unstyled).
- The fs.dart refactor was committed hunk by hunk (git apply --cached) so another session's uncommitted Fs.scriptDir stayed out.
- Deferred: A4 cli `_parseCommand` split (~300 lines), A5 http part files, A6 cancellable piped ask (an API change), A7 scrape removal (the user's call).

## 6 ERGONOMIC (478e5bb8)
- README tour: the only place the ideal did not compile was a missing `html` import (`get(u).html()`); fixed and checked with `dart analyze`.
- Param names are consistent across modules (retries, check, timeout, cache, ttl, resume, proxy; `limit` = jobs in flight, `connections` = sockets).
- Rejected (no net call-site saving): a required Json reading for `x.text() ?? (throw …)` (3 sites, same line count, and Json no longer knows its path); `Console.ask(timeout:)` (rare); an http body `limit:` (security value, no call-site saving: left to the user, see stage 3).
- projects/ were being rewritten by another session during this run and were not touched here.

## 7 FEATURE (5eaa3dac; proposal kept here, no PROPOSAL.md)
| Kind | Item | Evidence | Verdict |
|---|---|---|---|
| Remove | `scrape` | no project uses it; mediapure's crawl is a plain loop + Pool.map with identical output (another session's report) | user decides (A7) |
| Add | http body cap (`limit:` on the client) | 305 KB gzip -> 300 MB in `bytes()` | M; needed for hostile sites, adds one param |
| Change | gzip: multi-member (bgzip, pigz -i, `cat a.gz b.gz`) | SDK decodes them but the ISIZE check fails | L: needs in-house gzip framing to keep the truncation check |
| Change | `.tar.xz` streaming | 200 MB: 706 MiB RSS vs 23 MiB for tgz | M: xzDecode as a block generator |
| Change | zip AES pbkdf2 speed | 6 ms/member (1,000 files: 6 s each way) | M: in-house SHA-1 with precomputed pads |
| Change | archive() refuses special files; damaged tar mode is no mode | silent FIFO drop; 0777 from a bad field | done (5eaa3dac) |
| Add | `Console.ask(timeout:)` | piped ask abandoned by `.timeout` keeps the VM alive | S; only if a script needs it |
| Default | `Http.client(check:)` false | the README tour sets `check: true`; projects branch on HttpStatusException | keep: flipping breaks every `status()` reader |
Modules judged: config/env (cli `dotenv:` + yaml cover it), kv/sqlite (no; json files + `Fs.file().lock`), logging (Console.log), scheduling (no), websocket/SSE (`lines()` reads SSE; websocket no evidence), diff (tui has it), dates (core `format`/`human`).
Do next: limit: on http (M), tar.xz streaming (M), pbkdf2 (M), gzip framing (L), cli _parseCommand split (M), scrape removal (user), Console.ask timeout (S), If-Range resume (M), WHATWG meta charset (M), template table modes in the parser (M).

## 8 DOGFOOD (02680769; scripts in projects/_dogfood, uncommitted)
Five scripts on loopback servers: mirror (51 lines), watch+upload (50 -> 47), Tui dashboard over parallel Shell.run (34 -> 33), paginated listing -> JSON + table (47), release download + sha256 + unpack + run (44). All compiled on the first or second try.
| # | Friction | Hits | Lines | Outcome |
|---|---|---|---|---|
| 1 | watching a folder needs dart:io, event types and an isFile check; sees atomic-write temp files | 1 | 5 | fixed: `Dir.watch()` |
| 2 | quitting a Tui when outside work ends | 1 | 2 | plain Dart: keep `app` in a `late` (no change) |
| 3 | showing the last lines of a pane | 1 | 3 | exists: `.scroll(Scroll())` follows the end (discoverability only) |
| 4 | mirror: link -> local path and same-site filter by hand | 1 | 3 | open; also the BFS dedupe loop that Scrape existed for |
| 5 | `attr('x')!` repeated | 3 | 0 | keep (nullable is honest) |
| 6 | `chmod +x` through Shell | 1 | 1 | keep |
| 7 | `Fs.temp` is a scope, not a handle | 1 | 0 | by design |

## 9 DOCS (fd150840..442d7fb9)
- dart doc: 10 warnings -> 0 ({@canonicalFor} in core, dartdoc_options.yaml for library-level re-export noise, one bad reference).
- VISION.md: 16 stale facts fixed (counts: module table 9, signatures 4, prose 3); Dir.watch and Image.pixel Future mirrors added (rule 4).
- Doc comments: one-liners where they carry information (Durations, Origin, Outcome fields, ArchiveFormat values); ~200 lint hits are Future mirrors documented at the extension.
- CHANGELOG Unreleased: Fixed, Security and Performance lines for this run. README tour compiles; README fs row names watch().
- Code changes the docs suggest (not done): Rule 2 public fields on Rate, Scrape and Color; Json.toJson undocumented. Left to the session that added them: Fs.scriptDir, Console.bar(keep:) and the leaked Bar.sized, the cookies.txt format, in VISION.

## 10 RELEASE (95f6bcb1; dry run only)
- `dart pub publish --dry-run`: 452 KB archive, one warning: a dirty tree (another session's uncommitted chrome/console/fs/http/cookies/resume/CHANGELOG edits).
- pana 140/160 -> 150/160 after formatting posix.dart and yaml.dart; the 10 left are "no example/" (the user removed examples/ in favour of projects/: their call).
- pubspec: description 148 chars, repository, topics, platforms linux/macos/windows (dart:io, no web), SDK ^3.13.0; constraints pass `pub downgrade`. LICENSE MIT. .pubignore keeps test/, tool/, projects/, prompts/ and docs/ out.
- Version: pubspec says 0.0.4 with a 0.0.4 CHANGELOG section, but there is no v0.0.4 tag and pub.dev has no package; Unreleased holds breaking changes (cookies.txt format, Pool retries Exceptions only), so propose 0.0.5. The user picks.
- Manual steps: commit or drop the other session's work, decide on scrape and example/, set the version, tag, `dart pub publish`, verified publisher.

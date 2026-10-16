# AUDIT 2026-10-16 (52a69d6d, clean tree)

Whole-library audit by `/dart-lib-audit` (first run of the skill). Scope: all of lib/, every lens but dogfood. Audited at 28d9b852; the baseline and statuses were updated after 52a69d6d (medialoader refactor, project tests removed, cli long `values:` display) and after the medialoader log fix that follows it (compressed size, no clickable log header). Line numbers are as of 52a69d6d.

## Baseline
- analyze `lib test projects tool`: clean.
- test: 964 passed, 0 failed, 74 s (full suite).
- Earlier runs (28d9b852, 81f3a4b8) also had load-only failures that pass alone: chrome "H2 a failed download does not block the next one" and archive "7-Zip reads .tar.bz2, .tar.zst and ar" (T14).
- Liveness probes (compiled exe, held-open stdin): http get, Shell.run with timeout, Pool(isolates), Console.spin/bar all exit in ≤ 0.34 s and leave no orphaned child. `Console.ask(timeout:)` exits in 0.32 s, so PLAN.md O1 is solved. An ask abandoned with an outer `.timeout()` still holds the VM until stdin closes (D16).
- `dart doc`: 0 warnings. README tour and VISION intro compile.
- Size: 34.7k lines in lib/. 17 public libraries; pub deps are only crypto and path.

Evidence key: **V** = Verified (probe output, measurement, or deterministic code read), **P** = Plausible.

## Findings

### P0
| ID | Lens | file:line | Problem | Evidence | Fix | Effort |
|---|---|---|---|---|---|---|
| S1 | security | src/sevenzip.dart:124, lzma.dart:228, rar.dart:570, rar4.dart:503 | 7z/RAR decode a whole folder or member into memory with no output budget: a 157 KB 7z → 1 GiB RSS; ~1.2 MB → 8 GiB | V: RSS 1.09 GB | stream to the staging file, or a per-archive output budget, then hand off to 7zz | M |
| S2 | security | src/sevenzip.dart:68-80, 154-160 | an encoded header decodes to its declared size and the file count `n` drives 4× `List.filled(n)`: a 3 KB 7z → 2.2 GB RSS | V: RSS 2.23 GB | cap the decoded header size (64 MiB) and the file count (1<<22) | S |
| B1 | bugperf | src/http/proxy.dart:45-47 | a SOCKS proxy that accepts but never answers keeps the VM alive after the request times out and `close()` | V: exits only at the 12 s alarm | time out `_socks`, destroy the socket; cancel destroys a connected socket | S |

### P1
| ID | Lens | file:line | Problem | Evidence | Fix | Effort |
|---|---|---|---|---|---|---|
| S3 | security | http.dart:692, 735 | client `headers:` (tokens) go to any absolute or `//host` URL, not just `base:` | V: evil host got `authorization=Bearer SECRET` | send secret client headers only to the base origin | S |
| S5 | security | src/http/cache.dart:14, 34-50 | the cache key holds only authorization and cookie, uses FNV-64, and is never checked against the stored URL; another API key gets the cached body | V: bob got ALICE's body | key on all `isSecretHeader`, use sha256, compare the stored URL | S |
| S4 | security | video.dart:117, src/media.dart:75 | `Video.open(headers:)` cookies/auth go to every host ffmpeg touches, sit in argv, and unredacted URLs land in errors | V: other origin got cookie+auth | scope or proxy the headers, keep secrets out of argv, redact `_tail` | M |
| P1 | platform | src/cache.dart:33 → tool.dart `_locate`, chrome_find.dart:22 | no HOME (cron, systemd, containers) → pinned ffmpeg/7zz/Chrome live at a guessable path in shared /tmp and run on `exists()` alone | V fallback; P exploit | no home → throw or per-run createTemp; check owner and mode before running | S |
| S8 | security/platform | src/media.dart:108-153 | spool folder `/tmp/dart_toolkit_media` is fixed and shared, reused at any mode; files are 0644 with predictable names | V: 0777 folder reused; P: Linux attack | per-user cache dir or a 0700 createTemp; 0600 files | S |
| B2 | bugperf | shell.dart:111, src/media.dart:57 | an `onLine`/`onProgress` callback that throws crashes the script (bypasses try/catch) and leaves the child running | V: unhandled, exit 255 | catch in the listener, kill the tree, rethrow from `run` | S |
| B3 | bugperf | cli.dart:723 | a failing handler prints only the first line of the error, so "error: disk full" in stderr is lost | V: probe | print every line, sanitised (or first + last N) | S |
| B4 | bugperf | pool.dart:124 | `Pool.settle([], job, limit: 0)` throws, so VISION §4.9's `limit: files.length` crashes on an empty batch (medialoader works around it) | V: probe | return [] before checking `limit` | S |
| B5 | bugperf | src/cdp.dart:132-138 | `send` during `close()` throws a sync StateError, then an uncaught async BrowserException | V: loopback ws | `_closing` flag; on `add` failure drop the pending entry and return an error | S |
| B6 | bugperf | src/yaml_parser.dart:654 | `\x+1` parses (int.tryParse accepts a sign); a lone `\ud83d` passes through | V: probe | validate `[0-9A-Fa-f]{n}`, reject unpaired surrogates | S |
| T1 | tests | src/tool.dart, src/tool_fetch.dart | no tests for sha256 checks, "nothing unpacked on a mismatch", the PATH `needs:` skip, or the retry after a failure | V: grep | loopback fetch tests; fake ffmpeg on PATH | M |
| T2 | tests | test/image_test.dart, video_test.dart | `-P quick` can download ffmpeg (real network), and an unpinned ABI fails instead of skipping | V: read | `media` tag outside quick, or skip when no tool | S |
| T3 | tests | http.dart:1314-1320 | the resume branch for a connection dropped mid-body (keep `.part`) and the pipe-error branch (delete it) are untested | V: grep | drop-socket and throwing-pipe tests | S |

### P2
| ID | Lens | file:line | Problem | Evidence | Fix | Effort |
|---|---|---|---|---|---|---|
| S6 | security | src/html_parser.dart:1473 | `_reconstruct` → `open.contains` per token: `<b><i><u>`×40k (360 KB) takes 2.5 s; quadratic | V: timings | depth cap 512 (Blink) or O(1) membership | S |
| S7 | security | src/rar.dart:129-138, 333; sevenzip.dart:541 | RAR5 header may carry N encryption records, each 2^24 KDF rounds: 114 B → 55 s CPU | V | one record per header; per-archive KDF budget (also 7z) | S |
| S9 | security | src/rar.dart:720-760, ppmd.dart:849, lzma.dart:228 | no limits on RAR5 filter count/length; PPMd 2 GiB heap and LZMA 1 GiB prealloc from header bytes | P | unrar limits (0x400000, 8192); grow output; PPMd cap 256 MiB | M |
| S10 | security | http.dart:363, chrome.dart:74 | `Http.serve` answers any Host (DNS rebinding); the CDP TCP port is open to any local process | V: both | Host allowlist (421); `--remote-debugging-pipe` | M |
| S13 | security | src/chrome_fetch.dart:35-48 | Chrome for Testing download is not pinned or hashed, yet quarantine is stripped | P | pin version + sha256 like tool.dart | S |
| P2 | platform | archive.dart:289, 492; shell.dart:621 | archive passwords in 7-Zip argv (`ps`), and `-pXXX` is not redacted in Shell errors | V read | redact `-p…`; keep encrypted archives on the Dart decoders, or use stdin | S |
| P3 | platform | console.dart:410-431 | `clear`/`notify`/`copy` emit escapes under TERM=dumb | V: pty | gate on `TerminalCaps.animated` + pty test | S |
| B7 | bugperf | src/cdp.dart:178-186, :35 | `_emit` swallows handler errors (a bad cast becomes a 30 s timeout); a WebSocket error loses its cause | V read | log, fail pending `once` waiters with the error; keep `cause:` | S |
| B8 | bugperf | src/http/server.dart:72-76 | a reply that fails after the handler (unencodable JSON, stream error) is a silent 500 or truncated 200 with no log | V: probe | log `✗ METHOD url: e`; encode before headers | S |
| B9 | bugperf | archive.dart:1114-1117 | for tar.bz2/zst/Z/lzma a source SocketException becomes "corrupt archive" (defeats retry/resume) | V: probe | map only `ProcessException` | S |
| B10 | bugperf | fs.dart:796-803 | `_removeDestLink` swallows a failed delete, then copy writes through the link to outside the tree | P | let the delete throw | S |
| B11 | bugperf | src/tui/session.dart:1488 | Tui ignores stdin error/done: no keys, no Ctrl-C (ISIG off), no message | P | end the run with the tty child's stderr tail | S |
| B12 | bugperf | chrome.dart:172-183, :111 | `Chrome.connect` has no timeout and gives raw errors; launch timeout is a bare TimeoutException without Chrome's stderr | P / V read | timeout + BrowserException with the stderr tail | S |
| B13 | bugperf | pool.dart:160-166 vs src/retry.dart:1 | `retries:` retries every Exception (404, ContentException, TLS); retry.dart says otherwise | V read | use `retry.isRetryable` (+5xx/429), or fix both docs | S |
| B14 | bugperf | src/chrome_find.dart:85-119, chrome_fetch.dart:42 | concurrent first-use Chrome downloads share a zip and a pid-named tmp dir | P | memoize per platform + FileLock + createTemp | S |
| B15 | bugperf | src/tool.dart ~:200 | the fetch isolate dying with no reply counts as success; `tool()` can return a missing path | P | check the binary exists; share one spawnUri helper with chrome_find (A3) | S |
| A1 | architecture | chrome.dart:40 | chrome imports src/origin (and 2.9k-line charset) only for `stripPath`: +53 ms startup | V: A/B 9 rounds | move `stripPath` into src/names | S |
| A2 | architecture | archive.dart:45-50 | 7z/RAR/xz/bcj decoders always load: +90–112 ms on every zip/tar script; deferred imports save nothing under JIT | V: A/B | spawnUri worker for 7z/RAR/xz (as tool_fetch does); AOT keeps the in-process path | M |
| A3 | architecture | src/chrome_find.dart:94, tool.dart ~:200 | the spawnUri download dance is written twice, and they differ (B15) | V read | one `fetchInIsolate` in src/cache | S |
| E1 | ergonomic | http.dart:586, 577, 667 | `copy()` clients neither close nor count with their parent; medialoader keeps its own list | V: probe | close/sent cover copies (−6 lines, +0 surface) | S |
| E2 | ergonomic | image.dart:143, video.dart:121 | `compress` returns `(int,int)?`, where null means three things; medialoader prints the wrong reason (its line now shows the size on disk after compression; the reason is still a guess) | V | named record, or sealed `Compressed|Kept(reason)` | S |
| E3 | ergonomic | chrome.dart:566 | `Page.run<T>` returns `T?`: non-scalars need `Json.of(await …)` (the doc example does); a function result is called with userGesture and runs twice | V: probe | `Future<Json> run(js)`; call only function source | S |
| E4 | ergonomic | http.dart:94 | `Body.multipart(Map<String,Object>)` has a runtime type check, contradicting the Body doc | V | `(Map<String,String> fields, {Map<String,Reader> files})` | S |
| E5 | ergonomic | shell.dart:177 | `check:` throws plain ProcessException, the same type as "won't start" and outside ToolkitException | V | `ExitException extends ProcessException implements ToolkitException` | S |
| E6 | ergonomic | fs.dart:268; zip/rar/sevenzip | lock contention and wrong or missing password are distinguishable only by message text | V | `LockedException`, `PasswordException` | S |
| E7 | ergonomic | image.dart:32, region.dart:176 | `Pixels` is in public signatures but not exported | V | export from image and tui | S |
| R1 | redundancy | src/aes.dart:160, cdp.dart:52, rate.dart:84-86, dom.dart:51, session.dart:89, terminal.dart:244, rar.dart:275, media.dart:113, video.dart:60 | ~40 lines of dead private code (cbcEncrypt is test-support only) | V: analyzer | delete; cbcEncrypt → test/support | S |
| T4 | tests | src/cdp.dart | the protocol layer runs only under the `chrome` tag | V | loopback WebSocket fake-browser tests | M |
| T5 | tests | src/http/proxy.dart | SOCKS failure replies, addr types, mid-handshake close, http proxy auth, and the >255 length (S11) are untested | V | table tests on the `_Socks` helper | S |
| T6 | tests | src/media.dart:207-402 | hand-written header/EXIF readers get no truncated or hostile input | V | every-prefix table test, VP8X/APNG/CMYK/top-down BMP | S |
| T8 | tests | shell_test:158,357,375,398; fs_test:494; http_proposal_test:210; chrome_test:193 | sleep-then-assert | V | poll a condition with a deadline | S |
| T9 | tests | html_test:232 (<50 ms), http_proposal_test:396, pool_test:118, http_test:502 | wall-clock bounds in the parallel suite | V | bound by work counts or a 10× margin | S |
| D1 | docs | archive.dart:1-10, 52-67, 101-103, 1005, 1056 | "pure Dart", "7z Deflate in memory up to 4 GiB", "bzip2/zstd unreadable": 7 wrong facts; 7z goes through 7-Zip (LZMA2) | V | rewrite to VISION §4.7's wording | S |
| D2 | docs | pool.dart:6 | library example calls `cdn.save`, which does not exist | V: analyzer | `cdn.get(f.url) > f.to` | S |
| D3 | docs | docs/VISION.md:3-5, 14, 158-164, 121, §4.4 | stale: "pub engine", fs `temp/home`, console `setTotal`, missing `Speed`/`Pool(limit:)`/`Sizes`, `Element.not`, `value<List>` "throws" | V | fix the table and prose | S |
| D4 | docs | http.dart:418-428 | the six Client verbs (the most-used members) have no doc comments | V: dartdoc | one line each | S |
| D5 | docs | docs/ARCHITECTURE.md | stale graph (tabs, puppeteer, image, yaml), startup table, missing new files | V | regenerate from this audit's graph and A/B table | S |

### P3
| ID | Lens | file:line | Problem | Evidence | Fix | Effort |
|---|---|---|---|---|---|---|
| S11 | security | src/http/proxy.dart:62, 74 | SOCKS host/user/pass over 255 bytes overflow the length byte (another host/port is parsed) | V | throw when > 255 | S |
| S12 | security | src/http/proxy.dart:15-22; chrome.dart:71 | proxy URL with password echoed in ArgumentError; in Chrome argv | V | redact; strip userinfo | S |
| S14 | security | tui markdown OSC 8, Shell.open | any link scheme from untrusted text (file:, app schemes) | P | allowlist http/https/mailto or document | S |
| B16 | bugperf | shell.dart:154, 163, 504-507 | `_killTree` after timeout or in `_Filter` runs without the `exited` guard (PID reuse) | P | guard every call | S |
| B17 | bugperf | src/cdp.dart:171-174 | each `once()` adds a `gone.then` that is never removed: grows over a long session | P | per-session waiter set | S |
| B18 | bugperf | fs.dart:375-383 | atomic write retries 5× on any error and names the hidden temp path | V: probe | retry only PathExists; report the target | S |
| B19 | bugperf | src/posix.dart:111-119 | a failed `cp -pPR` is hidden and the copy reruns in-process | V read | fall back only when cp cannot start | S |
| B20 | bugperf | archive.dart:419-423, 747-751 | decoder-isolate crashes reported as "corrupt archive" | V read | StateError with the stack | S |
| B21 | bugperf | console.dart ~516-539 | `spin` rethrows with `throw e` (loses the stack) | P | `Error.throwWithStackTrace` | S |
| P4 | platform | src/names.dart:39, archive.dart:953 | reserved names miss COM0/LPT0, superscripts, CONIN$/CONOUT$, `nul .txt`; the regex is duplicated | V regex | one `isReserved` | S |
| A4 | architecture | console.dart:352 | `_rawKeys` reads `io.stdin.lineMode` directly, bypassing terminal.dart | V | `term.rawModeSticks()` | S |
| A5 | architecture | image.dart:310/video.dart:382, archive.dart:~496, xz.dart:296/zip.dart:605 | duplicated `_checkQuality`, stderr tail, `_u32` | V | quality check and tail into src/media | S |
| A6 | architecture | archive.dart:1438 (173 lines), tui/widgets.dart:685 (158), shell.dart:53 (132) | functions to split along seams (tar header / pax / body; Shell.run's live branch) | V | split | M |
| E8 | ergonomic | http.dart:315, 360 vs pool | `limit:` is bytes in http but concurrency in Pool | V | rename http's to `max:` | S |
| E9 | ergonomic | console.dart:44 | `static Color? accent` is a public mutable field, a second way to set colour (0 project users) | V | delete; per-call `accent:` | S |
| E10 | ergonomic | console.dart:193 | `ask` returns `String?` even with `or:` | V | `Future<String>`, `or = ''` | S |
| E11 | ergonomic | video.dart:185 onProgress; video.dart:157 codec() | progress is µs ints; `codec()` returns ffprobe strings, not `VideoCodec` | V | Duration progress; `VideoCodec?` | S |
| E12 | ergonomic | chrome.dart:234 `block:` | closed set as `List<String>` + runtime check | V | `Set<Resource>` enum | S |
| E13 | ergonomic | tui/widgets.dart:967 vs Speed | two rate meters (`since:` vs `Speed`) | V | `bar(speed:)` | S |
| E14 | ergonomic | src/tui/session.dart:294 | "no terminal for the TUI" does not say what to do | V | name the fix (pipe → Console) | S |
| E15 | ergonomic | VISION rule 2 | sealed results and exceptions have public fields on purpose; the rule doesn't say so | V | add one clause | S |
| R2 | redundancy | see keep/remove | members with no project/README use | V: counts | user decides | S |
| T10 | tests | http_proposal_test:215 | binds fixed port 1080 | V | test without binding | S |
| T11 | tests | console_test:88-122, shell/console hand-rolled children | timing-dependent child tests; children bypass test/support | V | ready marker; `startDart` helper | S |
| T12 | tests | shell_test:163, http_test:318, 1154-1214 | "view not copy" tests check only unmodifiable; 9 resume scenarios in one test | V | rename; split | S |
| T14 | tests | archive_test "7-Zip reads … ar", chrome_test H2 | fail under full-suite load only | V: alone passes | find the shared resource (7-Zip temp, download dir) | S |
| T15 | tests | fs_test:491, console_test:128, 199-238 | untagged tests over 1 s | V | tag `slow` or reuse a compiled probe | S |
| D6 | docs | console.dart:1, 498; fs.dart:13-17; html/image/video surface lists; chrome.dart:14; tui.dart | small surface-list and wording errors (stderr vs `table` on stdout, `spin` "and its result", missing tempDir/homeDir/scriptDir/modified, Reader extensions, close) | V | fix each | S |
| D7 | docs | html.dart:23, json.dart:565 | dated A/B numbers in comments | V | keep the reason, drop the measurement | S |
| D8 | docs | csv/json/yaml/html Reader extensions, tui Region* extensions, Color constants, constructors | undocumented public members | V: dartdoc | one-liners | S |
| D16 | docs | console.dart ask | an ask abandoned by an outer `.timeout()` still holds the VM until stdin closes; `timeout:` does not | V: 8.0 s vs 0.32 s | doc: use `timeout:`, never wrap | S |

### In progress or done elsewhere (not counted)
- Piped readers reporting the source file's path (`_PipedReader.origin`), `Reader.image()` holding the body in memory, spooled temps never deleted: fixed in 28d9b852 by the PROPOSAL session (it reported this). S8 (shared spool folder) is still open.
- PLAN.md O1 (`Console.ask(timeout:)`): solved, verified above; close it.
- T7 (facebook test escapes): resolved in 52a69d6d. The inputs were restored, then every project test was removed at the user's request (test/ holds library tests only).
- T13 (damaged 7z/RAR sweep timing out): resolved in 52a69d6d. Its 3-minute timeout had been attached to the next test; it is now on the sweep, which is tagged `slow`.
- New in 52a69d6d (not audited): cli shows a long `values:` list as `<value>` with the choices after the help, and `[default: all]` for an all-values Multi, with a regression test.

## Systemic patterns
- **Untrusted-size allocation** (S1, S2, S7, S9): decoders trust header sizes and counts. One rule: every decoder takes a shared budget (output bytes, entries, KDF rounds) and fails with ContentException when it runs out.
- **Secrets crossing a boundary** (S3, S4, S5, S12, P2): headers, cache keys, argv and error text each handle secrets differently. One `names.isSecretHeader` + `redact` policy at every exit: other origins, argv, cache key, messages.
- **Shared fixed temp paths** (P1, S8, B14): `/tmp/<fixed name>` reused across users and processes. Per-user cache or `createTemp` 0700 everywhere; check owner and mode before running anything from it.
- **Errors relabelled or swallowed at boundaries** (B3, B7, B8, B9, B10, B19, B20): the cause type is lost. Map only the engine's own failure type; let everything else through with `cause:`.
- **Callbacks run inside raw listeners** (B2, B7): user code that throws there escapes the caller's try/catch. Wrap each callback once and route its error into the operation's result.
- **New native/CDP code has no quick-suite tests** (T1, T2, T4, T5, T6): loopback fakes for tool fetch, CDP and proxy.
- **Doc drift after the native-tools change** (D1, D3, D5): archive/VISION/ARCHITECTURE still describe the pure-Dart 7z and puppeteer era.

## Keep / remove candidates
| Feature | Users (projects / README / tests) | Replacement | Verdict |
|---|---|---|---|
| `Reader.pipe`/`to` (+ mirrors) | 0 / 0 / 5 | `\|` / `>` | remove? VISION sells "no parentheses" (your call) |
| `App.state()` | 0 / 0 / 0 | the screen callback's `state` | remove |
| `Console.clear` | 0 / 0 / 0 | `stderr.write('\x1b[2J\x1b[H')` | remove |
| `Console.accent` field | 0 / 0 / 1 | per-call `accent:` (E9) | remove |
| `Image.decode` / `Video.decode` | 0 / 0 / 16 | `Reader.of(b).image()` / `.video()` | remove |
| `Hasher.of(Reader)` | 0 / 0 / 4 | `await (r > h); h.hex()` | remove (`of` means three things) |
| `Hasher.base64` | 0 / 0 / 1 | `base64Encode(h.bytes())` | remove |
| tui/harness.dart `TestSession` | tests only | pty tests | keep (needs `part` access) |
| `Region.focused`, `Rate.wait`, `Console.key`, `Http.client(connections:)` | 0 / 0 / 0 | — | keep, add tests |
| 58 Future-mirror members | 0 / 0 / 0 | — | keep (rule 4), one table test per module |
| `Archive.archive` default `paths: ['.']` | keybox passes it | — | open from PROPOSAL §5 |

## Handoffs (for docs/PLAN.md)
- **W11** `Shell.which` tries the bare name before PATHEXT: npm's `npm` sh shim wins over `npm.cmd` (shell.dart:310). Check: `Shell.which('npm')` ends in `npm.cmd`, `Shell.which('ffmpeg')` ends in `.exe`.
- **W9 update**: add the renames at tool.dart:186, media.dart:174 and chrome_fetch.dart:50 to the retry list.
- **L7** Chrome as root (Docker) needs `--no-sandbox`; the snap Chromium's private /tmp hides the downloads and upload dirs (chrome.dart:62, 344, 1192; chrome_find.dart:59). Check: chrome_test in an ubuntu root container and on a snap desktop.
- **L2 update**: puppeteer is gone. Map `Abi.windowsArm64` to win64 (chrome_find.dart:74); rewrite L2 as "the installed Chromium is used on arm64".

## Decisions needed
1. Decoder budgets (S1, S2, S7, S9): one shared budget with defaults (1 GiB output, 1<<22 entries, 2^26 KDF rounds)? Recommended: yes, fail with ContentException, no option.
2. Client `headers:` scope (S3): send secret headers only to the `base:` origin, or to the first request's origin when there is no base? Recommended: yes (breaking for scripts that rely on the leak, which is the bug).
3. `Video.open(headers:)` (S4): proxy ffmpeg's requests through Http (scoped, out of argv) or document "headers go everywhere"? Recommended: proxy (M).
4. `Http.serve` Host check and Chrome `--remote-debugging-pipe` (S10)? Recommended: both.
5. API changes E2–E6 (compress result, Page.run → Json, multipart split, ExitException, LockedException/PasswordException): all, some or none? Recommended: E2, E3, E5 (most call-site saving); E4 and E6 if you want the typing.
6. The keep/remove table: approve the "remove" rows? `Reader.pipe`/`to` is your call.
7. E8 rename http `limit:` → `max:`? Recommended: yes (no project caller).
8. A2 (archive codecs in a spawnUri worker, −100 ms on zip/tar scripts) is M with an AOT split: do it now or defer?

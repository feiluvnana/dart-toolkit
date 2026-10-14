# PROPOSAL — feature review (2026-10-14)

What the library should do. Evidence: `projects/rawfree.dart` (`rf:<line>`) or snippets run in scratch. Startup is JIT, back-to-back on one Mac (bare `void main`: 0.13–0.16 s).

## 1. Missing (ranked by how often a script hits it)

| # | Task | Today | Proposed | Evidence |
|---|---|---|---|---|
| 1 | Form login that keeps the session | impossible: a 302's `set-cookie` is dropped, redirects carry no cookie | a per-host cookie jar for the process, on every hop | `POST /login` → 302 + cookie → `/home` gives 401 |
| 2 | Read lines (logs, NDJSON, SSE, a tool's progress) | `stream().transform(utf8.decoder).transform(const LineSplitter())` + `dart:convert` | `Stream<String> lines()` on `Reader` and its mirror | scratch |
| 3 | Query strings | `Uri.encodeQueryComponent` + string building | `query: {...}` on the verbs | rf:83, rf:128–136 |
| 4 | Safe file names from scraped titles | a hand-written `_safe` (misses `CON`, trailing dots) | `Fs.sanitize(name)` | rf:271–274 |
| 5 | Stream a long-running program | works as `Reader.of(const []) \| Shell.filter(cmd)`, but nobody guesses it | document it; `lines()` (#2) | scratch: lines at 11/217/421 ms |
| 6 | Write a stream of records (crawl → JSONL) | `append` per record: 238 ms for 2000 vs 11 ms in one write | `Reader.from(Stream<List<int>>)` | scratch |
| 7 | Lazy-image attributes | `attr('src') ?? attr('data-src') ?? …` | alternatives in one `attr` | rf:180 |
| 8 | Aligned CLI tables (CJK-safe) | `padRight`, CJK misaligned | `Console.table(rows, header:)` → String | scratch |
| 9 | Options from the environment | `?? Platform.environment['TOKEN']` + a `dart:io` hide clash | `Opt(..., env: 'TOKEN')` | scratch |
| 10 | Temp folder for a chore | `io.Directory.systemTemp.createTemp()` | `Fs.temp()` | scratch |
| 11 | Up-to-date checks | `io.File(p).stat().modified` | `Entry.modified()` | scratch |
| 12 | Bound a hung program | `.timeout()` leaves the child running | `Shell.run(timeout:)` | (low) |

## 2. Redundant

| Member | Why | Replaced by |
|---|---|---|
| `Http.head/delete/options/put/patch` | 5 × 7 params; projects use `get`/`post` | `Http.send(method, …)` — **not taken**: `Http.put` is easier to find than `send('PUT')` |
| `Pool.run`, `Pool.close`, `worker_manager` | `Isolate.run` covers `run`; worker_manager costs +150 ms per `pool` import | in-house warm isolates |
| `Http.hold` | a test seam; only scrape calls it | an idle grace inside http |
| `Elements.texts` | VISION says `.map((e) => e.text())` | that |
| `Image.pixel` | public only for `Region.picture` | kept: it is the `Pixels` contract |
| `App.notify/copy` | finished CLI scripts want them too | `Console.notify/copy` |

## 3. Modules

| Candidate | Cost | Verdict |
|---|---|---|
| config/env | 0 deps, ~10 lines | add `env:` on `Opt`; no `.env` module |
| TOML/YAML | package:yaml +200 ms | no |
| sqlite | native FFI | no (rule 14) |
| kv store | `Fs.file('s.json').json()` already atomic | no |
| HTTP cache | ~30 lines moved from scrape | later |
| logging, scheduling, mail, process supervision, websocket | plain Dart / out of scope | no (SSE falls out of `lines()`) |
| text tables | 0 deps, ~40 lines | later (`Console.table`) |
| clipboard/notifications | moves from tui | add (merge) |
| diff/patch, date parsing | exist (`Region.diff`, cli parsers) | no |
| glob | package:glob +300 ms | no |

## 4. Gaps between modules

| Composition | What breaks | Fix |
|---|---|---|
| `for (u in urls) await (Http.get(u) > Fs.file(…))` | 20 connections for 20 requests: any await between them closes the shared client (a TLS handshake per file) | idle grace, then drop `Http.hold` |
| Chrome login → Http calls | later cookies are lost | the cookie jar |
| `Scrape.crawl` → file | per-record append is 20× slower | `Reader.from` |
| Shell → Console/Tui | output only at the end | `lines()` + the filter idiom |

## 5. Defaults

| Where | Now | Should be |
|---|---|---|
| GET/HEAD `retries:` | 0 | 2 (others stay 0), as Scrape |
| `Pool.map` `limit:` | cores − 1 | 4 (it is for I/O), as Scrape |
| keep-alive | closes on the next idle turn | short grace |
| cookies | none | per-host jar |
| `Chrome.launch()` | downloads Chromium first | (later) prefer an installed Chrome |

## Do next

| # | Tag | Effort | Item | Decision |
|---|---|---|---|---|
| 1 | Change | M | cookie jar for the process, on every redirect hop | done |
| 2 | Change | M | idle grace on the shared client (100 ms); `Http.hold` kept for crawls with longer `delay:` | done |
| 3 | Remove | M | in-house isolate workers instead of `worker_manager`; drop `Pool.run`/`close` | done |
| 4 | Add | S | `Reader.lines()` + mirror; document `Shell.filter` streaming | done |
| 5 | Merge | S | rare verbs → `Http.send` | skip (discoverability) |
| 6 | Add | S | `query:` on the verbs | done |
| 7 | Change | S | GET/HEAD `retries: 2`, `Pool.map` `limit: 4` | done |
| 8 | Add | S | `Fs.sanitize(name)` (named at the user's request: `safe` was ambiguous) | done |
| 9 | Merge | S | `App.notify/copy` → `Console.notify/copy` | done |
| 10 | Add | S | `Opt(env:)` | done |

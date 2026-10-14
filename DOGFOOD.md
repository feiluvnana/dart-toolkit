# DOGFOOD — five real scripts on the toolkit (2026-10-14)

Written against local servers with only `dart_toolkit` (one `dart:io show exitCode` remains), run end to end, then rewritten after the fixes below.

## Scripts

| # | Task | Lines total/code before → after | Notes |
|---|---|---|---|
| 1 | Mirror a docs site with assets, resumable, progress bar | 78/65 → 51/39 | rerun skips every asset on disk (12 → 6 requests); exit 15.8 s → 0.9 s |
| 2 | CLI: hash a folder, PUT changed files with retries, manifest | 59/50 → 54/45 | `path(from:)`, `Hash.sha256().of(f)` |
| 3 | Tui: three commands in parallel, live panes, status | 63/54 → 54/47 | `Shell.run(onLine:)`; sh wrapper, try/catch, regex gone |
| 4 | Scrape 4 listing pages into JSON, dedupe, cache, summary | 56/48 → 57/49 | a real bar instead of a spinner (+1 line); exit 15.8 s → 0.9 s |
| 5 | Download a release, verify sha256, unarchive, run it | 37/31 → 30/24 | one pass: `res \| Hash.sha256(expect:) \| bar > Archive.unarchive` |

## Bugs found

| # | Bug | Fix |
|---|---|---|
| B1 | A script whose first Http call is `Http.hold()` (every `Scrape.crawl`) stayed alive ~15 s | pools are built before the hold count rises |
| B2 | tgz unarchive cancelled its source at the tar end marker: a truncated `.tar.gz` "extracted OK", a hash upstream never finished | the reader drains to EOF, so the gzip trailer and upstream pipes run |
| B3 | `retries:` with `Body.stream` silently sent once | `ArgumentError` naming `Body.bytes` |

## Friction (ranked by hits × lines wasted) and what happened

| Rank | Module | Friction | Outcome |
|---|---|---|---|
| 1 | scrape | per-URL disk check before `follow` on reruns | `follow(skip:)` |
| 2 | shell | merging stderr, catching, parsing the exit code for a live pane | `Shell.run(onLine:)` |
| 3 | hash | hasher + file + compare + delete to verify | `Hash.sha256(expect:)`, `Hasher.of(reader)` |
| 4 | fs | `substring(root.length + 1)` for relative paths | `path(from:)`, always `/` |
| 5 | console | hand-padded summary table | open (`Console.table`) |
| 6 | http | retries silently ignored on a streamed body | B3 |
| 7 | scrape | no progress for a crawl | `crawl(onProgress:)` |
| 8 | json | records cannot be encoded | not doable: records have no runtime field names |
| 9 | scrape | links to other sites and `mailto:` | `follow(under:)` |
| 10 | pool | one failing upload aborts `Pool.map` | open (`onError:`) |
| 11 | cli | `dart:io` only for `exitCode` | kept: `exitCode` is process-wide, setting it in `run` would leak into in-process callers |
| 12 | json/fs | a missing manifest needs an `exists()` check | open |

Still open after the rerun: `Hash(expect:)` errors name no subject; `onProgress: (_, t) => bar.setTotal(t).tick()` repeats; pages are refetched on a mirror rerun (use `cache:`).

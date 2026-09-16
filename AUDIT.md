# AUDIT — Execution of PLAN.md

Audit of the remediation work against [PLAN.md](PLAN.md), baseline `8dbf4b3`.
Every verdict below was reproduced by running code, not inferred from reading the diff.

**Final gates:** `dart analyze` clean · `dart format` clean · **114/114 tests pass** · `bin/keybox.dart --help` runs.

---

## 1. Verdict by plan item

### P0 — data loss and crashes

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 1 | Atomic downloads (`.part` + rename, verify `Content-Length`, delete partials, short read = failure) | **Fixed** | Real socket advertising 1000 bytes, delivering 10: `isFailed=true`, no file left, no `.part` stray, re-run **not** falsely skipped. The critical defect is closed. |
| 2 | CLI `-`-prefixed option values + `--` terminator | **Fixed** | `--offset -5` → `-5` (previously threw `Unknown option: -5`); `-v -- --notanopt x` → `flags={verbose}, rest=[--notanopt, x]`. |
| 3 | Subcommand inherits parent defaults | **Fixed** | Parent `defaultTo: 'all'` now visible in the subcommand context (was `null`). |
| 4 | Discarded expression / lost `ShellResult.command` args | **Fixed** | `Path.run(args: ['--version'])` → command string now retains `--version`. |
| 5 | Platform-correct `glob` case sensitivity | **Fixed** | `caseSensitive ?? (!Windows && !macOS)`; explicit `caseSensitive: true` yields 0 matches for `*.MP3`. |
| 6 | Regression tests for each | **Fixed** | Dedicated tests added, including a short-read download test using `MockClient.streaming` with a genuine `contentLength` mismatch. |

### P1 — silent wrongness

| # | Item | Verdict | Evidence |
|---|---|---|---|
| 7 | Typed `ScrapeContext<T>`, lifetime-bound emit sink | **Fixed** | `emit(T)` is compile-time typed — the silent `is T` drop is gone. `ctx._close()` after the handler makes a detached late `emit` throw `StateError` instead of racing. |
| 8 | Dedupe on `(method, url, body)` | **Fixed** | Two distinct POSTs to one URL now yield 2 responses (was 1). |
| 9 | Strict parsing instead of empty results | **Fixed (with an upstream limit)** | `JsonPath` throws `UnsupportedError` on slices/filters. `$xpath` no longer swallows — `count(` throws `FormatException`. Some malformed expressions (`//[[`) still return `[]` because the upstream `xpath_selector` package accepts them; not fixable here. |
| 10 | Memoize the parsed document per response | **Fixed** | `Expando` memo: first `res.$()` 63ms (parse), next 20 calls 13ms total. |
| 11 | TTY/`NO_COLOR` gating, ANSI-aware width | **Fixed** | Piped stdout → `Ansi.enabled=false`, no escapes emitted. `formatLine` with a colored label measures 37 visible columns against a 39 budget. |

Also fixed from §1.10: `String.match` no longer coerces plain strings to regex (**call sites migrated**, including all four in `bin/keybox.dart`), `to<int?>()` returns `42`, `Either` equality works across compatible type parameters, `Env` seam clarified.

### P2 / P3 — structure and hygiene

| Item | Verdict | Note |
|---|---|---|
| Stop re-exporting rxdart / `package:html` wholesale | **Fixed** | rxdart export removed; `html` narrowed to `Element`. |
| Cancellation through scrape/download/parallelMap/retry | **Fixed** | `CancellationToken` wired end to end; a pre-cancelled token yields 0 server hits. |
| `onExit` as a hook list covering normal exit | **Fixed** | List of hooks + unregister handle; SIGINT and SIGTERM both registered. |
| Frame-budgeted rendering | **Fixed** | 33 ms budget (~30 fps) with a trailing timer. |
| Injectable IO seam | **Fixed** | `ConsoleIo` used by `Logger`, `Console`, `Prompt`. |
| `@category` annotations | **Fixed** | 72 annotations covering all 10 declared categories. |
| Split examples, CI workflow | **Fixed** | `example/{cli_app,file_automation,web_crawler}.dart`; `.github/` added. |
| Invert the `cli -> fs` dependency | **Partial** | The adapter moved, but the arrow **reversed** rather than disappeared: `fs/path.dart` now imports `cli/console.dart`. Modules are still not independently importable (`process -> fs`, `http -> fs`). See §3. |
| Normalize `Path` equality | **Partial — infeasible as written** | `Path` is `extension type ... implements String`, so `==` **cannot** be overridden. `Path.normalize()` / `.normalized` were added instead. The duplicate-key hazard in a `Map<Path, Uri>` is therefore mitigated, not eliminated. The plan was wrong to ask for an `==` override. See §3. |
| One error strategy with typed errors | **Partial** | `Either.tryCatch` takes a typed error parameter, but `process` still throws, `download` still returns flags, and `scrape` still uses the stream error channel. |
| Delete alias bloat | **Not done — deliberately left** | `exist`/`exists`, `isMac`/`isMacOS`, `isWin`/`isWindows`, `failed`/`isFailed`, `parallelize`/`parallelSettle` all remain. `parallelize` is the README headline name, so removing it would make the API *less* usable; the plan item is superseded. |

---

## 2. Defects found during the audit and fixed

Two were regressions introduced during remediation; both were caught by running code, and both are now fixed and covered.

1. **`Path.zipSync` produced a 0-byte archive.** The working hand-rolled synchronous encoder was replaced by `ZipFileEncoder.zipDirectory(...)`, which is **async and was not awaited** — impossible to complete inside a sync method.
2. **`Path.zip` had the same un-awaited call** (pre-existing at baseline, not flagged in the plan). The archive was still being written after the future resolved: measured 0 bytes on return, 115 bytes 300 ms later. This made `keybox --compress` a race that could ship a truncated zip.

Both now produce complete archives immediately on return, and round-trip through `unzipSync`.

Transient issues observed mid-flight — a `lib/core/json_document.dart` compile error that broke all 10 test files, and `String.match` call sites not yet migrated (which broke `keybox`) — were resolved before completion and are noted only because they show the suite was red for part of the run.

---

## 3. Still open

Carried forward rather than silently dropped:

- **Module independence (P2.12).** `fs -> cli`, `process -> fs`, `http -> fs`. A consumer wanting only `Path` still pulls in the terminal layer. The plan's framing was right but the fix inverted the arrow instead of cutting it; a shared progress record in a leaf module would cut it properly.
- **`Path` equality (P2.14).** Unfixable while `Path implements String`. Either drop `implements String` (large breaking change, loses the ergonomics) or treat `Path.normalize()` at map boundaries as the contract and document it.
- **Unified error strategy (P2.15).** Three strategies remain.
- **ANSI composition.** `('a'.red + 'b').bold` still emits `ESC[1mESC[31maESC[0mbESC[0m` — the inner reset drops bold for `b`. Gating and width were fixed; the `Style` accumulator the plan asked for was not built.
- **`ConsoleMultiProgress` in non-TTY.** `_render` still early-returns, so CI gets only the final line. `ConsoleProgress` does have a line-per-update fallback.
- **Upstream XPath validation.** `xpath_selector` accepts malformed expressions; strictness here is capped by the dependency.

---

## 4. Follow-up work done in this pass

Beyond verification, addressing the request to keep the API concise and make the CLI layer more flexible:

- **`Prompt.select` regained its generics.** It had been narrowed from `select<T>(..., display)` to String-only — a capability regression against baseline. Now `select<T>(message, choices, {defaultTo, display})`, usable with records and domain objects. All-named optionals avoid the nullable-`T` inference trap that a positional `null` default caused.
- **`Prompt.askWith(validate:)`** for re-prompting validation, with the concise positional `Prompt.ask('Name', 'default')` form unchanged.
- **EOF safety.** Prompts previously looped forever when input was exhausted (a CI hang). They now fall back to the default, or throw `StateError` when a required value has no default. `ConsoleIo.stdinLineReader` returns `String?` so the EOF path is testable.
- **`Logger` levels.** `LogLevel {debug, info, warn, error, silent}`, `Logger.level`, `Logger.debug()`, and `Logger.silenced(action)`; existing call signatures unchanged.
- **Uniform cancellation.** `.cancelWith(token)` on any `Stream` or `Future`, so cancellation composes the same way everywhere instead of being threaded as a parameter through each signature. The existing `cancelToken:` arguments remain for true engine-level abort.

16 tests added in `test/cli_flexibility_test.dart`.

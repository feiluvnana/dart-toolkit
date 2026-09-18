# Changelog

Every release so far is breaking and ships no deprecation shims. Numbers are back-to-back
deltas measured on the same machine; `tool/startup.dart` reproduces the startup ones.

## 0.0.3 — brevity and speed

An audit that read every public member, then probed the engine with mock clients. Ten defects
reproduced and fixed, the API renamed to one set of rules, five additions judged by what they
delete from `bin/keybox.dart` (stage 2 went from 38 lines to 27 and now downloads FLAC), and
the two largest startup costs removed.

### Speed

- **`html` is in-house.** A tag-soup parser and a CSS selector engine replace `package:html`
  and `csslib`, which cost about 580 ms of front-end work per `dart run` — the whole startup
  cost of a scraper. Importing `html` now costs +230–280 ms over a bare script against +660–720
  before, three pairs each; what is left is `http`. Parsing is 2–4× faster too (a 1.1 MB page:
  16 ms against 40). Checked
  against the old parser on three real pages in `test/html_differential_test.dart`, selector by
  selector. Intended differences: `<noscript>` content is parsed as markup, `:empty` follows the
  spec, `:nth-child` works.
- **Executables run through pub's snapshot.** `dart run dart_toolkit:keybox` starts in 350–420 ms
  against 1 330–1 480 ms for `dart run bin/keybox.dart`, and picks up edits. The README and the
  examples say so.
- `String.match` walks its matches once (462 → 231 ms per 200 000). `Ansi.enabled` asks the
  terminal once instead of per styled string (65 → 11 ms per 200 000). `run` inherits the
  environment untouched when nothing overrides it.

### Brevity

- **`$` returns `Elements`**, a `List<Element>` whose `text`, `attr()`, `lines` and `$()` act on
  the first match: `doc.$('a').attr('href')` for `doc.$('a').first.attr('href')`. An empty match
  answers `null` to `attr` and throws a `StateError` naming the problem to the others.
- **`ctx.cancel`** on `CliContext`: a `CancelToken` that `Cli.run` cancels on SIGINT, SIGTERM,
  `die` and when the action ends. Scripts stop declaring their own.
- **`[a, b].merge()`** on `Iterable<Stream<T>>` runs its sources at the same time — what
  `yield*` after `yield*` looks like it does and does not.
- **`.show()`** on `Stream<BatchProgress>` renders a `ConsoleMultiProgress` and returns the last
  event: one line for the five that built the widget, looped and closed it.
- **`follow` returns `bool`**: `false` when the target was dropped as visited, out of scope, too
  deep or not http. `ScrapeSummary.dropped` counts them.
- **`res.json`, `res.html`, `res.xml` are getters**, as `ShellResult.json` already was.
  `String.html` parses a string.

### Names

One set of rules, now in CONVENTIONS.md: read-only booleans are `is*`; the async form is bare and
the sync twin ends in `Sync`; a pure function of the receiver is a getter; one word per idea.

| was | is |
|---|---|
| `Response.ok`, `ShellResult.ok`, `Future<ShellResult>.ok` | `isOk` |
| `ConsoleIo.redirected`, `CliOption.required`, `Logger.enabled()` | `isRedirected`, `isRequired`, `isEnabled()` |
| `sortedBy(desc:)` | `sortedBy(descending:)` |
| `Either.tryCatch` (sync), `tryCatchAsync` | `tryCatchSync`, `tryCatch` |
| `Path.sanitized()`, `Duration.humanize()` | `sanitized`, `humanized` |
| `HandlerFailed`, `BadStatus` | `HookFailed`, `StatusFailed` |
| `InitContext.maxPages`, `maxDepth` | `pages`, `depth` |
| `Env.clear()` | `Env.reset()` |
| `Console.spin(successMessage:, failMessage:)` | `spin(done:, failed:)` |
| `Path.replaceInFile` | `replaceText` |
| `Stream.chunkTime` | `chunkEvery` |
| `HtmlDocument.document` | gone — the document is the tree; `root`, `head`, `body`, `outerHtml` |

Usage errors are a `UsageException`; `Cli.run` catches only that, so an `ArgumentError` thrown by
the action is no longer reported as "Run --help for usage".

### Fixed

- `run(cmd, input:)` deadlocked when the child echoed more than a pipe holds: stdin was fed
  before stdout was read.
- The command splitter escaped inside single quotes and escaped everything inside double
  quotes; it now reads as a POSIX shell does.
- A hook that called `stop()` and then threw hung the stream.
- A second `follow` of a URL already followed was dropped silently; keybox `-f all` never
  fetched FLAC.
- `/p#a`, `/p#b` and `/p` were three fetches; fragments are stripped.
- A seed at `a.com` dropped every `www.a.com` link; the default scope ignores a leading `www.`.
- A redirect to another host carried `authorization` and `cookie` with it.
- Leaving a `downloadAll` loop early left the in-flight `.part` file on disk.
- A non-2xx download never closed its body; the connection was held until GC.
- Exit hooks did not run when the action threw, and the signal watch kept the process alive.
- `app --help | head` died with an unhandled `Broken pipe`.
- `Retry-After` as an HTTP date fell through to the backoff; a second 429 could shorten a
  longer pause.

## 0.0.2 — three audits

Surface, call sites, then measurements. Names settled to one per operation and fifteen aliases
went; `parallelize` became the one concurrency primitive returning `List<Either>`; `CliOption`
and `DownloadProgress` became sealed types; implementation moved under `lib/src/` with eleven
public libraries, one per module, each with a third-party budget enforced by
`tool/check_deps.dart`. `rxdart` and the XPath-for-HTML package were dropped (the stream
operators are in-house; HTML XPath was 145× slower than CSS). Hashing, archiving and downloads
stream instead of holding the file (888 → 266 MB on a 512 MB file). `HtmlDocument` and
`XmlDocument` left `core`, then the format bridges left `http`, so a JSON client stopped
compiling two parsers (about a second per `dart run`). `Http.session` owns the client, timeout
and default headers. `scrape` became a chain of five hooks with every setting on `onInit`'s
context and every failure a `Left`. `Cli.run` owns the lifecycle; `ctx.option` and `ctx.number`
are non-null when a default or `required` guarantees a value.

## 0.0.1

Initial release: shell and subprocess automation, `Path`, `Env`, concurrency helpers, `Either`
and the JSON/HTML/XML documents, HTTP extensions and a scraping pipeline, and the CLI, console
and prompt toolkit.

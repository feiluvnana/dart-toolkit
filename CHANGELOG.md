# Changelog

## 0.0.2

A review pass: every bug below keeps a regression test. The three examples are rewritten to read
plainly.

**Changed**

- `FakeTerminal` moved to `package:dart_toolkit/testing.dart`, out of the `cli`/`tui` compile.
- `Chrome.launch(headless:, store:, executable:, args:, stealth:)` takes its settings directly;
  `Browser` is only for `connect(start:)`. `page.eval<T>(…)` replaces `.to<T>()` on its result.
- Crawl hooks are named parameters only: `Hooks` and `Crawler(hooks:)` are gone, `follow`/`send`
  take `onResponse:`, `url.crawl` gains `onInit:`. Shared hooks are a `Crawler` subclass.
- `Selection.text`, `attr(name, or:)` and `link` read the first match; `DocSelection` is an
  `Iterable<Doc>` (`.list` removed); JSONPath's leading `$` is optional.
- `'text'.link(url)` replaces `Style.link(url)(text)`. `Torrent.read(p).download(into:)` chains.
- Removed: `Env.isCI`, `Cancel.reason`, `Bar.add`, `Element.pairs`/`prepend`/`classes`/
  `innerMarkup`, `Selection.elements`, `Html.decodeEntities`; `Retry.attempt` is internal.
- `Batch.timeout` cancels the batch and names it; a scope timeout is a `TimeoutException` for
  batches too. A negative `Retry` is an `ArgumentError` at the call.
- `to<T>` with a type it cannot read is an `ArgumentError`; text dates without a zone read as UTC;
  `Env.get` treats a blank variable as absent.
- `Shell.run` refuses `#` comments, `$1`/`$$`, brace expansion and `FOO=1 cmd` (use `Shell.sh`).
- TSV has no quoting (a tab or line break in a cell is a `FormatException`); the INI writer
  refuses what would not read back as itself.
- Globs and `only:` take `\` as an escape; `only:` refuses `..`. `duplicates` compares by BLAKE3.
- A merging copy or move settles a folder a file is in the way of by `conflict:`.
- Native ABIs: `dart_toolkit_native` 13, `dart_toolkit_torrent` 3.

**Fixed**

- Crashes: `Run.errors` listened to before any stderr; `Batch.merge` when a later part fails
  first; BLAKE3 (SIGBUS) on a file truncated while it is hashed.
- Lost files: two moves, copies or saves at once landing on one name (a claimed name is taken
  under every policy); a cancelled `Renames.apply` leaving files under hidden names.
- Hangs: a script that made a request waiting up to 30 s to exit; a `Pool` after a worker failed
  to start or its isolate died; `tail()`/`changes()` cancelled at once; a segmented download from a
  server that ignores ranges; a cut paste end marker swallowing every later key; page waits and
  `Chrome.launch` ignoring a cancel; a `Store` update that writes inside its lock.
- Processes: grandchildren surviving a stop when their parent died first; a `stream:` input kept
  after the command ended; a resumed failed job duplicated by `add`; a leftover pool record adopted
  twice; a cancelled native install leaving cargo's children.
- Work: cleanups cancelled with the scope around the task; an isolate batch cancelled early still
  running; nested batch progress every 32 items; nullable and `Map<String, List<String>>` keys.
- HTTP: a retried revalidation's 304 thrown; `Vary` against the scope's headers; a cached answer's
  redirect target; `events()` replayed from the cache; a redirect loop retried.
- Files: `unarchive` into a mount point; a merge changing an existing folder's mode; 7z dropping
  symlinks; escaped gitignore characters; `clear()` creating a folder.
- Formats: YAML comments after an apostrophe in a plain scalar; srcset URLs with commas; streamed
  NDJSON line numbers; TOML dotted-key, XPath and CSS nesting depth; HTML button scope, `<p>`
  closers and SVG `style`/`title`; all 2125 HTML5 entities; a stray `]` in JSONPath.
- Terminal: widths from Unicode 16 (emoji, NFD marks, jamo); a slow UTF-8 read turning into Esc;
  completion quoting, option values taken for commands, fish short letters; `-n` named `--n`; a
  subcommand's usage hint; `wrap` dropping indentation; `plain` keeping charset escapes.
- Torrent: file indices with BEP 47 padding files; create/verify opening every file at once; a
  wrong piece count, a padded base32 hash and a bad creation date; a cancelled job never
  restarting; a `read` that could not be stopped.
- Image: `optimize` dropping a turned PNG's EXIF; `ImageInfo` reading EXIF from JPEG only.

**Faster**

- `Quality.under` without `visual:` searches by size alone (1.46 s → 0.14 s on 2000×1500).
- Folder-store pools are linear (2000 jobs: 1.1 s → 23 ms); isolate progress is throttled.
- `compareNatural` allocates nothing (5×); stream `parallelize` keeps nothing per item.
- Relative selectors walk siblings only; bulk `detach` is linear (8k nested: 513 → 7 ms); YAML
  writing 3.8× and TOML 2.2× faster.
- Connections are kept 100 ms between requests; the memory cache stops holding bodies past
  64 MiB; `Archive.contents` hands bytes over without a copy; folder copies do fewer syscalls.
- `isPidAlive` is a syscall, not a process (5 ms → 6 µs).

## 0.0.1

The first release: a toolkit for Dart scripts, built on one model.

- **Four shapes.** Every operation gives a value, a `Task<T>` (one result, a `Future` that reports
  its `Status`), a `Batch<I, T>` (many, made by `parallelize`, values in input order, one
  `BatchException` for every failure) or a `Stream`. `await` is success or throw; `.settled` never
  throws; a cancel is `Stopped`. Cleanup is `work.defer`; what remembers takes `store:`
  (`Store`, `Key<T>`); credentials are `Secret`s. Async only, one behaviour per method.
- **Modules.** `core`, `path` (atomic writes, `to:`/`into:`, `Conflict`, rename plans, listings,
  watching), `archive`, `hash`, `async` (`Worker`, `Pool`, `Job`, detached jobs, stream operators),
  `process` (`Shell`, `Command`, `Runner.fake`), `json` (`Doc`: JSON, YAML, TOML, INI), `html`/`xml`
  (`Html`, `Xml`, CSS and XPath), `collection` (`Table`), `http` (strict `url.get()`,
  `Http.scope`, `download`, `Client.fake`), `scrape` (`url.crawl`, `Crawler`), `chrome`, `image`
  (`compress` by perceived quality), `torrent`, `cli` (`Cli`, typed options, `Console`, `show`),
  `tui` (apps, widgets, mouse and hover, overlays, `Markdown`, `Picture`) and `native`.
- **Checked text, opt-in:** `'755'.mode`, `'**/*.mp3'.glob`, `'h2 a'.css`, `'//a'.xpath`,
  `r'$.a'.jsonPath`, `'9f86…'.hex`, `'image/'.mime`; parameters still take plain `String`s.
- **Test seams:** `Clock.fake()`, `Client.fake`, `Runner.fake`, `FakeTerminal`, `Store.memory()`,
  `Io.scope`, `Env.scope`, `cli.test`.
- **Native libraries** (`dart_toolkit_native` ABI 12, `dart_toolkit_torrent` ABI 2): a first use
  downloads this platform's build from the release of these sources (checked against its
  `.sha256`), else compiles it with `cargo`.

The rules are in `CONVENTIONS.md`; what is left for Windows is in `PLAN.md`.

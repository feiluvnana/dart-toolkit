# Changelog

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

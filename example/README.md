# Examples

One short script per kind of use case, and one that puts them together.

| File | Use case |
| :--- | :--- |
| [`scrape.dart`](scrape.dart) | Pull data out of one page — selectors, the string shorthand, typed `Field`s |
| [`crawl.dart`](crawl.dart) | Walk a site in stages — routes, tags, `meta`, scope and politeness |
| [`form.dart`](form.dart) | Sign in and submit the form a page came with, standalone and inside a crawl |
| [`http.dart`](http.dart) | Talk to a server — sessions, sealed bodies, JSON, downloads with progress |
| [`serve.dart`](serve.dart) | Listen instead — an OAuth callback, a webhook, a preview |
| [`shape.dart`](shape.dart) | Shape what came back — `Sequence`, the `Json` cursor, JSONPath, YAML |
| [`parallel.dart`](parallel.dart) | Do many things at once — bounded pools, `settle`, retries, locks, rate limits |
| [`files.dart`](files.dart) | Put results on disk — atomic writes, JSON, CSV, locking, state between runs |
| [`console.dart`](console.dart) | Say what the script is doing — logs, spinners, bars, tables, boxes |
| [`cli.dart`](cli.dart) | Present a command line — declared flags, commands, `--help`, exit codes |
| [`shell.dart`](shell.dart) | Drive the machine — `.env`, subprocesses, archives, shutdown |
| [`example.dart`](example.dart) | **The pipeline**: crawl → enrich → write → archive → report, in one script |

Every one runs offline and finishes in a second or two:

```sh
dart run example/example.dart
dart run example/example.dart --concurrency 8 --force

dart run example/crawl.dart
dart run example/shape.dart
dart run example/serve.dart
dart run example/cli.dart --help
dart run example/cli.dart build --token x -o dist --mode release
```

The network is stood in for rather than avoided. A crawl takes a
`MapDownloader` of fixtures, a `Reply.text(...)` behaves exactly like a
response off the wire, and `http.dart` and `serve.dart` start throwaway
servers on a free port — so in each case the lines that matter are the ones you
would write against a live site.

## Where to start

**`example.dart`** for the shape of a whole script: arguments, a crawl,
bounded concurrency, atomic writes, an archive and a summary table, in the
order a real run does them.

**`crawl.dart`** if you are here for the crawler. It is the flagship case —
one handler per stage, `meta` carrying context between them, and scope rules
(`depth`, `limit`, `samehost`, `allow`/`deny`) keeping the run bounded. Note
`.downloader(MapDownloader(...))`: swapping the downloader is how a pipeline
is tested without the network, and it is the only line that differs between
the fixture and live runs.

**`scrape.dart`** if you only need to read one page, and **`form.dart`** if you
need to put something back into it.

**`shape.dart`** for the middle of a script — the grouping, batching, summing
and JSON reading that used to mean reaching past this library. It is the one to
read for `Sequence`, which everything here hands back.

**`cli.dart`** if you are writing a command-line program: the interface is
declared once, and `cli.run` handles `--help`, validation, dispatch and the
exit code.

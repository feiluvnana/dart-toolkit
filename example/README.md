# Examples

Four runnable programs. All of them work offline — the crawls are served from
in-memory fixtures, and the networked parts are behind a flag.

| File | Shows |
| :--- | :--- |
| [`example.dart`](example.dart) | A tour of all seven domains, end to end |
| [`crawler.dart`](crawler.dart) | A multi-stage crawl: routes, tags, `meta`, scope, robots |
| [`scrape.dart`](scrape.dart) | One-off requests: selectors, extraction, sessions, downloads |
| [`tool.dart`](tool.dart) | A small CLI: declared arguments, prompts, progress, cleanup |

```sh
dart run example/example.dart
dart run example/example.dart --concurrency 8 --force

dart run example/crawler.dart -o tracks.jsonl
dart run example/crawler.dart --live          # against the real site

dart run example/scrape.dart
LIVE=1 dart run example/scrape.dart           # includes the networked half

dart run example/tool.dart --help
dart run example/tool.dart build --token x -o dist
dart run example/tool.dart report --token x -o dist
dart run example/tool.dart clean --token x --yes
```

## What to read first

**`example.dart`** if you want the shape of a whole script: arguments, a crawl,
bounded concurrency, atomic writes, an archive, and a summary table.

**`crawler.dart`** if you are here for the crawler. It is the flagship case —
one handler per stage, `meta` carrying context between them, and scope rules
(`depth`, `limit`, `samehost`, `allow`/`deny`, `robots`) keeping the run
bounded. Note `.downloader(MapDownloader(...))`: swapping the downloader is how
you test a pipeline without the network, and it is the only line that differs
between the fixture and live runs.

**`scrape.dart`** if you only need to pull data out of a page. No engine, no
frontier — just `net.http` and the selector API, with the loose string schema
and the typed `Field` form side by side.

**`tool.dart`** if you are writing a command-line program. Arguments are
declared once and `--help` writes itself; `system.on.exit` plus
`system.shutdown()` make the script safe to Ctrl-C.

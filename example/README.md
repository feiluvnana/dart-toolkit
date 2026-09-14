# Example: Full Pipeline

The complete, end-to-end `dart-toolkit` pipeline in a single runnable script:

[`example.dart`](example.dart)

A catalogue is crawled, each product enriched in parallel, the results written as JSON and CSV, compressed into an archive, and reported as a formatted Unicode table and status box. The crawl is served from an offline fixture, so it runs offline in seconds without requiring network access.

## Running the Example

```sh
# Run the pipeline with defaults
dart run example/example.dart

# Run with custom concurrency and force overwrite
dart run example/example.dart --concurrency 8 --force

# View command-line help
dart run example/example.dart --help
```

## Features Demonstrated

- **CLI parsing (`CliParser`)**: declared options (`--output`), flags (`--force`), numbers (`--concurrency`), and auto-generated usage help.
- **Paths (`Path`)**: `out / 'products.json'` composes, `.exists` asks, `.makeDir()`, `.writeJson()`, `.write(rows, as: .csv)` and `.zipTo()` act — one type, and every write atomic.
- **Console (`logger`, `Console`)**: step indicators, success badges, Unicode tables, boxes, rules, and progress bars.
- **Web crawling (`crawl`)**: multi-hop crawling with an offline fixture transport, and every knob a named argument — `politeness: .every(20.ms.jittered())`, `scope: .sameHost`, `depth`, `limit`, `concurrency`.
- **Leading dots**: `.every(…)`, `.sameHost`, `.text('h1')`, `.number('.price')`, `.csv`, `.left`, `.unicode` — the parameter type supplies the prefix.
- **DOM parsing & extraction (`res.$$()`, `page.pick(.number(…))`)**: jQuery-style CSS queries, attributes, readable text collapsing, and typed field extraction into a record.
- **Null-aware elements**: `[for (final card in …) ?card.$('a').attr('href')]` drops the misses, which is the shape a scraped `href` has.
- **Parallel enrichment (`items.parallelMap`)**: bounded concurrent execution with a progress bar.
- **Environment & subprocesses (`env`, `run`)**: `.env` configuration, a git check, and graceful shutdown hooks (`onExit`).

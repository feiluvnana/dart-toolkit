# Example: Full Pipeline

The complete, end-to-end `dart-toolkit` 8.0.0 pipeline in a single runnable script:

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

- **CLI Parsing (`CliParser`)**: Declared options (`--output`), flags (`--force`), numbers (`--concurrency`), and auto-generated usage help.
- **Console Domain (`logger`, `consoleWriter`)**: Step indicators, success badges, Unicode tables, boxes, rules, and progress bars.
- **Web Crawling (`Http.crawl`)**: Multi-hop web crawling with offline fixture transport, delay jitter, concurrency limits, and scope rules.
- **DOM Parsing & Extraction (`.$()`, `.all()`, `Field`)**: jQuery-style CSS queries, element attributes, readable text collapsing, and typed field extraction.
- **Parallel Enrichment (`parallelMap`)**: Bounded concurrent execution over async collections with progress tracking.
- **Atomic File I/O (`Files.writeJson`, `Files.writeCsv`, `Files.writeText`)**: Crash-safe atomic writes via staging files.
- **Archive Compression (`Formats.zip`)**: Direct archive packing with formatted file sizes.
- **Environment & Subprocesses (`Env`, `System.run`)**: `.env` configuration, git repository checks, and graceful shutdown lifecycle hooks (`System.onExit`).

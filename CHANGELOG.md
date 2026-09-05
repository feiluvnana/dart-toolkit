# Changelog

All notable changes to this project will be documented in this file.

## 1.0.0

- Initial release of `dart_toolkit` (Dart Script Toolkit by feiluvnana).
- **`console.*`**: Dedicated status loggers sub-namespace (`console.logger.*` with `step`, `ok`, `warn`, `fail`, `error`, `info`, `debug`, `task`, `write`, `writeln`), table formatting, boxed callouts, divider rules, dynamic progress bars, animated spinners, interactive prompts (`ask`, `confirm`, `pick`, `secret`), terminal geometry, ANSI color extensions on String.
- **`fs.*`**: Atomic file writes with `.part` staging and signal cleanup, zero-dependency path helpers (`join`, `base`, `name`, `ext`, `dir`), directory creation/walking, streaming downloads, human-readable size and time formatters, sanitization, 7-Zip archive integration (`fs.archive`).
- **`crawl.*` / `$()`**: Fluent builder crawler API (`crawl(urls).concurrent(n).delay(d).base(...).tag(...).run(process)` with process-only execution arguments, `crawl.collect`, `crawl.run`), unified crawler engine (`crawl.engine`), declarative route and tag handlers, pipeline response controls (`follow`, `save`, `emit`, `stop`), automatic relative URL resolution, streaming atomic downloads, batch asset synchronization (`crawl.sync`), jQuery-like CSS DOM query results.
- **`parallel.*`**: Bounded concurrency execution (`parallel.run`, `parallel.map`, `parallel.each`), dedicated `Pool` with progress and error event hooks.
- **`sys.*`**: Subprocess execution (`sys.run`), signal interception (`SIGINT`, `SIGTERM`), exit hooks, temporary file tracking, benchmark stopwatch (`sys.clock`), binary resolution (`sys.which`).
- **`cli.*`**: Command-line flag parsing with short/long aliases, typed option extraction with default values, positional argument access.

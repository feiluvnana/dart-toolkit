# Changelog

All notable changes to this project will be documented in this file.

## 0.0.1

- Initial release of `dart_toolkit`.
- Shell and subprocess automation (`$`, `run`, `String.run()`, `Path.run()`, `which()`, command pipelines).
- Ergonomic filesystem and path operations (`Path`, `readText`, `writeText`, `readJson`, `writeJson`, `append`, `replace`, `sanitized`, `sha256`, `md5`, `zip`, `unzip`).
- Environment variable management and `.env` loader (`Env.get`, `Env.set`, `Env.require`, `Env.load`, `Env.all()`).
- Async concurrency and flow control (`parallelize`, `retry`, `Mutex`, `Semaphore`, `isolate`, stream extensions).
- Core document parsing and types (`Either`, `JsonDocument`, `HtmlDocument`, `XmlDocument`).
- HTTP response extensions and web scraping pipeline.
- Rich CLI, terminal console, spinners, progress bars, tables, prompts, and lifecycle hooks (`Console`, `Prompt`, `Cli`, `onExit`, `die`).

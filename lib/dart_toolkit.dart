/// # Dart Script Toolkit (`dart-toolkit`)
///
/// A modern, lightweight automation and web scraping framework for Dart
/// developed by **feiluvnana**.
///
/// Organized into 5 cohesive, Java-inspired domain namespaces with strictly **1-word methods**:
/// - [io]: Input/Output, atomic file writes (`.part`), paths, CSV (`io.csv`), JSON store (`io.store`), 7-Zip archives (`io.archive`).
/// - [net]: Networking, HTTP requests (`net.http` / `net.get`), web scraping & crawling (`net.crawl`), jQuery-like DOM selectors (`net.$()`).
/// - [system]: Subprocess execution (`system.run`), environment variables (`system.env`), CLI args (`system.cli`), OS signals.
/// - [concurrent]: Bounded async concurrency pool (`concurrent.pool`) and parallel runners (`concurrent.run`).
/// - [util]: Time & delays (`util.time`), Git automation (`util.git`), terminal logging, tables & prompts (`util.console`).
library;

export 'toolkit.dart';

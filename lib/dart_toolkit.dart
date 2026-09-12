/// # Dart Script Toolkit (`dart-toolkit` 8.0.0)
///
/// A lightweight, idiomatic web crawling pipeline and command-line automation
/// toolkit for Dart.
///
/// ## Core Capabilities
/// - **Modern HTTP & Web Crawling**: Top-level [get], [post], [download], [Response] with
///   built-in [Response.html], `.$()`, `.$$()`, `.$xpath()`, and [Crawler] / [crawl]
///   emitting a native `Stream<Response>`.
/// - **Crash-Safe Atomic I/O**: [readText], [writeText], [readJson], [writeJson],
///   [readLines], [writeLines], [withLock], [watchPath], and [listDir].
/// - **Subprocesses & Environment**: [run], [runStream], [which], [env], [loadEnv],
///   and graceful [onExit] hooks.
/// - **Concurrency**: [parallelMap], [settle], [Pool], [RateLimiter], [Semaphore],
///   [retry], and [delay].
/// - **Terminal & CLI**: [CliParser], [logger], [ProgressBar], [Table], and [ansi].
/// - **Codecs & Formats**: [parseHtml], [parseJson], [parseYaml], [parseToml],
///   [parseCsv], [zip], and [unzip].
/// - **Native Dart 3 Extensions**: [sortedBy], [chunk], [window], [distinct],
///   [groupBy], [parallelMap], `.ms`, `.seconds`, `.toSlug()`, and `.extractNumber()`.
///
/// ```dart
/// import 'package:dart_toolkit/dart_toolkit.dart';
///
/// void main(List<String> args) async {
///   final cli = CliParser()..flag('verbose', abbr: 'v');
///   cli.parse(args);
///
///   final titles = await crawl(['https://news.ycombinator.com'])
///       .expand((res) => res.$$('.titleline > a').map((el) => el.text))
///       .distinct()
///       .join('\n');
///
///   await writeText('titles.txt', titles);
/// }
/// ```
library;

export 'cli/cli.dart';
export 'collection/collection.dart';
export 'concurrent/concurrent.dart';
export 'format/format.dart';
export 'io/io.dart';
export 'net/net.dart';
export 'system/system.dart';
export 'util/util.dart';

// The types and extensions no single domain owns: the two document cursors
// every `parse` hands back, the CSV cursor, the [Codec] seam they arrive
// through, and `.url`/`.ms`/`.s`. They lived under `lib/util/` through 5.4.0
// and were never reachable as `util.` anything — see the `util` library doc.
export 'src/codec.dart';
export 'src/csv.dart';
export 'src/extensions.dart';
export 'src/json.dart';
export 'src/method.dart';
export 'src/markup.dart';

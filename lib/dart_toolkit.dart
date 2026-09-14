/// # Dart Script Toolkit (`dart-toolkit`)
///
/// A web crawling pipeline and command-line automation toolkit for Dart,
/// written the way Dart is written: **top-level functions, extensions on the
/// native types, and plain classes**. There is no namespace object to go
/// through and no wrapper type to convert into — `readText(path)` is the read,
/// `items.chunk(2)` is the chunk, and a crawl is a `Stream<Response>`.
///
/// ## Core capabilities
/// - **HTTP & web crawling**: [get], [post], [download], [Response] with
///   [Response.html], `.$()`, `.$$()`, `.$xpath()`, and [crawl] / [Crawler]
///   emitting a native `Stream<Response>`.
/// - **Crash-safe atomic I/O**: [readText], [writeText], [readJson],
///   [writeJson], [readLines], [writeLines], [withLock], [watchPath],
///   [listDir] and [walkDir]. Every write is staged and renamed, so a file
///   appears whole or not at all.
/// - **Subprocesses & environment**: [run], [runStream], [which], [env],
///   [loadEnv], and graceful [onExit] / [shutdown] hooks.
/// - **Concurrency**: [parallelMap], [settle], [Pool], [RateLimiter],
///   [Semaphore], [retry] and [delay].
/// - **Terminal & CLI**: [CliParser], [logger], [ProgressBar], [Table], [ansi].
/// - **Codecs & formats**: [parseHtml], [parseJson], [parseYaml], [parseToml],
///   [parseCsv], [zip] and [unzip].
/// - **Native extensions**: `sortedBy`, `chunk`, `window`, `distinct`,
///   `groupBy`, `parallelMap`, `.ms`, `.seconds`, `.toSlug()`,
///   `.extractNumber()`.
///
/// ## One name per thing
///
/// Every operation has exactly one spelling. Where an operation reads as a
/// property of a value it is an extension method, and the top-level function
/// it forwards to is the same call:
///
/// ```dart
/// slugify('Hello World') == 'Hello World'.toSlug();
/// formatBytes(2048) == 2048.formatBytes();
/// ```
///
/// ```dart
/// import 'package:dart_toolkit/dart_toolkit.dart';
///
/// void main(List<String> args) async {
///   final parser = CliParser()..flag('verbose', abbr: 'v');
///   parser.parse(args);
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

// The types and extensions no single library owns: the two document cursors
// every `parse` hands back, the CSV cursor, the [DocumentFormat] seam they arrive
// through, and `.url`/`.ms`/`.s`.
export 'src/format.dart';
export 'src/csv.dart';
export 'src/extensions.dart';
export 'src/json.dart';
export 'src/markup.dart';
export 'src/method.dart';

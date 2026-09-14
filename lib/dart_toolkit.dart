/// # Dart Script Toolkit (`dart-toolkit`)
///
/// A web crawling pipeline and command-line automation toolkit for Dart,
/// written the way Dart 3.10 is written: **every operation hangs off the value
/// it acts on, and every argument is a leading dot.**
///
/// ```dart
/// final out = Path.cwd / 'output';
/// await (out / 'products.json').writeJson(rows);    // atomic
/// final settings = await Path('config.yaml').read(.yaml);
///
/// final res = await Http.get('https://example.com'.url);
/// final titles = res.$$('h1').map((h) => h.text);
/// ```
///
/// ## The map
///
/// | Reach for | Where | For |
/// | :--- | :--- | :--- |
/// | [Path] | `Path.cwd / 'out'` | Files, directories, locks, watches, hashes, archives — reading, writing **atomically**, walking |
/// | [Http] | `Http.get(url)` | One-off requests through a shared pooled client |
/// | [Fetcher] | `Fetcher(session: true)` | A session: cookies, base headers, retries, cache, rate limit |
/// | [crawl] | `crawl(seeds, next: …)` | A `Stream<Response>` from a self-feeding frontier |
/// | [Response] | `res.$('h1')`, `res.parse(.yaml)` | A reply, and every way of reading it |
/// | `String` | `'x'.toSlug()`, `'5MiB'.bytes`, `body.parse(.html)` | Text, sizes, durations, digests, every document format |
/// | `Iterable` | `items.chunk(2)`, `urls.parallelMap(Http.get)` | Native collections, plus bounded async work |
/// | [Console] / [logger] | `logger.ok(…)` | Terminal output and input |
/// | [CliParser] | `parser.flag('force')` | Flags, options, subcommands, usage |
/// | [Pool], [RateLimiter], [Semaphore], [retry] | | Bounded, paced, retried work |
///
/// ## What is top level
///
/// Fourteen names, because these are the ones with no receiver to hang off:
/// [crawl], [serve], [serveOnce], [run], [runStream], [which], [env],
/// [loadEnv], [onExit], [shutdown], [cpuCount], [logger], [delay] and [retry].
///
/// Everything else is a member. 9.0.0 moved 154 top-level functions onto the
/// values they act on: an editor cannot help with a flat list of names,
/// because there is nothing to type before the dot, and it can help perfectly
/// with `path.`, `res.` or `items.`.
///
/// ## One name per operation
///
/// Not one name plus an extension plus a `Sync` twin. Blocking filesystem
/// calls live under one member rather than behind a suffix on twenty-eight
/// names:
///
/// ```dart
/// await settings.readText();   // Future<String>
/// settings.sync.readText();    // String
/// ```
///
/// ## A leading dot, everywhere a type is known
///
/// ```dart
/// res.parse(.yaml);
/// page.pick(.number('.price'));
/// await Http.post(url, body: .json({'q': 'widgets'}));
/// crawl(seeds, politeness: .perHost(250.ms), scope: .sameHost);
/// await Path('dist/app.zip').hash(.sha256);
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
///   await Path('titles.txt').writeText(titles);
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

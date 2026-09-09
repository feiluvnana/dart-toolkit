/// # Dart Script Toolkit (`dart-toolkit`)
///
/// A lightweight automation and web-scraping toolkit developed by
/// **feiluvnana**, organised into seven domain namespaces with lowercase,
/// preferably one-word methods:
///
/// - [io]: files, atomic writes, paths, CSV (`io.csv`), a JSON store
///   (`io.store`), and a non-blocking mirror of the lot (`io.async`).
/// - [net]: HTTP (`net.http`), the crawler engine (`net.crawl`), selectors (`$`).
/// - [system]: subprocesses, environment (`system.env`), CLI args
///   (`system.cli`), the terminal (`system.console`).
/// - [concurrent]: bounded async task pools.
/// - [git]: repository queries and commands.
/// - [zip]: packing, unpacking and inspecting archives.
/// - [util]: pure helpers — time (`util.time`), sizes (`util.size`), text
///   (`util.text`), hashing (`util.hash`), randomness (`util.rand`).
///
/// Every name appears exactly once: there are no flat aliases, and each
/// operation lives in the domain that owns it. `git` and `zip` stand on their
/// own because they are self-contained tools with their own vocabulary; the
/// generic words behind `util` keep that prefix so they cannot collide with
/// your own `text`, `hash` or `size`.
///
/// ```dart
/// import 'package:dart_toolkit/dart_toolkit.dart';
///
/// void main(List<String> args) async {
///   system.cli.parse(args);
///   final titles = await net.crawl<String>('https://news.ycombinator.com')
///       .concurrent(4)
///       .collect((res) {
///         for (final title in res.$('.titleline > a').texts) res.emit(title);
///       });
///   await io.write('titles.txt', titles.join('\n'));
/// }
/// ```
library;

export 'concurrent/concurrent.dart';
export 'git/git.dart';
export 'io/io.dart';
export 'net/net.dart';
export 'system/system.dart';
export 'util/util.dart';
export 'zip/zip.dart';

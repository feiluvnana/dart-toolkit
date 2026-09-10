/// # Dart Script Toolkit (`dart-toolkit`)
///
/// A lightweight automation and web-scraping toolkit developed by
/// **feiluvnana**, organised into seven domain namespaces with lowercase,
/// preferably one-word methods.
///
/// Five of them are *axes* — a way of touching the machine:
///
/// - [io]: files, atomic writes, paths, CSV (`io.csv`), a JSON store
///   (`io.store`), and a non-blocking mirror of the lot (`io.async`).
/// - [net]: HTTP (`net.http`), the crawler engine (`net.crawl`), selectors (`$`).
/// - [system]: subprocesses, environment (`system.env`), the terminal
///   (`system.console`), shutdown (`system.on`).
/// - [concurrent]: bounded async task pools.
/// - [util]: pure helpers — time (`util.time`), sizes (`util.size`), text
///   (`util.text`), hashing (`util.hash`), randomness (`util.rand`).
///
/// Two are *subjects* — knowledge that came from outside Dart:
///
/// - [cli]: flags, options, subcommands and usage text.
/// - [tool]: wrapped executables and formats — `tool.git`, `tool.zip`.
///
/// Every name appears exactly once: there are no flat aliases, and each
/// operation lives in the domain that owns it. Argument parsing is its own
/// domain because it touches nothing at all, while `git` and `zip` share one
/// because a top level that grows a name per wrapped binary is not a top
/// level. The generic words behind `util` keep that prefix so they cannot
/// collide with your own `text`, `hash` or `size`. `NAMESPACE.md` has the
/// rules.
///
/// ```dart
/// import 'package:dart_toolkit/dart_toolkit.dart';
///
/// void main(List<String> args) async {
///   cli.parse(args);
///   final titles = await net.crawl<String>('https://news.ycombinator.com')
///       .concurrent(4)
///       .collect((res) {
///         for (final title in res.$('.titleline > a').texts) res.emit(title);
///       });
///   await io.write('titles.txt', titles.join('\n'));
/// }
/// ```
library;

export 'cli/cli.dart';
export 'concurrent/concurrent.dart';
export 'io/io.dart';
export 'net/net.dart';
export 'system/system.dart';
export 'tool/tool.dart';
export 'util/util.dart';

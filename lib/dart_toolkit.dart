/// # Dart Script Toolkit (`dart-toolkit`)
///
/// A lightweight automation and web-scraping toolkit developed by
/// **feiluvnana**, organised into eight domain namespaces with lowercase,
/// preferably one-word methods.
///
/// Five of them are *axes* — a way of touching the machine:
///
/// - [io]: files, atomic writes, paths, CSV (`io.csv`), the collections on
///   disk (`io.dictionary`, `dump`), watching (`io.watch`), locking
///   (`io.lock`), and a non-blocking mirror of the lot (`io.async`).
/// - [net]: HTTP (`net.http`), the crawler engine (`net.crawl`), the forms a
///   page carries ([Form]) — and, in the other direction, a server that
///   listens (`net.serve`, `net.once`). It fetches bytes and parses none of
///   them.
/// - [system]: subprocesses, environment (`system.env`), the terminal
///   (`system.console`), shutdown (`system.on`), the machine (`system.os`).
/// - [concurrent]: bounded async task pools, and rate limiting
///   (`concurrent.rate`).
/// - [util]: pure helpers — time (`util.time`), sizes (`util.size`), text
///   (`util.text`), hashing (`util.hash`), randomness (`util.rand`) — plus the
///   two read cursors every document door hands back: [Json] for maps and
///   scalars, [Markup] for elements.
///
/// One is neither, because it is a vocabulary rather than a way in:
///
/// - `collection`: [Sequence] and [Dictionary], the two collections this
///   library returns in place of Dart's, and the two operation types that
///   shape them — [Transformer] and [Collector]. A library, not an accessor:
///   Rule 2 spends no top-level name, and you reach every one of these from
///   the data you already hold.
///
/// Two are *subjects* — knowledge that came from outside Dart:
///
/// - [cli]: flags, options, subcommands and usage text.
/// - [format]: file formats — `format.html`, `format.json`, `format.yaml`,
///   `format.toml`, `format.zip`. Never executables: wrapping a binary is
///   `system.run` plus arguments.
///
/// Every name appears exactly once: there are no flat aliases, and each
/// operation lives in the domain that owns it. Argument parsing is its own
/// domain because it touches nothing at all, while the formats share one
/// because a top level that grows a name per format is not a top level. The
/// generic words behind `util` keep that prefix so they cannot collide with
/// your own `text`, `hash` or `size`. `NAMESPACE.md` has the rules.
///
/// ```dart
/// import 'package:dart_toolkit/dart_toolkit.dart';
///
/// void main(List<String> args) async {
///   cli.parse(args);
///   final titles = await net.crawl<String>('https://news.ycombinator.com'.url)
///       .concurrent(system.os.cpus)
///       .gather((page) => page.parse(format.html)
///           .find('.titleline > a').texts.list);
///
///   io.write('titles.txt', titles.transform(.unique()).collect(.join('\n')));
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

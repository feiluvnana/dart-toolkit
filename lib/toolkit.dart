/// # Core Toolkit Aggregator
///
/// Exports all 6 core namespaces for automation and scraping:
/// ```dart
/// import 'package:dart_toolkit/dart_toolkit.dart';
///
/// void main(List<String> args) async {
///   cli.parse(args);
///   sys.listen();
///   console.ok('Dart Script Toolkit initialized!');
/// }
/// ```
library;

export 'cli/cli.dart';
export 'console/console.dart';
export 'crawl/crawl.dart';
export 'fs/fs.dart';
export 'parallel/parallel.dart';
export 'sys/sys.dart';

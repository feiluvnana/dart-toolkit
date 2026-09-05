/// # Core Toolkit Aggregator
///
/// Exports the 5 cohesive Java-style domain namespaces:
/// - [io]: File system, atomic writing, paths, CSV, key-value storage, archives.
/// - [net]: HTTP networking, streaming downloads, crawler engine, and jQuery-like `$()` selectors.
/// - [system]: Process execution, environment variables, CLI argument parsing, OS signals.
/// - [concurrent]: Concurrency pool and bounded async workers.
/// - [util]: Time/delays, Git automation, terminal console, and ANSI colors.
library;

import 'concurrent/concurrent.dart';
import 'io/io.dart';
import 'net/net.dart';
import 'system/system.dart';
import 'util/util.dart';

export 'concurrent/concurrent.dart';
export 'io/io.dart';
export 'net/net.dart';
export 'system/system.dart';
export 'util/util.dart';

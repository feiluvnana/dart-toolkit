/// # Collections on Disk (`dump`, `io.dictionary`)
///
/// Writing a [Sequence] or a [Dictionary] to a file, and reading one back.
///
/// These are extensions declared here rather than members over in
/// `collection`, and the direction matters: Rule 1 says anything that writes a
/// file is `io`, and Rule 2 forbids `collection` needing `io` back. `io`
/// already depends on `collection` — `io.find` returns a [Sequence] — so this
/// adds no new edge, and a collection still knows nothing about the disk,
/// which is what keeps it testable.
///
/// The package has one export, so a script that imports
/// `package:dart_toolkit/dart_toolkit.dart` sees `rows.dump(path)` with no
/// extra import at all.
library;

import '../collection/dictionary.dart';
import '../collection/flow.dart';
import '../collection/sequence.dart';
import '../src/fs.dart';
import 'io.dart';

// ============================================================================
// COLLECTIONS ON DISK (dump)
// ============================================================================

/// Writing a [Sequence] to a JSON file.
extension Dumpable<T> on Sequence<T> {
  /// Writes these elements to [path] as a JSON array, atomically.
  ///
  /// ```dart
  /// rows.dump('out/rows.json');
  /// ```
  ///
  /// Every element has to survive `jsonEncode`, which for a type of your own
  /// means a `toJson`. Reading one back is `format.json.read`.
  FileSystemEntry dump(
    String path, {
    bool pretty = true,
    String part = '.part',
  }) => io.dump(path, collect(.list()), pretty: pretty, part: part);
}

/// Writing a [Dictionary] to a JSON file, and reading one back.
extension DictionaryDumpable<K, V> on Dictionary<K, V> {
  /// Writes these entries to [path] as a JSON object, atomically.
  ///
  /// ```dart
  /// // setup: final spend = Dictionary<String, num>({'a.com': 1});
  /// spend.dump('out/by-host.json');
  /// ```
  ///
  /// `io.dictionary` reads one back. The keys are written as JSON object keys,
  /// so a non-string [K] arrives back as its `toString`.
  FileSystemEntry dump(
    String path, {
    bool pretty = true,
    String part = '.part',
  }) => io.dump(path, map, pretty: pretty, part: part);
}

/// Writing a [Flow] to a JSON file, as it arrives.
extension FlowDumpable<T> on Flow<T> {
  /// Writes these elements to [path] as a JSON array, atomically.
  ///
  /// The streaming twin of [Dumpable.dump]. The brackets and commas are
  /// written around the elements as they arrive rather than the array being
  /// built first, so a crawl or a walk of any size becomes a JSON file
  /// without ever being a `List`:
  ///
  /// ```dart
  /// await net.crawl<Row>(seed).flow().dump('out/rows.json');
  /// ```
  ///
  /// Every element has to survive `jsonEncode`, which for a type of your own
  /// means a `toJson`. Reading one back is `format.json.read`. Claims the
  /// flow, the way every other terminal does.
  Future<FileSystemEntry> dump(
    String path, {
    bool pretty = true,
    String part = '.part',
  }) async => Fs.entryFor(
    (await Fs.pourJson(path, stream, pretty: pretty, part: part)).path,
  );
}

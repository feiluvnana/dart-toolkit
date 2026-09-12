/// # Collections on Disk (`dump`, `io.dictionary`)
///
/// Writing an [Iterable] or a [Map] to a file, and reading one back.
///
/// These are extensions declared here rather than members over in
/// `collection`, and the direction matters: Rule 1 says anything that writes a
/// file is `io`, and Rule 2 forbids `collection` needing `io` back.
///
/// The package has one export, so a script that imports
/// `package:dart_toolkit/dart_toolkit.dart` sees `rows.dump(path)` with no
/// extra import at all.
library;

import 'dart:async';

import '../src/fs.dart';
import 'io.dart';

// ============================================================================
// COLLECTIONS ON DISK (dump)
// ============================================================================

/// Writing an [Iterable] to a JSON file.
extension Dumpable<T> on Iterable<T> {
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
  }) => io.dump(path, toList(), pretty: pretty, part: part);
}

/// Writing a [Map] to a JSON file, and reading one back.
extension MapDumpable<K, V> on Map<K, V> {
  /// Writes these entries to [path] as a JSON object, atomically.
  ///
  /// ```dart
  /// final spend = <String, num>{'a.com': 1};
  /// spend.dump('out/by-host.json');
  /// ```
  ///
  /// `io.dictionary` reads one back. The keys are written as JSON object keys,
  /// so a non-string [K] arrives back as its `toString`.
  FileSystemEntry dump(
    String path, {
    bool pretty = true,
    String part = '.part',
  }) => io.dump(path, this, pretty: pretty, part: part);
}

/// Writing a [Stream] to a JSON file, as it arrives.
extension StreamDumpable<T> on Stream<T> {
  /// Writes these elements to [path] as a JSON array, atomically.
  ///
  /// The streaming twin of [Dumpable.dump]. The brackets and commas are
  /// written around the elements as they arrive rather than the array being
  /// built first, so a crawl or a walk of any size becomes a JSON file
  /// without ever being a `List`:
  ///
  /// ```dart
  /// await net.crawl([Fetch(seed)]).stream.dump('out/rows.json');
  /// ```
  ///
  /// Every element has to survive `jsonEncode`, which for a type of your own
  /// means a `toJson`. Reading one back is `format.json.read`. Claims the
  /// stream, the way every other terminal does.
  Future<FileSystemEntry> dump(
    String path, {
    bool pretty = true,
    String part = '.part',
  }) async => Fs.entryFor(
    (await Fs.pourJson(path, this, pretty: pretty, part: part)).path,
  );
}

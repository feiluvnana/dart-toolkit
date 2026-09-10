/// # IO Domain (`io.*`)
///
/// Filesystem access, path manipulation, CSV tables (`io.csv`) and a JSON
/// key-value store (`io.store`). Every write is atomic — see [Fs].
///
/// `io.*` blocks; `io.async.*` is the same set of names without blocking the
/// event loop. Inside a crawl, or anywhere else with work in flight, reach for
/// `io.async`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'csv.dart';
import '../src/fs.dart';
import 'store.dart';

export 'csv.dart';
export '../src/fs.dart' show Algo;
export 'store.dart';

// ============================================================================
// IO DOMAIN (io.*) - File System, Paths, CSV & Store
// ============================================================================

final StoreAccessor _store = StoreAccessor();

/// The `io` domain: files, paths, CSV and the key-value store.
const IoAccessor io = IoAccessor();

/// Entry point for filesystem and path operations.
///
/// Paths are plain strings; given a [File], pass its [File.path].
///
/// Everything here blocks. Every disk operation also lives on [async] as a
/// future, which is what a crawl or any other concurrent script should use.
///
/// ```dart
/// io.write(io.join('out', 'report.txt'), 'done');   // blocking
/// await io.async.write('out/report.txt', 'done');   // non-blocking
/// ```
class IoAccessor {
  /// Creates the accessor. Prefer the shared [io] instance.
  const IoAccessor();

  /// CSV parsing, formatting and file access.
  CsvAccessor get csv => const CsvAccessor();

  /// Persistent JSON key-value storage.
  StoreAccessor get store => _store;

  /// The non-blocking mirror of this domain. See [IoAsyncAccessor].
  IoAsyncAccessor get async => const IoAsyncAccessor();

  // --- Path utilities ---

  /// Joins path segments using the platform separator.
  String join(
    String part1, [
    String? part2,
    String? part3,
    String? part4,
    String? part5,
    String? part6,
    String? part7,
    String? part8,
  ]) => p.join(part1, part2, part3, part4, part5, part6, part7, part8);

  /// The final segment of [path], including any extension.
  String base(String path) => p.basename(path);

  /// The final segment of [path] without its extension.
  String name(String path) => p.basenameWithoutExtension(path);

  /// The extension of [path], including the leading dot.
  String ext(String path) => p.extension(path);

  /// The directory portion of [path].
  String dir(String path) => p.dirname(path);

  // --- Existence ---

  /// Whether [path] exists and holds at least one byte.
  ///
  /// Set [match] to also accept a loosely-named sibling — see [Fs.similar],
  /// which is fuzzy enough to produce false positives.
  bool has(String path, {bool match = false}) => Fs.has(path, match: match);

  /// Whether a loosely similarly-named file sits beside [path].
  ///
  /// See [Fs.similar] for the matching rules and their caveats.
  bool similar(String path) => Fs.similar(path);

  // --- Reading ---

  /// Reads [path] as a string.
  String read(String path, {Encoding encoding = utf8}) =>
      File(path).readAsStringSync(encoding: encoding);

  /// Reads [path] as raw bytes.
  List<int> bytes(String path) => File(path).readAsBytesSync();

  /// Reads and decodes the JSON document at [path] as [T].
  ///
  /// Write JSON with [dump]:
  ///
  /// ```dart
  /// io.dump('data.json', {'count': 42});
  /// final data = io.json<Map<String, Object?>>('data.json');
  /// ```
  T json<T>(String path) => Fs.json<T>(path);

  /// Streams [path] as decoded lines.
  Stream<String> lines(String path, {Encoding encoding = utf8}) =>
      Fs.lines(path, encoding: encoding);

  // --- Writing (always atomic, via a `.part` staging file) ---

  /// Writes text [content] to [path] atomically. See [Fs.writeSync].
  File write(
    String path,
    String content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) => Fs.writeSync(path, content, part: part, encoding: encoding);

  /// Writes raw [content] bytes to [path] atomically. See [Fs.saveSync].
  File save(String path, List<int> content, {String part = '.part'}) =>
      Fs.saveSync(path, content, part: part);

  /// Encodes [data] as JSON and writes it to [path] atomically.
  ///
  /// [data] accepts any value `jsonEncode` understands.
  File dump(
    String path,
    Object? data, {
    bool pretty = true,
    String part = '.part',
  }) => Fs.dumpSync(path, data, pretty: pretty, part: part);

  // --- Directories and metadata ---

  /// Replaces characters that are illegal in filenames. See [Fs.sanitize].
  String sanitize(String name, {String replace = '_', bool full = false}) =>
      Fs.sanitize(name, replace: replace, full: full);

  /// Creates the directory at [path], including parents.
  Directory mkdir(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Creates the parent directory of [path] if it is missing.
  void parent(String path) => Fs.parent(path);

  /// Copies [source] to [destination], creating parent directories.
  ///
  /// Recursively copies directories if [source] is a directory.
  FileSystemEntity copy(String source, String destination) {
    final type = FileSystemEntity.typeSync(source);
    if (type == FileSystemEntityType.directory) {
      final srcDir = Directory(source);
      final destDir = Directory(destination)..createSync(recursive: true);
      for (final entity in srcDir.listSync(recursive: true)) {
        final rel = p.relative(entity.path, from: source);
        final targetPath = p.join(destination, rel);
        if (entity is Directory) {
          Directory(targetPath).createSync(recursive: true);
        } else if (entity is File) {
          Fs.parent(targetPath);
          entity.copySync(targetPath);
        }
      }
      return destDir;
    } else {
      Fs.parent(destination);
      return File(source).copySync(destination);
    }
  }

  /// Moves [source] to [destination], creating parent directories.
  ///
  /// Works across filesystems by falling back to copy-and-delete.
  FileSystemEntity move(String source, String destination) {
    Fs.parent(destination);
    try {
      final type = FileSystemEntity.typeSync(source);
      if (type == FileSystemEntityType.directory) {
        return Directory(source).renameSync(destination);
      } else {
        return File(source).renameSync(destination);
      }
    } on FileSystemException {
      final copied = copy(source, destination);
      remove(source);
      return copied;
    }
  }

  /// Removes a file or directory at [path].
  ///
  /// Returns `true` if the entity was removed, or `false` if it did not exist.
  bool remove(String path) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file ||
        type == FileSystemEntityType.link) {
      File(path).deleteSync();
      return true;
    } else if (type == FileSystemEntityType.directory) {
      Directory(path).deleteSync(recursive: true);
      return true;
    }
    return false;
  }

  /// Creates a new temporary directory with the given name [prefix].
  Directory temp([String prefix = 'tmp_']) =>
      Directory.systemTemp.createTempSync(prefix);

  /// Lists files under [dir], optionally filtered by [pattern].
  List<File> find(String dir, {Pattern? pattern, bool recursive = true}) =>
      Fs.find(dir, pattern: pattern, recursive: recursive);

  /// Deletes files under [dir] matching [pattern] and returns the count.
  int delete(String dir, {Pattern? pattern, bool recursive = false}) =>
      Fs.delete(dir, pattern: pattern, recursive: recursive);

  /// Returns the hex digest of [path] using [algorithm].
  String hash(String path, [Algo algorithm = Algo.sha256]) =>
      Fs.hash(path, algorithm);

  /// Returns filesystem metadata for [path].
  FileStat stat(String path) => Fs.stat(path);
}

/// The non-blocking mirror of [IoAccessor], reachable as `io.async`.
///
/// Every operation that touches the disk appears here under the same name and
/// arguments, returning a future instead of blocking. The purely
/// computational helpers — [IoAccessor.join], [IoAccessor.base],
/// [IoAccessor.name], [IoAccessor.ext], [IoAccessor.dir] and
/// [IoAccessor.sanitize] — stay on `io` alone, since there is nothing to wait
/// for. A crawl runs many requests on one isolate, so a blocking read stalls
/// every other task in flight; reach for this inside handlers and pool
/// workers.
///
/// ```dart
/// await net.crawl<String>(seed).collect((res) async {
///   await io.async.write('pages/${res.depth}.html', res.body);
/// });
/// ```
class IoAsyncAccessor {
  /// Creates the accessor. Prefer the shared `io.async` instance.
  const IoAsyncAccessor();

  // --- Existence ---

  /// Whether [path] exists and holds at least one byte.
  Future<bool> has(String path, {bool match = false}) =>
      Fs.hasAsync(path, match: match);

  /// Whether a loosely similarly-named file sits beside [path]. See [Fs.similar].
  Future<bool> similar(String path) => Fs.similarAsync(path);

  // --- Reading ---

  /// Reads [path] as a string.
  Future<String> read(String path, {Encoding encoding = utf8}) =>
      File(path).readAsString(encoding: encoding);

  /// Reads [path] as raw bytes.
  Future<List<int>> bytes(String path) => File(path).readAsBytes();

  /// Reads and decodes the JSON document at [path] as [T].
  Future<T> json<T>(String path) => Fs.jsonAsync<T>(path);

  /// Streams [path] as decoded lines.
  Stream<String> lines(String path, {Encoding encoding = utf8}) =>
      Fs.lines(path, encoding: encoding);

  // --- Writing (always atomic, via a `.part` staging file) ---

  /// Writes text [content] to [path] atomically. See [Fs.write].
  Future<File> write(
    String path,
    String content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) => Fs.write(path, content, part: part, encoding: encoding);

  /// Writes raw [content] bytes to [path] atomically. See [Fs.save].
  Future<File> save(String path, List<int> content, {String part = '.part'}) =>
      Fs.save(path, content, part: part);

  /// Encodes [data] as JSON and writes it to [path] atomically.
  Future<File> dump(
    String path,
    Object? data, {
    bool pretty = true,
    String part = '.part',
  }) => Fs.dump(path, data, pretty: pretty, part: part);

  /// Streams [url] to [path] atomically. See [Fs.download].
  ///
  /// Network-bound, so this has no blocking counterpart on `io`.
  Future<File> download(
    Uri url,
    String path, {
    http.Client? pool,
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    String part = '.part',
  }) => Fs.download(
    url,
    path,
    pool: pool,
    headers: headers,
    onProgress: onProgress,
    part: part,
  );

  // --- Directories and metadata ---

  /// Creates the directory at [path], including parents.
  Future<Directory> mkdir(String path) => Fs.mkdir(path);

  /// Copies [source] to [destination], creating parent directories.
  Future<FileSystemEntity> copy(String source, String destination) =>
      Fs.copyAsync(source, destination);

  /// Moves [source] to [destination], creating parent directories.
  Future<FileSystemEntity> move(String source, String destination) =>
      Fs.moveAsync(source, destination);

  /// Removes a file or directory at [path]; `false` when it did not exist.
  Future<bool> remove(String path) => Fs.removeAsync(path);

  /// Creates a new temporary directory with the given name [prefix].
  Future<Directory> temp([String prefix = 'tmp_']) =>
      Directory.systemTemp.createTemp(prefix);

  /// Lists files under [dir], optionally filtered by [pattern].
  Future<List<File>> find(
    String dir, {
    Pattern? pattern,
    bool recursive = true,
  }) => Fs.findAsync(dir, pattern: pattern, recursive: recursive);

  /// Deletes files under [dir] matching [pattern] and returns the count.
  Future<int> delete(String dir, {Pattern? pattern, bool recursive = false}) =>
      Fs.deleteAsync(dir, pattern: pattern, recursive: recursive);

  /// Returns the hex digest of [path] using [algorithm].
  Future<String> hash(String path, [Algo algorithm = Algo.sha256]) =>
      Fs.hashAsync(path, algorithm);

  /// Returns filesystem metadata for [path].
  Future<FileStat> stat(String path) => FileStat.stat(path);
}

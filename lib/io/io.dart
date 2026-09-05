import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'csv.dart';
import 'file.dart';
import 'store.dart';

export 'csv.dart';
export 'file.dart';
export 'store.dart';

// ============================================================================
// IO DOMAIN (io.*) - File System, Paths, CSV, Store & Archives
// ============================================================================

final StoreAccessor _ioStore = StoreAccessor();

/// Top-level Input/Output accessor singleton (`io.*`).
///
/// Provides unified access to file operations, CSV processing, key-value storage, and archives.
///
/// ```dart
/// // File operations
/// await io.write('data.txt', 'content');
/// final exists = io.has('data.txt');
///
/// // Sub-namespaces
/// final records = await io.csv.read('users.csv');
/// io.store.set('key', 'value');
/// final arch = io.archive('backup.7z');
/// ```
const IoAccessor io = IoAccessor();

/// Top-level Input/Output domain accessor.
class IoAccessor {
  const IoAccessor();

  /// Sub-namespace for file and path operations (`io.file.*`).
  IoAccessor get file => this;

  /// Sub-namespace for CSV parsing, serialization, and file I/O (`io.csv.*`).
  CsvAccessor get csv => const CsvAccessor();

  /// Sub-namespace for persistent JSON key-value storage (`io.store.*`).
  StoreAccessor get store => _ioStore;

  /// Creates or manages an [Archive] for the specified file [path].
  ///
  /// ```dart
  /// final arch = io.archive('backups/data.7z');
  /// await arch.sync('data/');
  /// ```
  Archive archive(String path) => Fs.archive(path);

  // --- Path utilities directly under io namespace ---

  /// Safely joins path segments using the host platform's path separator.
  ///
  /// ```dart
  /// final p = io.join('dir', 'subdir', 'file.txt');
  /// ```
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

  /// Returns the basename of [path] (e.g. `'file.txt'` from `'/dir/file.txt'`).
  String base(String path) => p.basename(path);

  /// Returns the basename of [path] without its extension (e.g. `'file'` from `'/dir/file.txt'`).
  String name(String path) => p.basenameWithoutExtension(path);

  /// Returns the extension of [path] including the dot (e.g. `'.txt'` from `'/dir/file.txt'`).
  String ext(String path) => p.extension(path);

  /// Returns the directory component of [path] (e.g. `'/dir'` from `'/dir/file.txt'`).
  String dir(String path) => p.dirname(path);

  // --- File and directory operations ---

  /// Sanitizes a file or folder [name] to be valid across Windows, macOS, and Linux.
  ///
  /// Replaces illegal characters (`:`, `"`, `/`, `\`, `*`, `?`, `<`, `>`, `|`) with [replace],
  /// or with full-width equivalents if [full] is true.
  /// Strips control characters and trailing dots.
  ///
  /// ```dart
  /// final safe = io.sanitize('AC/DC: Back in Black?.mp3'); // 'AC_DC_ Back in Black_.mp3'
  /// ```
  String sanitize(String name, {String replace = '_', bool full = false}) =>
      Fs.sanitize(name, replace: replace, full: full);

  /// Formats byte count into a human-readable size string (e.g. `'1.5 MB'`, `'250 KB'`).
  String size(int bytes, {int decimals = 1}) =>
      Fs.size(bytes, decimals: decimals);

  /// Parses human-readable size strings (e.g. `'10MB'`, `'2.5 GB'`, `'500K'`) into bytes.
  int parse(String text) => Fs.parse(text);

  /// Formats a [Duration] into `mm:ss` or `hh:mm:ss` format.
  String time(Duration duration) => Fs.time(duration);

  /// Ensures that [path] exists as a directory, creating missing parent folders recursively.
  Future<Directory> mkdir(String path, {bool sync = false}) =>
      Fs.mkdir(path, sync: sync);

  /// Ensures the parent directory of [filePath] exists, creating it recursively if needed.
  void parent(String filePath) => Fs.parent(filePath);

  /// Checks whether [target] file exists and has non-zero byte size.
  ///
  /// If [match] is true, also checks whether a file with matching basename exists in the folder.
  bool has(Object target, {bool match = false}) => Fs.has(target, match: match);

  /// Matches existing files in the directory by basename ignoring common prefix/suffix differences.
  bool match(Object target) => Fs.match(target);

  /// Writes string, raw bytes, or encodable JSON objects atomically to [target] with temporary `.part` tracking.
  ///
  /// If interrupted or aborted, partial files are automatically cleaned up.
  ///
  /// ```dart
  /// await io.write('output.txt', 'Hello');
  /// await io.write('output.json', {'debug': true, 'items': [1, 2, 3]});
  /// ```
  Future<File> write(
    Object target,
    Object content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) {
    final file = target is File ? target : File(target.toString());
    return Fs.write(file, content, part: part, encoding: encoding);
  }

  /// Reads [target] file synchronously as a string with [encoding].
  String read(Object target, {Encoding encoding = utf8}) {
    final file = target is File ? target : File(target.toString());
    return file.readAsStringSync(encoding: encoding);
  }

  /// Reads [target] file synchronously as raw bytes.
  List<int> bytes(Object target) {
    final file = target is File ? target : File(target.toString());
    return file.readAsBytesSync();
  }

  /// Copies [source] file to [destination], creating parent directories as necessary.
  File copy(Object source, Object destination) {
    final src = source is File ? source : File(source.toString());
    final dest = destination is File
        ? destination
        : File(destination.toString());
    Fs.parent(dest.path);
    return src.copySync(dest.path);
  }

  /// Moves or renames [source] file to [destination], creating parent directories as necessary.
  File move(Object source, Object destination) {
    final src = source is File ? source : File(source.toString());
    final dest = destination is File
        ? destination
        : File(destination.toString());
    Fs.parent(dest.path);
    return src.renameSync(dest.path);
  }

  /// Creates a unique temporary directory in the system temp location.
  Directory temp([String prefix = 'tmp_']) =>
      Directory.systemTemp.createTempSync(prefix);

  /// Downloads [url] directly to [destination] file with atomic `.part` writing and progress callback.
  ///
  /// If the download fails or process exits, the partial `.part` file is cleanly discarded.
  Future<File> download(
    Uri url,
    Object destination, {
    http.Client? client,
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    String part = '.part',
  }) {
    final dest = destination is File
        ? destination
        : File(destination.toString());
    return Fs.download(
      url,
      dest,
      client: client,
      headers: headers,
      onProgress: onProgress,
      part: part,
    );
  }

  /// Recursively finds files in [dir] matching an optional regex or string [pattern].
  List<File> find(Object dir, {Pattern? pattern, bool recursive = true}) {
    final d = dir is Directory ? dir : Directory(dir.toString());
    return Fs.find(d, pattern: pattern, recursive: recursive);
  }

  /// Deletes files in [dir] matching an optional [pattern] and returns the count of deleted files.
  int delete(Object dir, {Pattern? pattern, bool recursive = false}) {
    final d = dir is Directory ? dir : Directory(dir.toString());
    return Fs.delete(d, pattern: pattern, recursive: recursive);
  }

  /// Reads or writes JSON data.
  ///
  /// If [data] is omitted, synchronously reads and parses JSON from [target].
  /// If [data] is provided, serializes [data] and atomically writes it to [target].
  ///
  /// ```dart
  /// // Read JSON
  /// final config = io.json('config.json');
  ///
  /// // Write JSON atomically
  /// await io.json('config.json', {'debug': true}, true);
  /// ```
  T json<T>(Object target, [Object? data, bool pretty = false]) =>
      Fs.json<T>(target, data, pretty);

  /// Streams lines from [target] file asynchronously using [encoding].
  ///
  /// ```dart
  /// await for (final line in io.lines('large_dataset.csv')) {
  ///   print(line);
  /// }
  /// ```
  Stream<String> lines(Object target, {Encoding encoding = utf8}) =>
      Fs.lines(target, encoding: encoding);

  /// Computes the cryptographic checksum (SHA-256 or MD5) of [target] file.
  ///
  /// ```dart
  /// final sha = io.hash('release.zip');
  /// final md5Hex = io.hash('release.zip', 'md5');
  /// ```
  String hash(Object target, [String algorithm = 'sha256']) =>
      Fs.hash(target, algorithm);

  /// Retrieves status and timestamp metadata for [target].
  FileStat stat(Object target) => Fs.stat(target);
}

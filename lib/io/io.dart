/// # IO Domain (`io.*`)
///
/// The filesystem. `io` itself is about **one file** — asking what is at a
/// path, reading it, writing it atomically, moving it, removing it. The two
/// things that are not about one file have namespaces of their own:
///
/// - `io.path` — everything answerable about a path **without touching the
///   disk**: [PathAccessor.join], [PathAccessor.dirname],
///   [PathAccessor.stem], [PathAccessor.parts]. No async twin, because there
///   is nothing to wait for.
/// - `io.dir` — making directories and looking inside them:
///   [DirAccessor.make], [DirAccessor.list], [DirAccessor.walk],
///   [DirAccessor.glob]. Creating a directory is not what `io` is mainly for,
///   and Rule 3 says a vocabulary with its own nouns gets its own name.
///
/// Plus `io.csv` for the two CSV operations that are about a file larger than
/// memory, and `io.async` for the whole thing again without blocking.
///
/// **The read and write halves are spelled the same.** The name says the
/// shape, and `.write` is how it goes back: `io.read`/`io.write` for text,
/// `io.bytes`/`io.bytes.write`, `io.lines`/`io.lines.write`,
/// `io.chunks`/`io.chunks.write`, `io.csv.rows`/`io.csv.write`. A reader who
/// learns one has learned all five. `io.save` was the exception through
/// 5.5.0 — bytes, under a name that is the same English word as `write` and
/// says nothing about which of the two takes them.
///
/// **One type here owns a resource.** Everything else is a value or an
/// accessor, and every other member is complete when it returns.
/// [Appender] — from `io.append.open(path)` — holds a descriptor open until
/// `close()`, because a loop that appends ten thousand lines should not
/// reopen the file ten thousand times. It is the one thing in `io` that needs
/// a `finally`.
///
/// Reading a JSON, YAML or TOML *document* is `format.*`: a format is
/// knowledge from outside Dart, so all of them live in one family rather than
/// one of them here. [dump] still writes one, because staging through a
/// `.part` file is this domain's job. Downloading is `net.http.download`,
/// because a socket is `net`'s.
///
/// `io.*` blocks; `io.async.*` is the same set of names without blocking the
/// event loop. Inside a crawl, or anywhere else with work in flight, reach
/// for `io.async`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'csv.dart' as csv_impl;
import 'entry.dart';
import '../src/entries.dart';
import '../src/fs.dart';
import '../src/lock.dart';
import '../src/watch.dart';

import 'package:path/path.dart' as p;

export 'csv.dart';
export 'entry.dart';
export 'io_extensions.dart';
export '../src/fs.dart' show Algo;
export '../src/lock.dart' show LockedError;

// ============================================================================
// TOP-LEVEL ATOMIC I/O & FILESYSTEM HELPERS
// ============================================================================

/// Reads [path] as a UTF-8 (or given [encoding]) string asynchronously.
Future<String> readText(String path, {Encoding encoding = utf8}) =>
    File(path).readAsString(encoding: encoding);

/// Reads [path] as a UTF-8 (or given [encoding]) string synchronously.
String readTextSync(String path, {Encoding encoding = utf8}) =>
    File(path).readAsStringSync(encoding: encoding);

/// Reads [path] as raw bytes asynchronously.
Future<List<int>> readBytes(String path) => File(path).readAsBytes();

/// Reads [path] as raw bytes synchronously.
List<int> readBytesSync(String path) => File(path).readAsBytesSync();

/// Reads [path] as a list of lines asynchronously.
Future<List<String>> readLines(String path, {Encoding encoding = utf8}) =>
    File(path).readAsLines(encoding: encoding);

/// Reads [path] as a list of lines synchronously.
List<String> readLinesSync(String path, {Encoding encoding = utf8}) =>
    File(path).readAsLinesSync(encoding: encoding);

/// Reads and decodes JSON from [path] asynchronously.
Future<dynamic> readJson(String path) async {
  final text = await File(path).readAsString();
  return jsonDecode(text);
}

/// Reads and decodes JSON from [path] synchronously.
dynamic readJsonSync(String path) {
  final text = File(path).readAsStringSync();
  return jsonDecode(text);
}

/// Writes [content] to [path] atomically via a temporary staging file.
Future<FileSystemEntry> writeText(
  String path,
  String content, {
  String part = '.part',
  Encoding encoding = utf8,
}) async => Fs.entryFor(
  (await Fs.write(path, content, part: part, encoding: encoding)).path,
);

/// Writes [content] to [path] atomically and synchronously.
FileSystemEntry writeTextSync(
  String path,
  String content, {
  String part = '.part',
  Encoding encoding = utf8,
}) => Fs.entryFor(
  Fs.writeSync(path, content, part: part, encoding: encoding).path,
);

/// Writes raw [bytes] to [path] atomically via a temporary staging file.
Future<FileSystemEntry> writeBytes(
  String path,
  List<int> bytes, {
  String part = '.part',
}) async => Fs.entryFor((await Fs.save(path, bytes, part: part)).path);

/// Writes raw [bytes] to [path] atomically and synchronously.
FileSystemEntry writeBytesSync(
  String path,
  List<int> bytes, {
  String part = '.part',
}) => Fs.entryFor(Fs.saveSync(path, bytes, part: part).path);

/// Writes [lines] to [path] atomically, one per line.
Future<FileSystemEntry> writeLines(
  String path,
  Iterable<String> lines, {
  String newline = '\n',
  Encoding encoding = utf8,
  String part = '.part',
}) async => Fs.entryFor(
  (await Fs.pourLines(
    path,
    Stream.fromIterable(lines),
    newline: newline,
    encoding: encoding,
    part: part,
  )).path,
);

/// Writes [lines] to [path] atomically and synchronously.
FileSystemEntry writeLinesSync(
  String path,
  Iterable<String> lines, {
  String newline = '\n',
  Encoding encoding = utf8,
  String part = '.part',
}) => Fs.entryFor(
  Fs.writeLinesSync(
    path,
    lines.toList(),
    newline: newline,
    encoding: encoding,
    part: part,
  ).path,
);

/// Serializes [data] as JSON and writes it to [path] atomically.
Future<FileSystemEntry> writeJson(
  String path,
  Object? data, {
  bool pretty = true,
  String part = '.part',
}) async =>
    Fs.entryFor((await Fs.dump(path, data, pretty: pretty, part: part)).path);

/// Serializes [data] as JSON and writes it to [path] atomically and synchronously.
FileSystemEntry writeJsonSync(
  String path,
  Object? data, {
  bool pretty = true,
  String part = '.part',
}) => Fs.entryFor(Fs.dumpSync(path, data, pretty: pretty, part: part).path);

/// Whether a file or entity exists at [path].
bool fileExists(String path) => File(path).existsSync();

/// Whether a directory exists at [path].
bool dirExists(String path) => Directory(path).existsSync();

/// Gets metadata for [path], or `null` if it does not exist.
FileSystemEntry? fileStat(String path) => Fs.stat(path);

/// Removes a file, link or directory at [path] asynchronously.
Future<bool> removePath(String path) => Fs.removeAsync(path);

/// Removes a file, link or directory at [path] synchronously.
bool removePathSync(String path) => Fs.removeSync(path);

/// Copies [source] to [destination] asynchronously, creating parent directories.
Future<FileSystemEntry> copyPath(String source, String destination) =>
    Fs.copyAsync(source, destination);

/// Copies [source] to [destination] synchronously, creating parent directories.
FileSystemEntry copyPathSync(String source, String destination) =>
    Fs.copySync(source, destination);

/// Moves [source] to [destination] asynchronously, creating parent directories.
Future<FileSystemEntry> movePath(String source, String destination) =>
    Fs.moveAsync(source, destination);

/// Moves [source] to [destination] synchronously, creating parent directories.
FileSystemEntry movePathSync(String source, String destination) =>
    Fs.moveSync(source, destination);

/// Creates directory [path] asynchronously, creating missing parents.
Future<FileSystemEntry> makeDir(String path) => Fs.mkdir(path);

/// Creates directory [path] synchronously, creating missing parents.
FileSystemEntry makeDirSync(String path) => Fs.mkdirSync(path);

/// Lists entries directly under [path] asynchronously.
Future<List<FileSystemEntry>> listDir(
  String path, {
  bool recursive = false,
  String? match,
}) => Entries.walkAsync(path, match: match, depth: recursive ? null : 1).toList();

/// Lists entries directly under [path] synchronously.
List<FileSystemEntry> listDirSync(
  String path, {
  bool recursive = false,
  String? match,
}) => recursive
    ? Entries.walk(path, match: match).toList()
    : Entries.list(path, match: match).toList();

/// Recursively walks [path] asynchronously, yielding entries matching [match].
Future<List<FileSystemEntry>> walkDir(
  String path, {
  String? match,
  int? depth,
}) => Entries.walkAsync(path, match: match, depth: depth).toList();

/// Recursively walks [path] synchronously, yielding entries matching [match].
List<FileSystemEntry> walkDirSync(
  String path, {
  String? match,
  int? depth,
}) => Entries.walk(path, match: match, depth: depth).toList();

/// Creates a new temporary directory asynchronously.
Future<FileSystemEntry> tempDir([String prefix = 'tmp_']) => Fs.temp(prefix);

/// Creates a new temporary directory synchronously.
FileSystemEntry tempDirSync([String prefix = 'tmp_']) => Fs.tempSync(prefix);

/// Creates a new empty temporary file asynchronously.
Future<FileSystemEntry> tempFile([String prefix = 'tmp_']) =>
    Fs.tempfile(prefix);

/// Creates a new empty temporary file synchronously.
FileSystemEntry tempFileSync([String prefix = 'tmp_']) =>
    Fs.tempfileSync(prefix);

/// Runs [action] with the lock file [path] held, safe across OS processes.
Future<R> withLock<R>(
  String path,
  FutureOr<R> Function() action, {
  Duration? wait,
}) => Lock.hold(path, action, wait: wait);

/// Runs [action] synchronously with the lock file [path] held.
R withLockSync<R>(String path, R Function() action) =>
    Lock.holdSync(path, action);

/// Whether the lock file at [path] is currently held by a live process.
bool isLocked(String path) => Lock.held(path);

/// Watches for filesystem changes at [path]. Returns a function that stops watching.
Future<void> Function() watchPath(
  String path,
  void Function(String path) onchange, {
  Pattern? pattern,
  Duration settle = const Duration(milliseconds: 200),
  bool recursive = true,
}) => Watch.start(
  path,
  onchange,
  pattern: pattern,
  settle: settle,
  recursive: recursive,
);

/// Joins path segments using the platform separator.
String joinPath(
  String part1, [
  String? part2,
  String? part3,
  String? part4,
  String? part5,
  String? part6,
  String? part7,
  String? part8,
]) => p.join(part1, part2, part3, part4, part5, part6, part7, part8);

/// The directory portion of [path].
String dirname(String path) => p.dirname(path);

/// The final segment of [path], including extension.
String filename(String path) => p.basename(path);

/// The final segment of [path] without extension.
String stemName(String path) => p.basenameWithoutExtension(path);

/// The extension of [path], including the leading dot.
String fileExtension(String path) => p.extension(path);

/// The current working directory path.
String get cwd => Fs.cwd;

/// The current user's home directory path.
String get home => Fs.home;

/// Splits [path] into individual segments.
List<String> pathParts(String path) => p.split(path);

/// Normalizes [path] by resolving `.` and `..`.
String normalizePath(String path) => p.normalize(path);

/// Resolves [path] to an absolute path.
String absolutePath(String path) => p.absolute(path);

/// Returns [path] relative to [from] (or current directory).
String relativePath(String path, {String? from}) => p.relative(path, from: from);

/// Expands leading `~` and `$VAR` environment variables in [path].
String expandPath(String path) {
  var out = path;
  if (out == '~') {
    out = Fs.home;
  } else if (out.startsWith('~/') || out.startsWith('~\\')) {
    out = p.join(Fs.home, out.substring(2));
  }
  return out.replaceAllMapped(
    RegExp(r'\$\{(\w+)\}|\$(\w+)'),
    (m) => Platform.environment[m.group(1) ?? m.group(2)!] ?? '',
  );
}

/// Replaces characters that are illegal in filenames.
String sanitizeFilename(String name, {String replace = '_', bool full = false}) =>
    Fs.sanitize(name, replace: replace, full: full);

/// Finds entries matching a shell-style glob [pattern] asynchronously.
Future<List<FileSystemEntry>> glob(String pattern) =>
    Entries.expandAsync(pattern).toList();

/// Finds entries matching a shell-style glob [pattern] synchronously.
List<FileSystemEntry> globSync(String pattern) =>
    Entries.expand(pattern).toList();

/// Static helper hub for all filesystem operations.
///
/// Easily discoverable via auto-complete:
/// ```dart
/// await Files.writeText('out.txt', 'hello');
/// final content = await Files.readText('out.txt');
/// final files = await Files.walk('src', match: '*.dart');
/// ```
abstract final class Files {
  Files._();

  /// Reads [path] as a UTF-8 string asynchronously.
  static Future<String> readText(String path, {Encoding encoding = utf8}) =>
      File(path).readAsString(encoding: encoding);

  /// Reads [path] as a UTF-8 string synchronously.
  static String readTextSync(String path, {Encoding encoding = utf8}) =>
      File(path).readAsStringSync(encoding: encoding);

  /// Reads [path] as a list of lines asynchronously.
  static Future<List<String>> readLines(
    String path, {
    Encoding encoding = utf8,
  }) => File(path).readAsLines(encoding: encoding);

  /// Reads [path] as a list of lines synchronously.
  static List<String> readLinesSync(
    String path, {
    Encoding encoding = utf8,
  }) => File(path).readAsLinesSync(encoding: encoding);

  /// Reads raw bytes from [path] asynchronously.
  static Future<Uint8List> readBytes(String path) => File(path).readAsBytes();

  /// Reads raw bytes from [path] synchronously.
  static Uint8List readBytesSync(String path) => File(path).readAsBytesSync();

  /// Reads and decodes JSON from [path] asynchronously.
  static Future<dynamic> readJson(String path) async {
    final text = await File(path).readAsString();
    return jsonDecode(text);
  }

  /// Reads and decodes JSON from [path] synchronously.
  static dynamic readJsonSync(String path) {
    final text = File(path).readAsStringSync();
    return jsonDecode(text);
  }

  /// Writes [content] to [path] atomically.
  static Future<FileSystemEntry> writeText(
    String path,
    String content, {
    Encoding encoding = utf8,
    String part = '.part',
  }) async => Fs.entryFor(
    (await Fs.write(path, content, part: part, encoding: encoding)).path,
  );

  /// Writes [content] to [path] atomically and synchronously.
  static FileSystemEntry writeTextSync(
    String path,
    String content, {
    Encoding encoding = utf8,
    String part = '.part',
  }) => Fs.entryFor(
    Fs.writeSync(path, content, part: part, encoding: encoding).path,
  );

  /// Writes [lines] to [path] atomically.
  static Future<FileSystemEntry> writeLines(
    String path,
    Iterable<String> lines, {
    String newline = '\n',
    Encoding encoding = utf8,
    String part = '.part',
  }) async => Fs.entryFor(
    (await Fs.pourLines(
      path,
      Stream.fromIterable(lines),
      newline: newline,
      encoding: encoding,
      part: part,
    )).path,
  );

  /// Writes [lines] to [path] atomically and synchronously.
  static FileSystemEntry writeLinesSync(
    String path,
    Iterable<String> lines, {
    String newline = '\n',
    Encoding encoding = utf8,
    String part = '.part',
  }) => Fs.entryFor(
    Fs.writeLinesSync(
      path,
      lines.toList(),
      newline: newline,
      encoding: encoding,
      part: part,
    ).path,
  );

  /// Writes raw [bytes] to [path] atomically.
  static Future<FileSystemEntry> writeBytes(
    String path,
    List<int> bytes, {
    String part = '.part',
  }) async => Fs.entryFor((await Fs.save(path, bytes, part: part)).path);

  /// Writes raw [bytes] to [path] atomically and synchronously.
  static FileSystemEntry writeBytesSync(
    String path,
    List<int> bytes, {
    String part = '.part',
  }) => Fs.entryFor(Fs.saveSync(path, bytes, part: part).path);

  /// Serializes [data] as JSON and writes to [path] atomically.
  static Future<FileSystemEntry> writeJson(
    String path,
    Object? data, {
    bool pretty = true,
    String part = '.part',
  }) async =>
      Fs.entryFor((await Fs.dump(path, data, pretty: pretty, part: part)).path);

  /// Serializes [data] as JSON and writes to [path] atomically and synchronously.
  static FileSystemEntry writeJsonSync(
    String path,
    Object? data, {
    bool pretty = true,
    String part = '.part',
  }) => Fs.entryFor(Fs.dumpSync(path, data, pretty: pretty, part: part).path);

  /// Appends [content] to [path] asynchronously.
  static Future<FileSystemEntry> append(
    String path,
    String content, {
    Encoding encoding = utf8,
  }) => Fs.append(path, content, encoding: encoding);

  /// Appends [content] to [path] synchronously.
  static FileSystemEntry appendSync(
    String path,
    String content, {
    Encoding encoding = utf8,
  }) => Fs.appendSync(path, content, encoding: encoding);

  /// Whether a file or directory exists at [path].
  static bool exists(String path) => fileExists(path) || dirExists(path);

  /// Whether [path] exists and is non-empty.
  static bool has(String path) => Fs.has(path);

  /// Whether [path] exists and is non-empty asynchronously.
  static Future<bool> hasAsync(String path) => Fs.hasAsync(path);

  /// Computes the hash digest of [path] synchronously.
  static String hashSync(String path, [Algo algo = Algo.sha256]) =>
      Fs.hash(path, algo);

  /// Computes the hash digest of [path] asynchronously.
  static Future<String> hash(String path, [Algo algo = Algo.sha256]) =>
      Fs.hashAsync(path, algo);

  /// Whether a file exists at [path].
  static bool isFile(String path) => fileExists(path);

  /// Whether a directory exists at [path].
  static bool isDir(String path) => dirExists(path);

  /// Metadata for [path], or `null` if missing.
  static FileSystemEntry? stat(String path) => fileStat(path);

  /// Metadata for [path] synchronously, or `null` if missing.
  static FileSystemEntry? statSync(String path) => fileStat(path);

  /// Lists entries directly under [path] asynchronously.
  static Future<List<FileSystemEntry>> list(
    String path, {
    bool recursive = false,
    String? match,
  }) => listDir(path, recursive: recursive, match: match);

  /// Lists entries directly under [path] synchronously.
  static List<FileSystemEntry> listSync(
    String path, {
    bool recursive = false,
    String? match,
  }) => listDirSync(path, recursive: recursive, match: match);

  /// Recursively walks [path] asynchronously.
  static Future<List<FileSystemEntry>> walk(
    String path, {
    String? match,
    int? depth,
  }) => walkDir(path, match: match, depth: depth);

  /// Recursively walks [path] synchronously.
  static List<FileSystemEntry> walkSync(
    String path, {
    String? match,
    int? depth,
  }) => walkDirSync(path, match: match, depth: depth);

  /// Deletes files in [dir] matching [match] and returns the count of removed files.
  static int sweepSync(String dir, {String? match}) {
    var count = 0;
    for (final entry in walkSync(dir, match: match)) {
      if (entry.isfile || entry.islink) {
        if (removeSync(entry.path)) count++;
      }
    }
    return count;
  }

  /// Deletes files in [dir] matching [match] asynchronously and returns the count of removed files.
  static Future<int> sweep(String dir, {String? match}) async {
    var count = 0;
    for (final entry in await walk(dir, match: match)) {
      if (entry.isfile || entry.islink) {
        if (await remove(entry.path)) count++;
      }
    }
    return count;
  }

  /// Calculates the total recursive size in bytes of [dir] synchronously.
  static int dirSizeSync(String dir) {
    var total = 0;
    for (final entry in walkSync(dir)) {
      total += entry.size;
    }
    return total;
  }

  /// Calculates the total recursive size in bytes of [dir] asynchronously.
  static Future<int> dirSize(String dir) async {
    var total = 0;
    for (final entry in await walk(dir)) {
      total += entry.size;
    }
    return total;
  }

  /// Whether directory [dir] is empty synchronously.
  static bool isDirEmptySync(String dir) => Entries.empty(dir);

  /// Whether directory [dir] is empty asynchronously.
  static Future<bool> isDirEmpty(String dir) => Entries.emptyAsync(dir);

  /// Creates directory [path] asynchronously.
  static Future<FileSystemEntry> makeDir(String path) => Fs.mkdir(path);

  /// Creates directory [path] synchronously.
  static FileSystemEntry makeDirSync(String path) => Fs.mkdirSync(path);

  /// Removes a file, link, or directory at [path] asynchronously.
  static Future<bool> remove(String path) => removePath(path);

  /// Removes a file, link, or directory at [path] synchronously.
  static bool removeSync(String path) => removePathSync(path);

  /// Deletes a file, link, or directory at [path] asynchronously.
  static Future<bool> delete(String path) => remove(path);

  /// Deletes a file, link, or directory at [path] synchronously.
  static bool deleteSync(String path) => removeSync(path);

  /// Copies [source] to [destination] asynchronously.
  static Future<FileSystemEntry> copy(String source, String destination) =>
      copyPath(source, destination);

  /// Copies [source] to [destination] synchronously.
  static FileSystemEntry copySync(String source, String destination) =>
      copyPathSync(source, destination);

  /// Moves [source] to [destination] asynchronously.
  static Future<FileSystemEntry> move(String source, String destination) =>
      movePath(source, destination);

  /// Moves [source] to [destination] synchronously.
  static FileSystemEntry moveSync(String source, String destination) =>
      movePathSync(source, destination);

  /// Creates a temporary directory asynchronously.
  static Future<FileSystemEntry> tempDir([String prefix = 'tmp_']) =>
      Fs.temp(prefix);

  /// Creates a temporary directory synchronously.
  static FileSystemEntry tempDirSync([String prefix = 'tmp_']) =>
      Fs.tempSync(prefix);

  /// Creates an empty temporary file asynchronously.
  static Future<FileSystemEntry> tempFile([String prefix = 'tmp_']) =>
      Fs.tempfile(prefix);

  /// Creates an empty temporary file synchronously.
  static FileSystemEntry tempFileSync([String prefix = 'tmp_']) =>
      Fs.tempfileSync(prefix);

  /// Runs [action] with the lock file at [path] held asynchronously.
  static Future<R> lock<R>(
    String path,
    FutureOr<R> Function() action, {
    Duration? wait,
  }) => withLock(path, action, wait: wait);

  /// Runs [action] with the lock file at [path] held synchronously.
  static R lockSync<R>(String path, R Function() action) =>
      withLockSync(path, action);

  /// Whether the lock file at [path] is currently held by a live process.
  static bool isLocked(String path) => Lock.held(path);

  /// Watches filesystem changes at [path].
  static Future<void> Function() watch(
    String path,
    void Function(String path) onchange, {
    Pattern? pattern,
    Duration settle = const Duration(milliseconds: 200),
    bool recursive = true,
  }) => watchPath(path, onchange, pattern: pattern, settle: settle, recursive: recursive);

  /// The current working directory path.
  static String get cwd => Fs.cwd;

  /// The current user's home directory path.
  static String get home => Fs.home;

  /// Joins path segments using the platform separator.
  static String join(
    String part1, [
    String? part2,
    String? part3,
    String? part4,
    String? part5,
    String? part6,
    String? part7,
    String? part8,
  ]) => p.join(part1, part2, part3, part4, part5, part6, part7, part8);

  /// The directory portion of [path].
  static String dirname(String path) => p.dirname(path);

  /// The final segment of [path], including extension.
  static String filename(String path) => p.basename(path);

  /// The final segment of [path] without extension.
  static String stem(String path) => p.basenameWithoutExtension(path);

  /// The extension of [path], including the leading dot.
  static String ext(String path) => p.extension(path);

  /// Splits [path] into individual segments.
  static List<String> parts(String path) => p.split(path);

  /// Normalizes [path] by resolving `.` and `..`.
  static String normalize(String path) => p.normalize(path);

  /// Resolves [path] to an absolute path.
  static String abs(String path) => p.absolute(path);

  /// Returns [path] relative to [from] (or current directory).
  static String rel(String path, {String? from}) => p.relative(path, from: from);

  /// Expands leading `~` and `$VAR` environment variables in [path].
  static String expand(String path) => expandPath(path);

  /// Replaces characters that are illegal in filenames.
  static String sanitize(String name, {String replace = '_', bool full = false}) =>
      Fs.sanitize(name, replace: replace, full: full);

  /// Finds entries matching a shell-style glob [pattern] asynchronously.
  static Future<List<FileSystemEntry>> glob(String pattern) =>
      Entries.expandAsync(pattern).toList();

  /// Finds entries matching a shell-style glob [pattern] synchronously.
  static List<FileSystemEntry> globSync(String pattern) =>
      Entries.expand(pattern).toList();

  /// Creates a symbolic link at [path] pointing to [target] synchronously.
  static FileSystemEntry linkSync(String path, String target) =>
      Fs.linkSync(path, target);

  /// Creates a symbolic link at [path] pointing to [target] asynchronously.
  static Future<FileSystemEntry> link(String path, String target) =>
      Fs.link(path, target);

  /// Resolves the raw target of a symbolic link at [path] synchronously.
  static String? symlinkTargetSync(String path) => Fs.targetSync(path);

  /// Resolves the raw target of a symbolic link at [path] asynchronously.
  static Future<String?> symlinkTarget(String path) => Fs.target(path);

  /// Reads CSV rows from [path] synchronously.
  static Iterable<List<String>> readCsvRowsSync(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) => csv_impl.readCsvRowsSync(path, delimiter: delimiter, encoding: encoding);

  /// Reads CSV rows from [path] asynchronously.
  static Stream<List<String>> readCsvRows(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) => csv_impl.readCsvRows(path, delimiter: delimiter, encoding: encoding);

  /// Reads CSV records from [path] synchronously.
  static Iterable<Map<String, String>> readCsvRecordsSync(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) => csv_impl.readCsvRecordsSync(path, delimiter: delimiter, encoding: encoding);

  /// Reads CSV records from [path] asynchronously.
  static Stream<Map<String, String>> readCsvRecords(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) => csv_impl.readCsvRecords(path, delimiter: delimiter, encoding: encoding);

  /// Writes CSV [rows] to [path] atomically and synchronously.
  static FileSystemEntry writeCsvSync<V>(
    String path,
    Iterable<Map<String, V>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
    String part = '.part',
  }) => csv_impl.writeCsvSync(
    path,
    rows,
    headers: headers,
    delimiter: delimiter,
    newline: newline,
    part: part,
  );

  /// Writes CSV [rows] to [path] as they arrive, atomically.
  static Future<FileSystemEntry> writeCsv<V>(
    String path,
    Stream<Map<String, V>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
    String part = '.part',
    Encoding encoding = utf8,
  }) => csv_impl.writeCsv(
    path,
    rows,
    headers: headers,
    delimiter: delimiter,
    newline: newline,
    part: part,
    encoding: encoding,
  );
}

/// Shorthand alias for [Files].
typedef IO = Files;

/// # Filesystem
///
/// Reading, writing, listing and watching files — with **every write atomic**:
/// content is staged through a `.part` file and renamed into place, so a file
/// appears whole or not at all even if the script is killed mid-write.
///
/// Each operation is a top-level function, and each has a `Sync` twin. The
/// async one is the default; reach for `Sync` only in a short script where
/// blocking the event loop costs nothing.
///
/// ```dart
/// final config = await readJson('config.json');
/// await writeText('out/report.txt', report);       // atomic
/// await writeJson('out/data.json', rows);          // atomic
///
/// for (final entry in await walkDir('src', match: '*.dart')) {
///   print('${entry.path} ${entry.size}');
/// }
///
/// await withLock('sync.lock', () async => rebuild());
/// ```
///
/// **Names say what they act on**, because a bare `list`, `copy` or `join` at
/// top level says nothing: [listDir], [walkDir], [makeDir], [copyPath],
/// [movePath], [removePath], [joinPath], [fileExists], [dirExists].
///
/// Path questions — [joinPath], [dirname], [filename], [stemName],
/// [fileExtension], [pathParts], [normalizePath] — never touch the disk and so
/// have no async twin.
///
/// **One type here owns a resource.** [Appender] holds a descriptor open until
/// `close()`, because a loop that appends ten thousand lines should not reopen
/// the file ten thousand times. It is the one thing here that needs a
/// `finally`.
///
/// Reading a JSON, YAML or TOML *document* is the `format` library: a format
/// is knowledge from outside Dart, so all of them live in one family rather
/// than one of them here. [writeJson] still writes one, because staging
/// through a `.part` file is this library's job. Downloading is [download],
/// because a socket belongs to `net`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
}) =>
    Entries.walkAsync(path, match: match, depth: recursive ? null : 1).toList();

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
List<FileSystemEntry> walkDirSync(String path, {String? match, int? depth}) =>
    Entries.walk(path, match: match, depth: depth).toList();

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
String relativePath(String path, {String? from}) =>
    p.relative(path, from: from);

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
String sanitizeFilename(
  String name, {
  String replace = '_',
  bool full = false,
}) => Fs.sanitize(name, replace: replace, full: full);

/// Finds entries matching a shell-style glob [pattern] asynchronously.
Future<List<FileSystemEntry>> glob(String pattern) =>
    Entries.expandAsync(pattern).toList();

/// Finds entries matching a shell-style glob [pattern] synchronously.
List<FileSystemEntry> globSync(String pattern) =>
    Entries.expand(pattern).toList();

/// Appends [content] to the file at [path].
///
/// Creates the file when it is not there. Unlike [writeText] this is not
/// atomic: a log is appended to, not replaced.
Future<FileSystemEntry> appendText(
  String path,
  String content, {
  Encoding encoding = utf8,
}) => Fs.append(path, content, encoding: encoding);

/// Appends [content] to the file at [path] synchronously.
FileSystemEntry appendTextSync(
  String path,
  String content, {
  Encoding encoding = utf8,
}) => Fs.appendSync(path, content, encoding: encoding);

/// Whether anything — file, directory or link — exists at [path].
///
/// [fileExists] and [dirExists] are the narrower questions.
bool pathExists(String path) => fileExists(path) || dirExists(path);

/// Whether [path] exists and holds something, i.e. is not a zero-byte file.
///
/// The check to make before parsing a file another process may still be
/// writing: an empty file exists but has nothing to read.
bool hasContent(String path) => Fs.has(path);

/// Whether [path] exists and holds something, asynchronously.
Future<bool> hasContentAsync(String path) => Fs.hasAsync(path);

/// The digest of the file at [path], as lowercase hex.
///
/// Streams the file rather than loading it, so it is safe on one larger than
/// memory. Returns the empty-input digest when [path] is not there.
Future<String> fileHash(String path, [Algo algo = Algo.sha256]) =>
    Fs.hashAsync(path, algo);

/// The digest of the file at [path] synchronously, as lowercase hex.
String fileHashSync(String path, [Algo algo = Algo.sha256]) =>
    Fs.hash(path, algo);

/// Deletes files under [dir] matching [match], returning how many went.
///
/// Directories are left in place; only files and links are removed.
Future<int> sweepDir(String dir, {String? match}) async {
  var count = 0;
  for (final entry in await walkDir(dir, match: match)) {
    if (entry.isFile || entry.isLink) {
      if (await removePath(entry.path)) count++;
    }
  }
  return count;
}

/// Deletes files under [dir] matching [match] synchronously.
int sweepDirSync(String dir, {String? match}) {
  var count = 0;
  for (final entry in walkDirSync(dir, match: match)) {
    if (entry.isFile || entry.isLink) {
      if (removePathSync(entry.path)) count++;
    }
  }
  return count;
}

/// The total size in bytes of everything under [dir], recursively.
Future<int> dirSize(String dir) async {
  var total = 0;
  for (final entry in await walkDir(dir)) {
    total += entry.size;
  }
  return total;
}

/// The total size in bytes of everything under [dir], synchronously.
int dirSizeSync(String dir) {
  var total = 0;
  for (final entry in walkDirSync(dir)) {
    total += entry.size;
  }
  return total;
}

/// Whether the directory [dir] holds no entries.
Future<bool> isDirEmpty(String dir) => Entries.emptyAsync(dir);

/// Whether the directory [dir] holds no entries, synchronously.
bool isDirEmptySync(String dir) => Entries.empty(dir);

/// Creates a symbolic link at [path] pointing to [target].
Future<FileSystemEntry> createLink(String path, String target) =>
    Fs.link(path, target);

/// Creates a symbolic link at [path] pointing to [target] synchronously.
FileSystemEntry createLinkSync(String path, String target) =>
    Fs.linkSync(path, target);

/// The raw target of the symbolic link at [path], or `null` if it is not one.
Future<String?> readLink(String path) => Fs.target(path);

/// The raw target of the symbolic link at [path] synchronously.
String? readLinkSync(String path) => Fs.targetSync(path);

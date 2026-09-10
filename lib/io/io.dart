/// # IO Domain (`io.*`)
///
/// Filesystem access, path manipulation, CSV tables (`io.csv`) and a JSON
/// key-value store (`io.store`). Every write is atomic — see [Fs].
///
/// Reading a JSON *document* is `format.json.read`, beside `format.yaml` and
/// `format.toml`: a format is knowledge from outside Dart, so all three live in
/// one family rather than one of them here. `io.dump` still writes one,
/// because staging through a `.part` file is this domain's job.
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
import '../src/lock.dart';
import '../src/watch.dart';
import '../util/sequence.dart';
import 'store.dart';

export 'csv.dart';
export '../src/fs.dart' show Algo;
export '../src/lock.dart' show LockedError;
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

  /// [path] made absolute against the current directory.
  String abs(String path) => p.absolute(path);

  /// [path] made relative to [from], or to the current directory.
  String rel(String path, {String? from}) => p.relative(path, from: from);

  /// The current working directory.
  String get cwd => Directory.current.path;

  /// The current user's home directory.
  ///
  /// `$HOME` on POSIX and `%USERPROFILE%` on Windows, falling back to
  /// `%HOMEDRIVE%%HOMEPATH%` and finally to [cwd], so this never returns
  /// `null` for a script to handle.
  String get home {
    final env = Platform.environment;
    final named =
        Platform.isWindows
            ? env['USERPROFILE'] ??
                ((env['HOMEDRIVE'] ?? '') + (env['HOMEPATH'] ?? ''))
            : env['HOME'];
    return named == null || named.isEmpty ? cwd : named;
  }

  /// [path] with a leading `~` and any `$VAR` references resolved.
  ///
  /// `~` expands to [home] only at the start of the path, which is the only
  /// place a shell expands it either. `$VAR` and `${VAR}` read from the
  /// process environment, and a name that is not set expands to nothing —
  /// the same as a shell, and the reason this is not `env.read`'s job.
  ///
  /// ```dart
  /// io.expand('~/.config/mytool/config.json');
  /// io.expand(r'$XDG_CACHE_HOME/mytool');
  /// ```
  String expand(String path) {
    var out = path;
    if (out == '~') {
      out = home;
    } else if (out.startsWith('~/') || out.startsWith('~\\')) {
      out = p.join(home, out.substring(2));
    }
    return out.replaceAllMapped(
      _variable,
      (m) => Platform.environment[m.group(1) ?? m.group(2)!] ?? '',
    );
  }

  static final _variable = RegExp(r'\$\{(\w+)\}|\$(\w+)');

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
  /// [data] accepts any value `jsonEncode` understands. Reading one back is
  /// `format.json.read`; the write stays here because staging through a `.part`
  /// file is this domain's job, not the format's.
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

  /// Runs [action] with the lock file [path] held, and returns what it gave.
  ///
  /// The moment a script is good enough to put on a schedule, two copies of it
  /// eventually run at once — a slow run overlapping the next tick, or a human
  /// running it by hand while cron does. Atomic writes make the *file* safe;
  /// they do not stop the *result* from being whichever process finished last.
  ///
  /// ```dart
  /// await io.lock('.crawl.lock', () async {
  ///   // exactly one process in here
  ///   await net.crawl<Row>(seed).save('out.csv');
  /// });
  /// ```
  ///
  /// A second process throws [LockedError] straight away, or waits up to
  /// [wait] for its turn when one is given. The lock is released on a normal
  /// return, on a throw, **and on Ctrl-C** — a lock file that outlives an
  /// interrupt is worse than no lock at all, because the next run refuses to
  /// start.
  ///
  /// The file holds the pid and a timestamp, so a stale lock is diagnosable.
  /// A lock whose recorded process is gone is taken rather than obeyed; there
  /// is deliberately no age cut-off, because "older than an hour is stale"
  /// breaks the one run that legitimately took ninety minutes.
  Future<R> lock<R>(
    String path,
    FutureOr<R> Function() action, {
    Duration? wait,
  }) => Lock.hold(path, action, wait: wait);

  /// Whether the lock file at [path] is held by a live process.
  ///
  /// For a status line, not for deciding whether to take it — between the
  /// check and the take, another process can win. [lock] is the answer that
  /// cannot race.
  bool locked(String path) => Lock.held(path);

  /// Lists files under [dir], optionally filtered by [pattern].
  Sequence<File> find(String dir, {Pattern? pattern, bool recursive = true}) =>
      Sequence(Fs.find(dir, pattern: pattern, recursive: recursive));

  /// Calls [onchange] when a file at or under [path] changes.
  ///
  /// Returns the function that stops watching — hold onto it, because a live
  /// watcher keeps the process alive:
  ///
  /// ```dart
  /// final stop = io.watch(
  ///   'lib',
  ///   (changed) => log.info('changed: $changed'),
  ///   pattern: RegExp(r'\.dart$'),
  /// );
  /// // ... later
  /// await stop();
  /// ```
  ///
  /// [settle] coalesces a burst of events for one path into a single call,
  /// which is the part everyone hand-rolls wrong: an editor writes a file two
  /// or three times per save, so the naive version fires three builds. Pass
  /// `Duration.zero` for every raw event.
  ///
  /// Only files are reported, filtered by [pattern] when one is given. Set
  /// [recursive] to `false` to watch just the one directory. A directory
  /// created later is picked up either way — Linux watches one directory at a
  /// time, so a recursive watch there is a subscription per directory, and
  /// hiding that asymmetry is most of why this member exists.
  ///
  /// Called `observe` through 4.0.0, because `system.on.signals()` meant *watch
  /// for Ctrl-C* and two `watch`es meaning two unrelated things is exactly
  /// what Rule 5 is for. NAMESPACE.md recorded the compromise in as many
  /// words — *`observe` is free, honest, and slightly less good than
  /// `watch`*. 5.0.0 moved signal watching to `system.on.signals()`, where it
  /// belongs by Rule 3, and took the better name back.
  Future<void> Function() watch(
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

  /// Deletes every file under [dir] matching [pattern], and returns how many.
  ///
  /// The sweep, where [remove] is the single entity. Both were called `delete`
  /// and `remove` through 4.0.0 — synonyms, so neither name said which was
  /// which, and `io.delete(path)` read like it would remove that one file and
  /// instead swept a directory.
  ///
  /// ```dart
  /// io.remove('out/report.pdf');                      // one entity
  /// io.sweep('out', pattern: RegExp(r'\.part$'));     // everything matching
  /// ```
  int sweep(String dir, {Pattern? pattern, bool recursive = false}) =>
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

  /// Creates the parent directory of [path] if it is missing.
  Future<void> parent(String path) => Fs.parentAsync(path);

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
  Future<Sequence<File>> find(
    String dir, {
    Pattern? pattern,
    bool recursive = true,
  }) async =>
      Sequence(await Fs.findAsync(dir, pattern: pattern, recursive: recursive));

  /// Deletes every file under [dir] matching [pattern], and returns how many.
  ///
  /// The sweep, where [IoAsyncAccessor.remove] is the single entity.
  Future<int> sweep(String dir, {Pattern? pattern, bool recursive = false}) =>
      Fs.deleteAsync(dir, pattern: pattern, recursive: recursive);

  /// Returns the hex digest of [path] using [algorithm].
  Future<String> hash(String path, [Algo algorithm = Algo.sha256]) =>
      Fs.hashAsync(path, algorithm);

  /// Returns filesystem metadata for [path].
  Future<FileStat> stat(String path) => FileStat.stat(path);
}

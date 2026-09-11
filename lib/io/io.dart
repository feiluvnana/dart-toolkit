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
///   [DirAccessor.make], [DirAccessor.iterable], [DirAccessor.walk],
///   [DirAccessor.glob]. Creating a directory is not what `io` is mainly for,
///   and Rule 3 says a vocabulary with its own nouns gets its own name.
///
/// Plus `io.csv` for the two CSV operations that are about a file larger than
/// memory, and `io.async` for the whole thing again without blocking.
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

import 'csv.dart';
import 'dir.dart';
import 'entry.dart';
import 'path.dart';
import '../src/entries.dart';
import '../src/fs.dart';
import '../src/lock.dart';
import '../src/watch.dart';
import '../collection/dictionary.dart';
import '../collection/sequence.dart';

export 'collections.dart';
export 'csv.dart';
export 'dir.dart';
export 'entry.dart';
export 'path.dart';
export '../src/fs.dart' show Algo;
export '../src/lock.dart' show LockedError;

// ============================================================================
// IO DOMAIN (io.*) - Files, Paths, Directories, CSV & Collections
// ============================================================================

/// The `io` domain: files, paths (`io.path`), directories (`io.dir`), CSV and
/// the collections on disk.
const IoAccessor io = IoAccessor();

/// Entry point for the filesystem.
///
/// Paths are plain strings; given a [FileSystemEntry], pass its
/// [FileSystemEntry.path].
///
/// Everything here blocks. Every disk operation also lives on [async] as a
/// future, which is what a crawl or any other concurrent script should use.
///
/// ```dart
/// io.write(io.path.join('out', 'report.txt'), 'done');   // blocking
/// await io.async.write('out/report.txt', 'done');        // non-blocking
/// ```
class IoAccessor {
  /// Creates the accessor. Prefer the shared [io] instance.
  const IoAccessor();

  /// Paths, as strings: joining, splitting, naming. Touches no disk.
  PathAccessor get path => const PathAccessor();

  /// Directories: making them, listing them, walking them.
  DirAccessor get dir => const DirAccessor();

  /// CSV files too large to hold: streaming reads and streaming writes.
  ///
  /// Parsing and formatting CSV *text* is `format.csv`, beside the other five
  /// formats — it is a codec, and 5.2.0 moved it where the codecs live.
  CsvFileAccessor get csv => const CsvFileAccessor();

  /// The non-blocking mirror of this domain. See [IoAsyncAccessor].
  IoAsyncAccessor get async => const IoAsyncAccessor();

  /// The JSON object at [path] as a [Dictionary], or an empty one when the
  /// file is not there.
  ///
  /// The state a script keeps between runs, with [Slot]s for keys:
  ///
  /// ```dart
  /// // setup: const cursor = Slot<int>('cursor');
  /// final db = io.dictionary('out/cache.json');
  /// db.write(cursor, (db.read(cursor) ?? 0) + 1);
  /// db.dump('out/cache.json');
  /// ```
  ///
  /// The path is named twice rather than held, which is the trade for a
  /// collection that does not secretly own a file — the same one
  /// `format.json.read` already makes. `Store` held it, and held a
  /// process-wide mutable singleton with it.
  ///
  /// An absent file is an empty dictionary, because a first run has nothing to
  /// read. A file that is there and is not a JSON object throws
  /// [FormatException], because that is a broken file rather than a missing
  /// one and silence is how a half-written snapshot becomes a silent data
  /// loss.
  Dictionary<String, Object?> dictionary(String path) {
    final file = File(path);
    if (!file.existsSync()) return Dictionary<String, Object?>();
    return _dictionary(path, file.readAsStringSync());
  }

  // --- Existence: one question per member ---

  /// Whether anything at all is at [path] — file, directory or link.
  ///
  /// The question that had no answer through 5.1.0. [has] is not it: that one
  /// means *a file exists and holds at least one byte*, which is three
  /// questions fused into one, and a script writing
  /// `if (!io.has(dir)) io.dir.make(dir)` was correct by accident.
  ///
  /// A symlink counts as existing even when it dangles, because something is
  /// there — [islink] is true and [isfile] is false, which is the whole point
  /// of splitting them.
  bool exists(String path) => Entries.kind(path) != null;

  /// Whether [path] is a regular file.
  ///
  /// The three kind questions are exclusive: a symlink is [islink], never
  /// [isfile], whatever it points at.
  bool isfile(String path) => Entries.kind(path) == FileSystemEntryKind.file;

  /// Whether [path] is a directory. See [isfile] on symlinks.
  bool isdir(String path) =>
      Entries.kind(path) == FileSystemEntryKind.directory;

  /// Whether [path] is a symbolic link, whatever it resolves to.
  bool islink(String path) => Entries.kind(path) == FileSystemEntryKind.link;

  /// How many bytes are at [path], or `null` when there is nothing there.
  ///
  /// A directory is `0`; what is *in* it is `io.dir.list(path)`.
  int? size(String path) => stat(path)?.size;

  /// Whether [path] exists and has nothing in it.
  ///
  /// Zero bytes for a file, and no entries for a directory. `false` when
  /// there is nothing at [path] at all — *absent* and *empty* are two
  /// different answers, which is exactly what [has] could not tell you.
  bool empty(String path) => stat(path)?.empty ?? false;

  /// Whether [path] exists and holds at least one byte.
  ///
  /// The composite, kept because it is genuinely the question a resumable
  /// script asks: *is there a finished file here, or do I have to make one?*
  /// A zero-byte file reads as absent, since an interrupted write leaves one.
  ///
  /// The three ingredients are [exists], [isfile] and [empty] now, so a
  /// caller who wanted one of them no longer has to take all three.
  ///
  /// Set [match] to also accept a loosely-named sibling — see [Fs.similar],
  /// which is fuzzy enough to produce false positives.
  bool has(String path, {bool match = false}) => Fs.has(path, match: match);

  /// Whether a loosely similarly-named file sits beside [path].
  ///
  /// See [Fs.similar] for the matching rules and their caveats.
  bool similar(String path) => Fs.similar(path);

  /// The entry at [path], or `null` when there is nothing there.
  ///
  /// One stat, four answers — kind, size, mtime and the name parts — so a
  /// loop that needs more than one of them pays once:
  ///
  /// ```dart
  /// final entry = io.stat('out/report.csv');
  /// if (entry != null && entry.size > 1024) log.info(entry.name);
  /// ```
  ///
  /// It returned a `dart:io` [FileStat] through 5.1.0, which could answer
  /// `size` and `type` and nothing else, and was the only way to ask either.
  FileSystemEntry? stat(String path) => Fs.stat(path);

  // --- Reading ---

  /// Reads [path] as a string.
  String read(String path, {Encoding encoding = utf8}) =>
      File(path).readAsStringSync(encoding: encoding);

  /// Reads [path] as raw bytes.
  List<int> bytes(String path) => File(path).readAsBytesSync();

  /// Reads [path] as decoded lines.
  ///
  /// ```dart
  /// io.lines('access.log')
  ///     .transform(.where((l) => l.contains(' 500 ')))
  ///     .collect(.count());
  /// ```
  ///
  /// This returned a `Stream<String>` through 5.1.0 — from the accessor whose
  /// whole promise is that it blocks. `io.async.lines` is the [Stream], which
  /// is the one shape difference the mirror allows and the reason it is
  /// allowed: each side is honest about which accessor it is on.
  Sequence<String> lines(String path, {Encoding encoding = utf8}) =>
      Sequence(Fs.linesSync(path, encoding: encoding));

  // --- Writing (always atomic, via a `.part` staging file) ---

  /// Writes text [content] to [path] atomically. See [Fs.writeSync].
  FileSystemEntry write(
    String path,
    String content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) => Fs.entryFor(
    Fs.writeSync(path, content, part: part, encoding: encoding).path,
  );

  /// Writes raw [content] bytes to [path] atomically. See [Fs.saveSync].
  FileSystemEntry save(
    String path,
    List<int> content, {
    String part = '.part',
  }) => Fs.entryFor(Fs.saveSync(path, content, part: part).path);

  /// Encodes [data] as JSON and writes it to [path] atomically.
  ///
  /// [data] accepts any value `jsonEncode` understands. Reading one back is
  /// `format.json.read`; the write stays here because staging through a `.part`
  /// file is this domain's job, not the format's.
  FileSystemEntry dump(
    String path,
    Object? data, {
    bool pretty = true,
    String part = '.part',
  }) => Fs.entryFor(Fs.dumpSync(path, data, pretty: pretty, part: part).path);

  /// Appends [content] to the end of [path], creating it if it is missing.
  ///
  /// ```dart
  /// io.append('out/run.log', '${util.time.stamp()} finished\n');
  /// ```
  ///
  /// **The one write here that is not atomic**, and it cannot be: appending
  /// adds to what is already on disk, so there is no staged copy to swap into
  /// place. An interrupted append can leave a partial line. When a file has
  /// to appear whole or not at all, build it and [write] it.
  FileSystemEntry append(
    String path,
    String content, {
    Encoding encoding = utf8,
  }) => Fs.appendSync(path, content, encoding: encoding);

  /// Creates [path] empty, or updates its modification time if it is there.
  ///
  /// The marker file a script leaves to say a step is done, and the way to
  /// make an empty file without `io.write(path, '')` — which reads like it
  /// meant to write something.
  FileSystemEntry touch(String path) => Fs.touchSync(path);

  // --- Moving and removing ---

  /// Copies [source] to [destination], creating parent directories.
  ///
  /// Recursively copies directories if [source] is a directory.
  FileSystemEntry copy(String source, String destination) =>
      Fs.copySync(source, destination);

  /// Moves [source] to [destination], creating parent directories.
  ///
  /// Works across filesystems by falling back to copy-and-delete.
  FileSystemEntry move(String source, String destination) =>
      Fs.moveSync(source, destination);

  /// Removes a file, link or directory at [path].
  ///
  /// Returns `true` if the entity was removed, or `false` if it did not
  /// exist. The single entity, where `io.dir.sweep` is the sweep.
  bool remove(String path) => Fs.removeSync(path);

  // --- Metadata, locking and watching ---

  /// Returns the hex digest of [path] using [algorithm].
  String hash(String path, [Algo algorithm = Algo.sha256]) =>
      Fs.hash(path, algorithm);

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
  ///
  /// Holding a lock is inherently asynchronous, so there is no `io.async`
  /// twin: this *is* the one form it has.
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
  /// Watching is inherently asynchronous, so like [lock] it has no `io.async`
  /// twin.
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
}

/// The non-blocking mirror of [IoAccessor], reachable as `io.async`.
///
/// Every operation that touches the disk appears here under the same name and
/// arguments, returning a future instead of blocking — including the whole of
/// `io.dir`, as [IoAsyncAccessor.dir]. A crawl runs many requests on one
/// isolate, so a blocking read stalls every other task in flight; reach for
/// this inside handlers and pool workers.
///
/// ```dart
/// await net.crawl<String>(seed).collect((res) async {
///   await io.async.write('pages/${res.depth}.html', res.body);
/// });
/// ```
///
/// **What is deliberately not here**, and why the mirror is still complete:
///
/// - `io.path` — pure string arithmetic, with nothing to wait for.
/// - [IoAccessor.lock], [IoAccessor.locked] and [IoAccessor.watch] — already
///   asynchronous on `io`, because holding a lock and watching for a change
///   have no blocking form to mirror.
/// - `io.csv` — every member of it is already a `Stream` or a `Future`.
///
/// [lines] is the one member whose *shape* differs: a [Stream] here, a
/// `Sequence` on `io`. That is the mirror working rather than failing —
/// blocking means the lines are already read. `test/regression_test.dart`
/// pins this exception set, so a member added to one side and forgotten on
/// the other fails the build.
class IoAsyncAccessor {
  /// Creates the accessor. Prefer the shared `io.async` instance.
  const IoAsyncAccessor();

  /// Directories, without blocking. See [DirAsyncAccessor].
  DirAsyncAccessor get dir => const DirAsyncAccessor();

  /// The JSON object at [path] as a [Dictionary]. See [IoAccessor.dictionary].
  Future<Dictionary<String, Object?>> dictionary(String path) async {
    final file = File(path);
    if (!await file.exists()) return Dictionary<String, Object?>();
    return _dictionary(path, await file.readAsString());
  }

  // --- Existence ---

  /// Whether anything at all is at [path] — file, directory or link.
  Future<bool> exists(String path) async =>
      await Entries.kindAsync(path) != null;

  /// Whether [path] is a regular file.
  Future<bool> isfile(String path) async =>
      await Entries.kindAsync(path) == FileSystemEntryKind.file;

  /// Whether [path] is a directory.
  Future<bool> isdir(String path) async =>
      await Entries.kindAsync(path) == FileSystemEntryKind.directory;

  /// Whether [path] is a symbolic link.
  Future<bool> islink(String path) async =>
      await Entries.kindAsync(path) == FileSystemEntryKind.link;

  /// How many bytes are at [path], or `null` when there is nothing there.
  Future<int?> size(String path) async => (await stat(path))?.size;

  /// Whether [path] exists and has nothing in it.
  Future<bool> empty(String path) async => (await stat(path))?.empty ?? false;

  /// Whether [path] exists and holds at least one byte.
  Future<bool> has(String path, {bool match = false}) =>
      Fs.hasAsync(path, match: match);

  /// Whether a loosely similarly-named file sits beside [path]. See [Fs.similar].
  Future<bool> similar(String path) => Fs.similarAsync(path);

  /// The entry at [path], or `null` when there is nothing there.
  Future<FileSystemEntry?> stat(String path) => Fs.statAsync(path);

  // --- Reading ---

  /// Reads [path] as a string.
  Future<String> read(String path, {Encoding encoding = utf8}) =>
      File(path).readAsString(encoding: encoding);

  /// Reads [path] as raw bytes.
  Future<List<int>> bytes(String path) => File(path).readAsBytes();

  /// Streams [path] as decoded lines, without loading the whole file.
  ///
  /// The shape `io.lines` used to have on both accessors. It belongs on this
  /// one: a stream is what *not blocking* looks like.
  Stream<String> lines(String path, {Encoding encoding = utf8}) =>
      Fs.lines(path, encoding: encoding);

  // --- Writing (always atomic, via a `.part` staging file) ---

  /// Writes text [content] to [path] atomically. See [Fs.write].
  Future<FileSystemEntry> write(
    String path,
    String content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) async => Fs.entryFor(
    (await Fs.write(path, content, part: part, encoding: encoding)).path,
  );

  /// Writes raw [content] bytes to [path] atomically. See [Fs.save].
  Future<FileSystemEntry> save(
    String path,
    List<int> content, {
    String part = '.part',
  }) async => Fs.entryFor((await Fs.save(path, content, part: part)).path);

  /// Encodes [data] as JSON and writes it to [path] atomically.
  Future<FileSystemEntry> dump(
    String path,
    Object? data, {
    bool pretty = true,
    String part = '.part',
  }) async =>
      Fs.entryFor((await Fs.dump(path, data, pretty: pretty, part: part)).path);

  /// Appends [content] to the end of [path]. See [IoAccessor.append].
  Future<FileSystemEntry> append(
    String path,
    String content, {
    Encoding encoding = utf8,
  }) => Fs.append(path, content, encoding: encoding);

  /// Creates [path] empty, or updates its modification time.
  Future<FileSystemEntry> touch(String path) => Fs.touch(path);

  // --- Moving and removing ---

  /// Copies [source] to [destination], creating parent directories.
  Future<FileSystemEntry> copy(String source, String destination) =>
      Fs.copyAsync(source, destination);

  /// Moves [source] to [destination], creating parent directories.
  Future<FileSystemEntry> move(String source, String destination) =>
      Fs.moveAsync(source, destination);

  /// Removes a file, link or directory at [path]; `false` when it did not exist.
  Future<bool> remove(String path) => Fs.removeAsync(path);

  // --- Metadata ---

  /// Returns the hex digest of [path] using [algorithm].
  Future<String> hash(String path, [Algo algorithm = Algo.sha256]) =>
      Fs.hashAsync(path, algorithm);
}

/// Decodes a JSON object read from [path] into a [Dictionary].
Dictionary<String, Object?> _dictionary(String path, String text) {
  final decoded = jsonDecode(text);
  if (decoded is! Map) {
    throw FormatException(
      '$path holds a ${decoded.runtimeType}, not a JSON object',
    );
  }
  return Dictionary({
    for (final entry in decoded.entries) entry.key.toString(): entry.value,
  });
}

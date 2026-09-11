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

import 'csv.dart';
import 'dir.dart';
import 'entry.dart';
import 'path.dart';
import '../src/entries.dart';
import '../src/fs.dart';
import '../src/lock.dart';
import '../src/watch.dart';
import '../collection/dictionary.dart';
import '../collection/flow.dart';
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
  /// there, and `io.stat(path)?.islink` is how you tell it from a file.
  ///
  /// The kind questions were three members here — `isfile`, `isdir`,
  /// `islink` — through 6.1.0, on both accessors. Each was a second reading
  /// of the stat [stat] already returns, and the entry it hands back spells
  /// all three: `io.stat(p)?.isfile`.
  bool exists(String path) => Entries.kind(path) != null;

  /// Whether [path] exists and holds at least one byte.
  ///
  /// The composite, kept because it is genuinely the question a resumable
  /// script asks: *is there a finished file here, or do I have to make one?*
  /// A zero-byte file reads as absent, since an interrupted write leaves one.
  ///
  /// The ingredients are [exists] and the entry from [stat] now, so a caller
  /// who wanted one of them no longer has to take all three.
  ///
  /// A loosely-named sibling counts for [similar], not for this. It was a
  /// `match:` flag here through 5.5.0, and `io.has(p, match: true)` was
  /// provably `io.similar(p)` for every input — [similar] opens by calling
  /// [has] — so it was two spellings of one answer, one of them a boolean
  /// that turned this member into a different one.
  bool has(String path) => Fs.has(path);

  /// Whether [path] holds bytes, or a loosely similarly-named file beside it
  /// does.
  ///
  /// [has], widened. See [Fs.similar] for the matching rules and their
  /// caveats — it is fuzzy enough to produce false positives, which is why
  /// this is the member you have to ask for by name.
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

  /// Reads [path] as raw bytes, and writes bytes back.
  ///
  /// Callable, and a namespace, exactly as [lines] and [append] are:
  /// `bytes(path)` reads and `bytes.write(path, data)` writes.
  ///
  /// ```dart
  /// final data = io.bytes('cover.jpg');
  /// io.bytes.write('out/cover.jpg', data);
  /// ```
  ///
  /// The write was `io.save` through 5.5.0, which is the same English word as
  /// [write] and said nothing about which of the two took bytes. The rule for
  /// the whole domain now: **the name says the shape, and `.write` is how it
  /// goes back.** A reader who learns [lines] has learned this and [chunks]
  /// for free.
  BytesAccessor get bytes => const BytesAccessor();

  /// Reads [path] as decoded lines, and writes a collection back as them.
  ///
  /// Callable, and a namespace: `lines(path)` reads and
  /// `lines.write(path, seq)` writes one element per line.
  ///
  /// ```dart
  /// io.lines('access.log')
  ///     .transform(.where((l) => l.contains(' 500 ')))
  ///     .collect(.count());
  ///
  /// io.lines.write('out/hosts.txt', hosts.keys);
  /// ```
  ///
  /// Reading returned a `Stream<String>` through 5.1.0 — from the accessor
  /// whose whole promise is that it blocks. `io.async.lines` is the [Flow],
  /// which is the shape difference the mirror specifies: each side is honest
  /// about which accessor it is on.
  LinesAccessor get lines => const LinesAccessor();

  /// Reads [path] in byte chunks, without holding the whole file.
  ///
  /// The streaming half of [bytes], which reads all of it at once. A lazy
  /// view, so
  /// nothing is read until the sequence is walked and a reader that stops
  /// early stops reading:
  ///
  /// ```dart
  /// io.chunks('big.bin').collect(.count());          // how many chunks
  /// io.chunks('big.bin', size: 4096).collect(.first());
  /// ```
  ///
  /// [size] is the most bytes a chunk carries; the last one is short.
  /// `chunks.write(path, seq)` is the other direction, which writes the
  /// chunks through without ever holding the file.
  ChunksAccessor get chunks => const ChunksAccessor();

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

  /// Encodes [data] as JSON and writes it to [path] atomically.
  ///
  /// [data] accepts any value `jsonEncode` understands. Reading one back is
  /// `format.json.read`, and the general form of this is
  /// `format.json.write(path, data)` — this is that under the shorter name a
  /// script reaches for, for the one format everybody has.
  ///
  /// Its three relatives write JSON *of a collection*, with the receiver
  /// first: `seq.dump(path)`, `dict.dump(path)`, `await flow.dump(path)`.
  FileSystemEntry dump(
    String path,
    Object? data, {
    bool pretty = true,
    String part = '.part',
  }) => Fs.entryFor(Fs.dumpSync(path, data, pretty: pretty, part: part).path);

  /// Appends to the end of [path], creating it if it is missing.
  ///
  /// Callable, and a namespace: `append(path, text)` opens, writes and closes
  /// in one call, and `append.open(path)` hands back a handle that stays open
  /// for a loop that writes many times.
  ///
  /// ```dart
  /// io.append('out/run.log', '${util.time.stamp()} finished\n');
  /// ```
  ///
  /// **The one write here that is not atomic**, and it cannot be: appending
  /// adds to what is already on disk, so there is no staged copy to swap into
  /// place. An interrupted append can leave a partial line. When a file has
  /// to appear whole or not at all, build it and [write] it — or hand the
  /// elements to `io.lines.write`, which stages.
  AppendAccessor get append => const AppendAccessor();

  /// Creates [path] empty, or updates its modification time if it is there.
  ///
  /// The marker file a script leaves to say a step is done, and the way to
  /// make an empty file without `io.write(path, '')` — which reads like it
  /// meant to write something.
  FileSystemEntry touch(String path) => Fs.touchSync(path);

  /// Creates a new empty temporary file named after [prefix].
  ///
  /// The file beside `io.dir.temp`'s directory. It is made inside a fresh
  /// temporary directory of its own, so two callers with one prefix cannot
  /// collide, and removing `io.path.dirname(entry.path)` removes the lot.
  ///
  /// ```dart
  /// final scratch = io.temp('render_');
  /// io.write(scratch.path, 'working');
  /// io.remove(io.path.dirname(scratch.path));
  /// ```
  FileSystemEntry temp([String prefix = 'tmp_']) => Fs.tempfileSync(prefix);

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
  /// // setup: final seed = 'https://example.com'.url;
  /// await io.lock('.crawl.lock', () async {
  ///   // exactly one process in here
  ///   await net.crawl([Fetch(seed)]).flow.dump('out.json');
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
/// await net.crawl([Fetch(seed)]).flow.collect(.foreach((res) async {
///   await io.async.write('pages/${res.fetch.depth}.html', res.body);
/// }));
/// ```
///
/// **What is deliberately not here**, and why the mirror is still complete:
///
/// - `io.path` — pure string arithmetic, with nothing to wait for.
/// - [IoAccessor.lock], [IoAccessor.locked] and [IoAccessor.watch] — already
///   asynchronous on `io`, because holding a lock and watching for a change
///   have no blocking form to mirror.
/// - [DirAccessor.cwd] and [DirAccessor.home] — neither reads anything.
///
/// `io.csv` used to be a third entry on that list, because every member of it
/// was already a `Stream` or a `Future` from the accessor that promises to
/// block. It is a real mirror now; see the `io.csv` library doc.
///
/// Members whose *shape* differs follow one rule with no exceptions: a
/// [Sequence] on `io`, a [Flow] on `io.async`. That covers [lines] and
/// [chunks], `io.dir`'s [DirAccessor.list], [DirAccessor.walk] and
/// [DirAccessor.glob], and `io.csv`'s [CsvFileAccessor.rows],
/// [CsvFileAccessor.records] and [CsvFileAccessor.write]. That is the mirror
/// working rather than failing — blocking means the elements are already
/// read. `test/regression_test.dart` pins the set, so a member added to one
/// side and forgotten on the other fails the build.
///
/// **One property is not parity.** A [Flow] from here is consumed once; the
/// [Sequence] from `io` can be walked again, re-reading the disk. Where a
/// listing has to be read twice, `Flow.of` is the re-derivable form and
/// `collect(.seq())` is the held one.
class IoAsyncAccessor {
  /// Creates the accessor. Prefer the shared `io.async` instance.
  const IoAsyncAccessor();

  /// Directories, without blocking. See [DirAsyncAccessor].
  DirAsyncAccessor get dir => const DirAsyncAccessor();

  /// CSV files, streaming. See [CsvFileAsyncAccessor].
  CsvFileAsyncAccessor get csv => const CsvFileAsyncAccessor();

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

  /// Whether [path] exists and holds at least one byte.
  Future<bool> has(String path) => Fs.hasAsync(path);

  /// Whether a loosely similarly-named file sits beside [path]. See [Fs.similar].
  Future<bool> similar(String path) => Fs.similarAsync(path);

  /// The entry at [path], or `null` when there is nothing there.
  Future<FileSystemEntry?> stat(String path) => Fs.statAsync(path);

  // --- Reading ---

  /// Reads [path] as a string.
  Future<String> read(String path, {Encoding encoding = utf8}) =>
      File(path).readAsString(encoding: encoding);

  /// Reads [path] as raw bytes, and writes bytes back. See [IoAccessor.bytes].
  BytesAsyncAccessor get bytes => const BytesAsyncAccessor();

  /// Reads [path] as decoded lines, and writes a flow back as them.
  ///
  /// Callable, and a namespace, exactly as [IoAccessor.lines] is — the shape
  /// is what differs: a [Flow] where the blocking mirror hands back a
  /// [Sequence], on both the reading and the writing side.
  ///
  /// ```dart
  /// await io.async.lines('big.log')
  ///     .transform(.where((line) => line.contains('ERROR')))
  ///     .collect(.foreach(print));
  ///
  /// await io.async.lines.write(
  ///   'out/errors.log',
  ///   io.async.lines('big.log').transform(.where((l) => l.contains('ERROR'))),
  /// );
  /// ```
  LinesAsyncAccessor get lines => const LinesAsyncAccessor();

  /// Reads [path] in byte chunks as they arrive, and writes a flow of them
  /// back. See [IoAccessor.chunks].
  ChunksAsyncAccessor get chunks => const ChunksAsyncAccessor();

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

  /// Encodes [data] as JSON and writes it to [path] atomically.
  Future<FileSystemEntry> dump(
    String path,
    Object? data, {
    bool pretty = true,
    String part = '.part',
  }) async =>
      Fs.entryFor((await Fs.dump(path, data, pretty: pretty, part: part)).path);

  /// Appends to the end of [path]. See [IoAccessor.append].
  AppendAsyncAccessor get append => const AppendAsyncAccessor();

  /// Creates [path] empty, or updates its modification time.
  Future<FileSystemEntry> touch(String path) => Fs.touch(path);

  /// Creates a new empty temporary file named after [prefix].
  /// See [IoAccessor.temp].
  Future<FileSystemEntry> temp([String prefix = 'tmp_']) => Fs.tempfile(prefix);

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

// ============================================================================
// THE NAMESPACES
// ============================================================================

/// The namespace behind [IoAccessor.bytes].
class BytesAccessor {
  /// Creates the accessor. Prefer the shared `io.bytes` instance.
  const BytesAccessor();

  /// Reads [path] as raw bytes.
  List<int> call(String path) => File(path).readAsBytesSync();

  /// Writes [content] to [path] atomically. See [Fs.saveSync].
  FileSystemEntry write(
    String path,
    List<int> content, {
    String part = '.part',
  }) => Fs.entryFor(Fs.saveSync(path, content, part: part).path);
}

/// The namespace behind [IoAsyncAccessor.bytes].
class BytesAsyncAccessor {
  /// Creates the accessor. Prefer the shared `io.async.bytes` instance.
  const BytesAsyncAccessor();

  /// Reads [path] as raw bytes.
  Future<List<int>> call(String path) => File(path).readAsBytes();

  /// Writes [content] to [path] atomically. See [Fs.save].
  Future<FileSystemEntry> write(
    String path,
    List<int> content, {
    String part = '.part',
  }) async => Fs.entryFor((await Fs.save(path, content, part: part)).path);
}

/// The namespace behind [IoAccessor.chunks].
class ChunksAccessor {
  /// Creates the accessor. Prefer the shared `io.chunks` instance.
  const ChunksAccessor();

  /// Reads [path] in byte chunks of at most [size] — on the walk, not before.
  Sequence<List<int>> call(String path, {int size = 64 * 1024}) =>
      Sequence(Fs.chunksSync(path, size: size));

  /// Writes [chunks] to [path] atomically, one after another.
  ///
  /// The whole sequence is walked while the staging file is open, so nothing
  /// is held but the chunk being written — which is what makes copying a file
  /// larger than memory one line.
  FileSystemEntry write(
    String path,
    Sequence<List<int>> chunks, {
    String part = '.part',
  }) => Fs.entryFor(
    Fs.writeChunksSync(path, chunks.collect(.list()), part: part).path,
  );
}

/// The namespace behind [IoAsyncAccessor.chunks].
class ChunksAsyncAccessor {
  /// Creates the accessor. Prefer the shared `io.async.chunks` instance.
  const ChunksAsyncAccessor();

  /// Reads [path] in byte chunks of at most [size] as they arrive.
  Flow<List<int>> call(String path, {int size = 64 * 1024}) =>
      Flow.of(() => Fs.chunks(path, size: size));

  /// Writes [chunks] to [path] atomically as they arrive.
  ///
  /// ```dart
  /// await io.async.chunks.write('copy.bin', io.async.chunks('big.bin'));
  /// ```
  ///
  /// The file appears whole or not at all: bytes go to a staging file that is
  /// renamed into place once the flow ends, and discarded if it fails.
  Future<FileSystemEntry> write(
    String path,
    Flow<List<int>> chunks, {
    String part = '.part',
  }) async =>
      Fs.entryFor((await Fs.pourChunks(path, chunks.stream, part: part)).path);
}

/// The namespace behind [IoAccessor.lines].
class LinesAccessor {
  /// Creates the accessor. Prefer the shared `io.lines` instance.
  const LinesAccessor();

  /// Reads [path] as decoded lines — on the first walk, not before.
  Sequence<String> call(String path, {Encoding encoding = utf8}) =>
      Sequence(Fs.linesSync(path, encoding: encoding));

  /// Writes [lines] to [path] atomically, one element per line.
  ///
  /// The general form that a crawl's `save(path)` and `io.csv.pipe` were each
  /// a private version of through 5.4.0. [newline] ends every line,
  /// including the last.
  FileSystemEntry write(
    String path,
    Sequence<String> lines, {
    String newline = '\n',
    Encoding encoding = utf8,
    String part = '.part',
  }) => Fs.entryFor(
    Fs.writeLinesSync(
      path,
      lines.collect(.list()),
      newline: newline,
      encoding: encoding,
      part: part,
    ).path,
  );
}

/// The namespace behind [IoAsyncAccessor.lines].
class LinesAsyncAccessor {
  /// Creates the accessor. Prefer the shared `io.async.lines` instance.
  const LinesAsyncAccessor();

  /// Reads [path] as decoded lines, without loading the whole file.
  Flow<String> call(String path, {Encoding encoding = utf8}) =>
      Flow.of(() => Fs.lines(path, encoding: encoding));

  /// Writes [lines] to [path] atomically as they arrive, one per line.
  ///
  /// Never holds more than the line it is writing, so a crawl, a large log or
  /// a piped stdin becomes a file in one call:
  ///
  /// ```dart
  /// await io.async.lines.write(
  ///   'titles.txt',
  ///   net.crawl([Fetch(seed)]).flow.transform(.map((res) => res.url.toString())),
  /// );
  /// ```
  ///
  /// The file appears whole or not at all: lines go to a staging file that is
  /// renamed into place once the flow ends, and discarded if it fails.
  Future<FileSystemEntry> write(
    String path,
    Flow<String> lines, {
    String newline = '\n',
    Encoding encoding = utf8,
    String part = '.part',
  }) async => Fs.entryFor(
    (await Fs.pourLines(
      path,
      lines.stream,
      newline: newline,
      encoding: encoding,
      part: part,
    )).path,
  );
}

/// The namespace behind [IoAccessor.append].
class AppendAccessor {
  /// Creates the accessor. Prefer the shared `io.append` instance.
  const AppendAccessor();

  /// Appends [content] to the end of [path], creating it if it is missing.
  FileSystemEntry call(
    String path,
    String content, {
    Encoding encoding = utf8,
  }) => Fs.appendSync(path, content, encoding: encoding);

  /// A handle on [path] that stays open until it is closed.
  ///
  /// `io.append(path, line)` opens, writes and closes every time it is
  /// called, which is right for the log line a script writes twice and wrong
  /// for the loop that writes ten thousand:
  ///
  /// ```dart
  /// final log = io.append.open('out/run.log');
  /// try {
  ///   for (final row in rows.collect(.list())) {
  ///     log.write('${row.host}\n');
  ///   }
  /// } finally {
  ///   await log.close();
  /// }
  /// ```
  ///
  /// The caller closes it — this is the one thing in `io` that is a handle
  /// rather than a snapshot, and [Appender.close] is what flushes.
  Appender open(String path, {Encoding encoding = utf8}) {
    Fs.mkparentSync(path);
    return Appender._(path, encoding);
  }
}

/// The namespace behind [IoAsyncAccessor.append].
class AppendAsyncAccessor {
  /// Creates the accessor. Prefer the shared `io.async.append` instance.
  const AppendAsyncAccessor();

  /// Appends [content] to the end of [path]. See [AppendAccessor.call].
  Future<FileSystemEntry> call(
    String path,
    String content, {
    Encoding encoding = utf8,
  }) => Fs.append(path, content, encoding: encoding);

  /// A handle on [path] that stays open. See [AppendAccessor.open].
  Future<Appender> open(String path, {Encoding encoding = utf8}) async {
    await Fs.mkparent(path);
    return Appender._(path, encoding);
  }
}

/// An open file, held for a run of appends.
///
/// **The one type in `io` with a lifecycle.** Every other member of the
/// domain is complete when it returns, and every other value here — a
/// [FileSystemEntry], a [Dictionary] — is a snapshot that owns nothing and
/// can be handed around freely. This holds a descriptor from
/// `io.append.open(path)` until [close], so closing it is the caller's job
/// and a `try`/`finally` is the shape:
///
/// ```dart
/// // setup: const lines = ['first', 'second'];
/// final log = await io.append.open('out/run.log');
/// try {
///   for (final line in lines) log.write('$line\n');
/// } finally {
///   await log.close();
/// }
/// ```
///
/// It exists because the alternative for a loop is `io.append(path, text)` per
/// line, which opens and closes the file every time. Like every append, it is
/// **not atomic** — see [IoAccessor.append].
final class Appender {
  Appender._(this.path, Encoding encoding)
    : _sink = File(path).openWrite(mode: FileMode.append, encoding: encoding);

  /// The file being appended to.
  final String path;

  final IOSink _sink;
  var _closed = false;

  /// Appends [content] exactly as given.
  void write(String content) {
    if (_closed) throw StateError('This appender is closed.');
    _sink.write(content);
  }

  /// Flushes what is buffered and releases the descriptor.
  ///
  /// Idempotent, so a `finally` that runs after an early `close` is not an
  /// error. Nothing written is guaranteed to be on disk until this returns.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sink.flush();
    await _sink.close();
  }

  @override
  String toString() => 'Appender($path${_closed ? ', closed' : ''})';
}

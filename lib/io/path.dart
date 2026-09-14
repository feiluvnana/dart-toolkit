/// # Paths (`Path`)
///
/// A path is a **type**, and every filesystem operation is one of its members.
///
/// ```dart
/// final out = Path.cwd / 'output' / 'reports';
/// await out.makeDir();
/// await (out / 'q3.json').writeJson(rows);        // atomic
/// final text = await (out / 'notes.md').readText();
/// ```
///
/// This replaces the seventy-six top-level path and file functions the
/// library carried through 8.1.0 — `joinPath`, `readText`, `writeJson`,
/// `listDir`, `fileExists`, `withLock`, and their twenty-eight `Sync` twins.
/// Those names could not be discovered: there was nothing to type before the
/// dot. `path.` narrows an editor to the thirty operations that make sense on
/// a path, each with its own doc and signature.
///
/// **It costs nothing.** `Path` is an extension type over `String`, so it is
/// erased at run time — a `Path` *is* a `String` in the VM, with no wrapper
/// allocated and no conversion to pay for.
///
/// **It is still a `String`.** `implements String` means every `String` member
/// comes along (`startsWith`, `split`, `==`, interpolation) and a `Path` flows
/// unchanged into `File(...)`, `Directory(...)` and any third-party signature
/// that takes a path:
///
/// ```dart
/// final settings = Path.home / '.tool' / 'config.yaml';
/// if (settings.endsWith('.yaml')) print('$settings');  // String members, free
/// final handle = File(settings);                       // dart:io, no conversion
/// ```
///
/// **Every write is atomic**, as it has been since 1.0: content is staged
/// through a `.part` file and renamed into place, so a file appears whole or
/// not at all even if the script is killed mid-write.
///
/// ## Blocking calls live under `.sync`
///
/// ```dart
/// await settings.readText();   // Future<String>
/// settings.sync.readText();    // String
/// ```
///
/// One member to find instead of a `Sync` suffix to remember on twenty-eight
/// names. [SyncPath] carries the same names with the same meanings; only the
/// return type differs.
///
/// ## Reading a document
///
/// Any codec reads and writes through the same two members, and the leading
/// dot is the whole spelling because the parameter type supplies the prefix:
///
/// ```dart
/// final settings = await Path('config.yaml').read(.yaml);   // Json
/// await Path('out/products.csv').write(rows, as: .csv);     // atomic
/// ```
/// {@category Files}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'entry.dart';
import '../src/csvtext.dart';
import '../src/entries.dart';
import '../src/format.dart';
import '../src/fs.dart';
import '../src/json.dart';
import '../src/lock.dart';
import '../src/watch.dart';

// ============================================================================
// PATHS (Path)
// ============================================================================

/// A filesystem path, and everything you can do to what is at it.
///
/// See the library doc comment for why this is a type rather than seventy-six
/// functions. Members are grouped so that `path.` reads like a table of
/// contents: **place** ([operator /], [parent], [name], [stem], [ext]),
/// **ask** ([exists], [isFile], [isDir], [size]), **read** ([readText],
/// [readJson], [read]), **write** (`Path.writeText`, `Path.writeJson`, [write]),
/// **move** ([copyTo], [moveTo], [delete], [makeDir]), **walk** ([list],
/// [walk], [glob], [watch]) and **hold** ([lock], [hash]).
extension type const Path(String raw) implements String {
  // -------------------------------------------------------------- statics --

  /// The current working directory.
  static Path get cwd => Path(Fs.cwd);

  /// The current user's home directory, never null.
  static Path get home => Path(Fs.home);

  /// Lifts [path] into a [Path].
  ///
  /// `Path('a/b')` is the same call; this exists so that a leading dot
  /// resolves where the parameter type is known — `f(.of(name))`.
  static Path of(String path) => Path(path);

  /// Creates and returns a new temporary directory.
  static Future<Path> tempDir([String prefix = 'tmp_']) async =>
      Path((await Fs.temp(prefix)).path);

  /// Creates and returns a new empty temporary file.
  static Future<Path> tempFile([String prefix = 'tmp_']) async =>
      Path((await Fs.tempfile(prefix)).path);

  // ---------------------------------------------------------------- place --

  /// This path with [child] appended, using the platform separator.
  ///
  /// ```dart
  /// final report = Path.cwd / 'output' / 'reports' / 'q3.json';
  /// ```
  ///
  /// An absolute [child] replaces the left side, which is what `p.join` does
  /// and what a reader expects of `/`.
  ///
  /// A leading dot cannot be an operator's left operand: write
  /// `Path.cwd / 'sub'`, not `.cwd / 'sub'`.
  Path operator /(String child) => Path(p.join(raw, child));

  /// The directory holding this path.
  Path get parent => Path(p.dirname(raw));

  /// The final segment, extension included.
  String get name => p.basename(raw);

  /// The final segment without its extension.
  String get stem => p.basenameWithoutExtension(raw);

  /// The extension, including the leading dot, or `''`.
  String get ext => p.extension(raw);

  /// The individual segments.
  List<String> get parts => p.split(raw);

  /// This path resolved against the working directory.
  Path get absolute => Path(p.absolute(raw));

  /// This path with `.` and `..` resolved away.
  Path get normalized => Path(p.normalize(raw));

  /// This path relative to [from], or to the working directory.
  Path relativeTo([String? from]) => Path(p.relative(raw, from: from));

  /// This path with a leading `~` and any `$VAR` expanded.
  Path get expanded {
    var out = raw;
    if (out == '~') {
      out = Fs.home;
    } else if (out.startsWith('~/') || out.startsWith(r'~\')) {
      out = p.join(Fs.home, out.substring(2));
    }
    return Path(
      out.replaceAllMapped(
        RegExp(r'\$\{(\w+)\}|\$(\w+)'),
        (m) => Platform.environment[m.group(1) ?? m.group(2)!] ?? '',
      ),
    );
  }

  /// This path with the characters no filesystem accepts taken out of [name].
  ///
  /// Only the final segment is touched — the separators above it are the path,
  /// not part of a filename. With [full] the illegal characters become
  /// full-width look-alikes instead of [replace], which keeps a title
  /// readable.
  Path sanitized({String replace = '_', bool full = false}) {
    final clean = Fs.sanitize(name, replace: replace, full: full);
    final dir = p.dirname(raw);
    return Path(
      dir == '.' && !raw.startsWith('.') ? clean : p.join(dir, clean),
    );
  }

  // ------------------------------------------------------------------ ask --

  /// Whether anything — file, directory or link — is here.
  bool get exists => Entries.kind(raw) != null;

  /// Whether a regular file is here.
  bool get isFile => File(raw).existsSync();

  /// Whether a directory is here.
  bool get isDir => Directory(raw).existsSync();

  /// Whether a symbolic link is here.
  bool get isLink => Entries.kind(raw) == FileSystemEntryKind.link;

  /// Whether this path exists and holds something — not a zero-byte file.
  ///
  /// The check to make before parsing a file another process may still be
  /// writing: an empty file exists but has nothing to read.
  bool get hasContent => Fs.has(raw);

  /// What is here, or `null` when nothing is.
  FileSystemEntry? get stat => Entries.at(raw);

  /// The size in bytes of the file here, and `0` for anything else.
  ///
  /// [dirSize] is the recursive question about a directory.
  int get size => Entries.at(raw)?.size ?? 0;

  /// The total size in bytes of everything under this directory.
  Future<int> get dirSize async {
    var total = 0;
    await for (final entry in Entries.walkAsync(raw)) {
      total += entry.size;
    }
    return total;
  }

  /// Whether this directory holds no entries.
  Future<bool> get isDirEmpty => Entries.isEmptyAsync(raw);

  /// Whether a lock file here is currently held by a live process.
  ///
  /// See [lock].
  bool get isLocked => Lock.held(raw);

  // ----------------------------------------------------------------- read --

  /// The file here as text.
  Future<String> readText({Encoding encoding = utf8}) =>
      File(raw).readAsString(encoding: encoding);

  /// The file here as a list of lines.
  Future<List<String>> readLines({Encoding encoding = utf8}) =>
      File(raw).readAsLines(encoding: encoding);

  /// The file here as raw bytes.
  Future<List<int>> readBytes() => File(raw).readAsBytes();

  /// The file here parsed as a JSON document cursor.
  ///
  /// [read] with a leading dot is the same call for every other format:
  /// `read(.yaml)`, `read(.toml)`, `read(.csv)`.
  Future<Json> readJson() async =>
      DocumentFormat.json.parse(await _textOrEmpty);

  /// The file here parsed through [format].
  ///
  /// ```dart
  /// final settings = await Path('config.yaml').read(.yaml);
  /// final sheet = await Path('rows.csv').read(.csv);
  /// ```
  ///
  /// A file that is not there parses as the empty string, which every codec
  /// reads as the empty cursor — so an optional config needs no [exists] in
  /// front of it.
  Future<T> read<T>(DocumentFormat<T, Object?> format) async =>
      format.parse(await _textOrEmpty);

  /// The lines of the file here, as they are decoded.
  ///
  /// Streams rather than loading, so it is safe on a file larger than memory.
  Stream<String> lines({Encoding encoding = utf8}) =>
      Fs.lines(raw, encoding: encoding);

  /// The bytes of the file here, in chunks of [size].
  Stream<List<int>> chunks({int size = 64 * 1024}) =>
      Fs.chunks(raw, size: size);

  /// The CSV file here as raw rows of cells, streamed.
  Stream<List<String>> csvRows({
    String delimiter = ',',
    Encoding encoding = utf8,
  }) => _csvRows(raw, delimiter: delimiter, encoding: encoding);

  /// The CSV file here as records keyed by its header line, streamed.
  Stream<Map<String, String>> csvRecords({
    String delimiter = ',',
    Encoding encoding = utf8,
  }) async* {
    List<String>? headers;
    await for (final row in csvRows(delimiter: delimiter, encoding: encoding)) {
      if (headers == null) {
        headers = row;
        continue;
      }
      if (!CsvText.blank(row)) yield _record(headers, row);
    }
  }

  Future<String> get _textOrEmpty async {
    final file = File(raw);
    return await file.exists() ? file.readAsString() : '';
  }

  // ---------------------------------------------------------------- write --

  /// Writes [content] here atomically, staged through a `.part` file.
  Future<Path> writeText(
    String content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) async {
    await Fs.write(raw, content, part: part, encoding: encoding);
    return this;
  }

  /// Writes [lines] here atomically, one per line.
  Future<Path> writeLines(
    Iterable<String> lines, {
    String newline = '\n',
    Encoding encoding = utf8,
    String part = '.part',
  }) async {
    await Fs.pourLines(
      raw,
      Stream.fromIterable(lines),
      newline: newline,
      encoding: encoding,
      part: part,
    );
    return this;
  }

  /// Writes raw [bytes] here atomically.
  Future<Path> writeBytes(List<int> bytes, {String part = '.part'}) async {
    await Fs.save(raw, bytes, part: part);
    return this;
  }

  /// Serialises [data] as JSON and writes it here atomically.
  Future<Path> writeJson(
    Object? data, {
    bool pretty = true,
    String part = '.part',
  }) async {
    await Fs.dump(raw, data, pretty: pretty, part: part);
    return this;
  }

  /// Renders [value] through [as] and writes it here atomically.
  ///
  /// ```dart
  /// await Path('out/products.csv').write(rows, as: .csv);
  /// await Path('config.yaml').write(settings, as: .yaml);
  /// ```
  Future<Path> write<V>(
    V value, {
    required DocumentFormat<Object?, V> as,
    String part = '.part',
  }) async {
    await Fs.write(raw, as.format(value), part: part);
    return this;
  }

  /// Writes [rows] here as CSV, atomically, as they arrive.
  ///
  /// Takes a `Stream` so a million rows never have to be in memory at once.
  /// The header line is [headers], or the keys of the first row.
  Future<Path> writeCsv<V>(
    Stream<Map<String, V>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
    String part = '.part',
    Encoding encoding = utf8,
  }) async {
    await Fs.atomic(raw, (staging) async {
      final sink = staging.openWrite(encoding: encoding);
      var columns = headers;
      var headed = false;

      void line(Iterable<String> cells) => sink.write(
        '${cells.map((cell) => CsvText.escape(cell, delimiter)).join(delimiter)}'
        '$newline',
      );

      void header() {
        final names = columns;
        if (headed || names == null) return;
        line(names);
        headed = true;
      }

      try {
        await for (final row in rows) {
          columns ??= row.keys.toList();
          header();
          line([for (final key in columns) row[key]?.toString() ?? '']);
        }
        header();
        await sink.flush();
      } finally {
        await sink.close();
      }
    }, part: part);
    return this;
  }

  /// Appends [content] to the file here, creating it when it is not there.
  ///
  /// The one write that is deliberately not atomic: a log is appended to, not
  /// replaced.
  Future<Path> appendText(String content, {Encoding encoding = utf8}) async {
    await Fs.append(raw, content, encoding: encoding);
    return this;
  }

  /// Creates the file here when it is missing, and bumps its timestamp when
  /// it is not.
  Future<Path> touch() async {
    await Fs.touch(raw);
    return this;
  }

  // ----------------------------------------------------------------- move --

  /// Copies what is here to [destination], creating parent directories.
  Future<Path> copyTo(String destination) async =>
      Path((await Fs.copyAsync(raw, destination)).path);

  /// Moves what is here to [destination], creating parent directories.
  Future<Path> moveTo(String destination) async =>
      Path((await Fs.moveAsync(raw, destination)).path);

  /// Removes the file, link or directory here. `false` when nothing was there.
  Future<bool> delete() => Fs.removeAsync(raw);

  /// Creates the directory here, and any missing parent of it.
  Future<Path> makeDir() async => Path((await Fs.mkdir(raw)).path);

  /// Creates a symbolic link here pointing at [target].
  Future<Path> linkTo(String target) async =>
      Path((await Fs.link(raw, target)).path);

  /// What the symbolic link here points at, or `null` when it is not one.
  Future<String?> readLink() => Fs.target(raw);

  // ----------------------------------------------------------------- walk --

  /// The entries directly under this directory.
  ///
  /// [match] is a shell-style glob tested against each name. Pass
  /// [recursive] for the whole tree, or use [walk], which also takes a depth.
  Future<List<FileSystemEntry>> list({bool recursive = false, String? match}) =>
      Entries.walkAsync(
        raw,
        match: match,
        depth: recursive ? null : 1,
      ).toList();

  /// Everything under this directory, [depth] levels deep at most.
  Future<List<FileSystemEntry>> walk({String? match, int? depth}) =>
      Entries.walkAsync(raw, match: match, depth: depth).toList();

  /// The entries matching this path read as a shell-style glob pattern.
  ///
  /// ```dart
  /// for (final entry in await Path('src/**/*.dart').glob()) print(entry.path);
  /// ```
  Future<List<FileSystemEntry>> glob() => Entries.expandAsync(raw).toList();

  /// Deletes the files under this directory matching [match], and says how
  /// many went. Directories are left in place.
  ///
  /// It was `sweep` through 8.1.0, which did not say that anything was
  /// deleted.
  Future<int> deleteFiles({String? match}) async {
    var count = 0;
    for (final entry in await walk(match: match)) {
      if (entry.isFile || entry.isLink) {
        if (await Fs.removeAsync(entry.path)) count++;
      }
    }
    return count;
  }

  /// Calls [onChange] when anything at or under this path changes.
  ///
  /// Returns the function that stops watching. A burst of events for one save
  /// is coalesced into one call after `Iterable.settle`.
  Future<void> Function() watch(
    void Function(String path) onChange, {
    Pattern? pattern,
    Duration settle = const Duration(milliseconds: 200),
    bool recursive = true,
  }) => Watch.start(
    raw,
    onChange,
    pattern: pattern,
    settle: settle,
    recursive: recursive,
  );

  // ----------------------------------------------------------------- hold --

  /// Runs [action] with the lock file here held, safe across OS processes.
  ///
  /// A lock left behind by a process that died is detected and taken over.
  /// [wait] bounds how long to block for a live holder; without it the call
  /// throws [LockedError] at once.
  Future<R> lock<R>(FutureOr<R> Function() action, {Duration? wait}) =>
      Lock.hold(raw, action, wait: wait);

  /// The digest of the file here, as lowercase hex.
  ///
  /// ```dart
  /// final sum = await Path('dist/app.zip').hash(.sha256);
  /// ```
  ///
  /// Streams the file rather than loading it, so it is safe on one larger than
  /// memory. A file that is not there gives the empty-input digest.
  Future<String> hash([Algo algo = Algo.sha256]) => Fs.hashAsync(raw, algo);

  /// The blocking twin of every member above, under one name.
  ///
  /// ```dart
  /// await settings.readText();   // Future<String>
  /// settings.sync.readText();    // String
  /// ```
  SyncPath get sync => SyncPath(raw);
}

/// The blocking view of a [Path], reached through [Path.sync].
///
/// Every member here is the same operation as the [Path] member of the same
/// name, run on this thread. Reach for it in a short script where blocking the
/// event loop costs nothing; prefer [Path] everywhere else.
extension type const SyncPath(String raw) implements String {
  /// The file here as text.
  String readText({Encoding encoding = utf8}) =>
      File(raw).readAsStringSync(encoding: encoding);

  /// The file here as a list of lines.
  List<String> readLines({Encoding encoding = utf8}) =>
      File(raw).readAsLinesSync(encoding: encoding);

  /// The file here as raw bytes.
  List<int> readBytes() => File(raw).readAsBytesSync();

  /// The file here parsed as a JSON document cursor.
  Json readJson() => DocumentFormat.json.parse(_textOrEmpty);

  /// The file here parsed through [format].
  T read<T>(DocumentFormat<T, Object?> format) => format.parse(_textOrEmpty);

  /// The lines of the file here.
  Iterable<String> lines({Encoding encoding = utf8}) =>
      Fs.linesSync(raw, encoding: encoding);

  /// The bytes of the file here, in chunks of [size].
  Iterable<List<int>> chunks({int size = 64 * 1024}) =>
      Fs.chunksSync(raw, size: size);

  /// The CSV file here as raw rows of cells.
  Iterable<List<String>> csvRows({
    String delimiter = ',',
    Encoding encoding = utf8,
  }) => _csvRowsSync(raw, delimiter: delimiter, encoding: encoding);

  /// The CSV file here as records keyed by its header line.
  Iterable<Map<String, String>> csvRecords({
    String delimiter = ',',
    Encoding encoding = utf8,
  }) sync* {
    List<String>? headers;
    for (final row in csvRows(delimiter: delimiter, encoding: encoding)) {
      if (headers == null) {
        headers = row;
        continue;
      }
      if (!CsvText.blank(row)) yield _record(headers, row);
    }
  }

  String get _textOrEmpty {
    final file = File(raw);
    return file.existsSync() ? file.readAsStringSync() : '';
  }

  /// Writes [content] here atomically.
  Path writeText(
    String content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) {
    Fs.writeSync(raw, content, part: part, encoding: encoding);
    return Path(raw);
  }

  /// Writes [lines] here atomically, one per line.
  Path writeLines(
    Iterable<String> lines, {
    String newline = '\n',
    Encoding encoding = utf8,
    String part = '.part',
  }) {
    Fs.writeLinesSync(
      raw,
      lines.toList(),
      newline: newline,
      encoding: encoding,
      part: part,
    );
    return Path(raw);
  }

  /// Writes raw [bytes] here atomically.
  Path writeBytes(List<int> bytes, {String part = '.part'}) {
    Fs.saveSync(raw, bytes, part: part);
    return Path(raw);
  }

  /// Serialises [data] as JSON and writes it here atomically.
  Path writeJson(Object? data, {bool pretty = true, String part = '.part'}) {
    Fs.dumpSync(raw, data, pretty: pretty, part: part);
    return Path(raw);
  }

  /// Renders [value] through [as] and writes it here atomically.
  Path write<V>(
    V value, {
    required DocumentFormat<Object?, V> as,
    String part = '.part',
  }) {
    Fs.writeSync(raw, as.format(value), part: part);
    return Path(raw);
  }

  /// Writes [rows] here as CSV, atomically.
  Path writeCsv<V>(
    Iterable<Map<String, V>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
    String part = '.part',
  }) {
    Fs.writeSync(
      raw,
      CsvText.records(
        rows.toList(),
        headers: headers,
        delimiter: delimiter,
        newline: newline,
      ),
      part: part,
    );
    return Path(raw);
  }

  /// Appends [content] to the file here.
  Path appendText(String content, {Encoding encoding = utf8}) {
    Fs.appendSync(raw, content, encoding: encoding);
    return Path(raw);
  }

  /// Creates the file here, or bumps its timestamp.
  Path touch() {
    Fs.touchSync(raw);
    return Path(raw);
  }

  /// Copies what is here to [destination].
  Path copyTo(String destination) => Path(Fs.copySync(raw, destination).path);

  /// Moves what is here to [destination].
  Path moveTo(String destination) => Path(Fs.moveSync(raw, destination).path);

  /// Removes the file, link or directory here.
  bool delete() => Fs.removeSync(raw);

  /// Creates the directory here, and any missing parent of it.
  Path makeDir() => Path(Fs.mkdirSync(raw).path);

  /// Creates a symbolic link here pointing at [target].
  Path linkTo(String target) => Path(Fs.linkSync(raw, target).path);

  /// What the symbolic link here points at.
  String? readLink() => Fs.targetSync(raw);

  /// The entries directly under this directory.
  List<FileSystemEntry> list({bool recursive = false, String? match}) =>
      recursive
      ? Entries.walk(raw, match: match).toList()
      : Entries.list(raw, match: match).toList();

  /// Everything under this directory, [depth] levels deep at most.
  List<FileSystemEntry> walk({String? match, int? depth}) =>
      Entries.walk(raw, match: match, depth: depth).toList();

  /// The entries matching this path read as a shell-style glob pattern.
  List<FileSystemEntry> glob() => Entries.expand(raw).toList();

  /// Deletes the files under this directory matching [match].
  int deleteFiles({String? match}) {
    var count = 0;
    for (final entry in walk(match: match)) {
      if ((entry.isFile || entry.isLink) && Fs.removeSync(entry.path)) count++;
    }
    return count;
  }

  /// The total size in bytes of everything under this directory.
  int get dirSize {
    var total = 0;
    for (final entry in Entries.walk(raw)) {
      total += entry.size;
    }
    return total;
  }

  /// Whether this directory holds no entries.
  bool get isDirEmpty => Entries.isEmpty(raw);

  /// Whether this path exists and holds something.
  bool get hasContent => Fs.has(raw);

  /// Runs [action] with the lock file here held.
  R lock<R>(R Function() action) => Lock.holdSync(raw, action);

  /// The digest of the file here, as lowercase hex.
  String hash([Algo algo = Algo.sha256]) => Fs.hash(raw, algo);

  /// Creates and returns a new temporary directory.
  static Path tempDir([String prefix = 'tmp_']) =>
      Path(Fs.tempSync(prefix).path);

  /// Creates and returns a new empty temporary file.
  static Path tempFile([String prefix = 'tmp_']) =>
      Path(Fs.tempfileSync(prefix).path);
}

/// Lifts a `String` into a [Path].
///
/// The counterpart of `.url`, which lifts one into a `Uri`:
///
/// ```dart
/// await 'output/report.txt'.path.writeText(report);
/// final res = await Http.get('https://example.com'.url);
/// ```
extension PathOnString on String {
  /// This string read as a filesystem path.
  Path get path => Path(this);
}

// ============================================================================
// CSV ROW SCANNING
// ============================================================================

Stream<List<String>> _csvRows(
  String path, {
  required String delimiter,
  required Encoding encoding,
}) async* {
  final file = File(path);
  if (!await file.exists()) return;

  final pending = <List<String>>[];
  final scanner = CsvScanner(pending.add, delimiter: delimiter);
  await for (final chunk in file.openRead().transform(encoding.decoder)) {
    scanner.add(chunk);
    for (final row in pending) {
      yield row;
    }
    pending.clear();
  }
  scanner.close();
  for (final row in pending) {
    yield row;
  }
}

Iterable<List<String>> _csvRowsSync(
  String path, {
  required String delimiter,
  required Encoding encoding,
}) sync* {
  final file = File(path);
  if (!file.existsSync()) return;

  final pending = <List<String>>[];
  final scanner = CsvScanner(pending.add, delimiter: delimiter);
  final decoder = encoding.decoder.startChunkedConversion(_Feed(scanner.add));
  for (final chunk in Fs.chunksSync(path)) {
    decoder.add(chunk);
    yield* pending;
    pending.clear();
  }
  decoder.close();
  scanner.close();
  yield* pending;
}

/// One row keyed by [headers], short rows padded with empty strings.
Map<String, String> _record(List<String> headers, List<String> row) => {
  for (var i = 0; i < headers.length; i++)
    headers[i]: i < row.length ? row[i] : '',
};

/// A [Sink] that hands each decoded piece of text straight to a callback.
class _Feed implements Sink<String> {
  _Feed(this._each);

  final void Function(String text) _each;

  @override
  void add(String data) => _each(data);

  @override
  void close() {}
}

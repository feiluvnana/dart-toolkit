/// # Filesystem, Paths & Atomic Writes (internal)
///
/// Implementation behind the public `io.*` namespace. Every write stages into
/// a `.part` sibling and renames it into place only after a successful flush,
/// so an interrupted run never leaves a truncated file behind. Staged files
/// are registered with [Exit] and removed on Ctrl-C.
///
/// Not exported: reach these operations through `io.*`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../io/entry.dart';
import 'entries.dart';
import 'proc.dart';

// ============================================================================
// FILESYSTEM, PATHS & ATOMIC WRITES (Fs)
// ============================================================================

/// Hash algorithms accepted by [Fs.hash].
///
/// Named `Algo` and not `Digest` because `package:crypto` exports a `Digest`
/// of its own — a hash *result*, where this one selects an *algorithm* — and
/// two libraries exporting one name is an `ambiguous_import` error for anyone
/// importing both.
enum Algo {
  /// SHA-256, producing a 64-character hex digest.
  sha256,

  /// MD5, producing a 32-character hex digest.
  md5,
}

/// Static filesystem helpers backing the `io.*` namespace.
///
/// Paths are plain strings throughout. Given a [File] or [Directory], pass its
/// [FileSystemEntity.path].
class Fs {
  const Fs._();

  /// Replaces characters that are illegal in filenames.
  ///
  /// By default illegal characters collapse to [replace]. With [full] they are
  /// swapped for full-width look-alikes instead, which preserves readability
  /// for titles. Control characters and trailing dots are always stripped, and
  /// an empty result becomes `'unnamed'`.
  static String sanitize(
    String name, {
    String replace = '_',
    bool full = false,
  }) {
    const wide = <String, String>{
      ':': '：',
      '"': '”',
      '/': '／',
      r'\': '＼',
      '*': '＊',
      '?': '？',
      '<': '＜',
      '>': '＞',
      '|': '｜',
    };

    var s = name;
    if (full) {
      wide.forEach((from, to) => s = s.replaceAll(from, to));
    } else {
      s = s.replaceAll(RegExp(r'[:"\/\\*?<>|]'), replace);
    }
    s = s.replaceAll(RegExp(r'[\x00-\x1F\x7F\r\n\t]'), '').trim();
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1).trim();
    }
    return s.isEmpty ? 'unnamed' : s;
  }

  /// The current working directory.
  static String get cwd => Directory.current.path;

  /// The current user's home directory, never null.
  static String get home {
    final env = Platform.environment;
    final named = Platform.isWindows
        ? env['USERPROFILE'] ??
              ((env['HOMEDRIVE'] ?? '') + (env['HOMEPATH'] ?? ''))
        : env['HOME'];
    return named == null || named.isEmpty ? cwd : named;
  }

  /// The entry at [path] after an operation that guarantees it exists.
  ///
  /// A caller that has just written or created [path] cannot get `null` back
  /// except by losing a race with something that deleted it, so the fallback
  /// describes an empty file rather than making every write return a nullable.
  static FileSystemEntry entryFor(String path) =>
      Entries.at(path) ??
      FileSystemEntry(
        path: path,
        kind: FileSystemEntryKind.file,
        size: 0,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
      );

  /// Creates the directory at [path], including parents.
  static Future<FileSystemEntry> mkdir(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) await dir.create(recursive: true);
    return entryFor(path);
  }

  /// Creates the directory at [path], including parents, blocking.
  static FileSystemEntry mkdirSync(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return entryFor(path);
  }

  /// Creates the directory holding [path], and returns it.
  static Future<FileSystemEntry> mkparent(String path) =>
      mkdir(p.dirname(path));

  /// Creates the directory holding [path], blocking, and returns it.
  static FileSystemEntry mkparentSync(String path) =>
      mkdirSync(p.dirname(path));

  /// Creates a symbolic link at [path] pointing at [target], blocking.
  ///
  /// Replaces a link already at [path]; anything else there is left alone and
  /// the create throws, because silently unlinking a real file to put a
  /// pointer in its place is not a thing a caller asked for.
  static FileSystemEntry linkSync(String path, String target) {
    mkparentSync(path);
    final link = Link(path);
    if (Entries.kind(path) == FileSystemEntryKind.link) link.deleteSync();
    link.createSync(target);
    return entryFor(path);
  }

  /// The non-blocking twin of [linkSync].
  static Future<FileSystemEntry> link(String path, String target) async {
    await mkparent(path);
    final link = Link(path);
    if (await Entries.kindAsync(path) == FileSystemEntryKind.link) {
      await link.delete();
    }
    await link.create(target);
    return entryFor(path);
  }

  /// What the link at [path] points at, or `null` when it is not a link.
  static String? targetSync(String path) {
    if (Entries.kind(path) != FileSystemEntryKind.link) return null;
    try {
      return Link(path).targetSync();
    } on FileSystemException {
      return null;
    }
  }

  /// The non-blocking twin of [targetSync].
  static Future<String?> target(String path) async {
    if (await Entries.kindAsync(path) != FileSystemEntryKind.link) return null;
    try {
      return await Link(path).target();
    } on FileSystemException {
      return null;
    }
  }

  /// Creates a new empty temporary file with the given name [prefix].
  ///
  /// The file half of [tempSync]: a unique directory is made and the file
  /// put inside it, so two callers with one prefix cannot collide and
  /// removing the directory removes the file.
  static FileSystemEntry tempfileSync([String prefix = 'tmp_']) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    final file = File(p.join(dir.path, '$prefix${_staged++}'))..createSync();
    return entryFor(file.path);
  }

  /// The non-blocking twin of [tempfileSync].
  static Future<FileSystemEntry> tempfile([String prefix = 'tmp_']) async {
    final dir = await Directory.systemTemp.createTemp(prefix);
    final file = File(p.join(dir.path, '$prefix${_staged++}'));
    await file.create();
    return entryFor(file.path);
  }

  /// Reads [path] in byte chunks of at most [size], blocking per chunk.
  ///
  /// A generator, so nothing opens until the first walk and a reader that
  /// stops early stops reading.
  static Iterable<List<int>> chunksSync(
    String path, {
    int size = 64 * 1024,
  }) sync* {
    if (size <= 0) throw ArgumentError.value(size, 'size', 'must be positive');
    final handle = File(path).openSync();
    try {
      while (true) {
        final chunk = handle.readSync(size);
        if (chunk.isEmpty) return;
        yield chunk;
      }
    } finally {
      handle.closeSync();
    }
  }

  /// Streams [path] in byte chunks of at most [size].
  static Stream<List<int>> chunks(String path, {int size = 64 * 1024}) {
    if (size <= 0) throw ArgumentError.value(size, 'size', 'must be positive');
    return File(path).openRead().transform(_rechunk(size));
  }

  /// Regroups a byte stream into chunks of exactly [size], the last short.
  static StreamTransformer<List<int>, List<int>> _rechunk(int size) {
    var held = <int>[];
    return StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (chunk, sink) {
        held.addAll(chunk);
        while (held.length >= size) {
          sink.add(held.sublist(0, size));
          held = held.sublist(size);
        }
      },
      handleDone: (sink) {
        if (held.isNotEmpty) sink.add(held);
        sink.close();
      },
    );
  }

  /// Creates a new temporary directory with the given name [prefix].
  static Future<FileSystemEntry> temp([String prefix = 'tmp_']) async =>
      entryFor((await Directory.systemTemp.createTemp(prefix)).path);

  /// Creates a new temporary directory with the given name [prefix], blocking.
  static FileSystemEntry tempSync([String prefix = 'tmp_']) =>
      entryFor(Directory.systemTemp.createTempSync(prefix).path);

  /// Whether [path] exists and holds at least one byte.
  ///
  /// Zero-length files count as absent, since an interrupted write can leave
  /// one behind. Pass [match] to also accept a loosely-named sibling — see
  /// [similar] for the caveats before enabling it.
  static bool has(String path, {bool match = false}) {
    final file = File(path);
    if (file.existsSync() && file.lengthSync() > 0) return true;
    return match && similar(path);
  }

  /// Whether a *loosely* similarly-named non-empty file sits beside [path].
  ///
  /// A sibling matches when its base name equals [path]'s, or when either name
  /// is the other suffixed after an underscore — so `cover.jpg` is considered
  /// present when `thumb_cover.jpg` exists. This is deliberately fuzzy and can
  /// skip work you wanted done, which is why every caller defaults to *not*
  /// using it.
  static bool similar(String path) {
    if (has(path)) return true;
    final dir = File(path).parent;
    if (!dir.existsSync()) return false;
    final base = p.basenameWithoutExtension(path).toLowerCase();
    for (final entity in dir.listSync().whereType<File>()) {
      if (entity.lengthSync() == 0 || entity.path.endsWith('.part')) continue;
      final other = p.basenameWithoutExtension(entity.path).toLowerCase();
      if (other == base ||
          other.endsWith('_$base') ||
          base.endsWith('_$other')) {
        return true;
      }
    }
    return false;
  }

  /// Writes [content] to [path] atomically via a `.part` staging file.
  static Future<File> write(
    String path,
    String content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) => atomic(
    path,
    (staging) =>
        staging.writeAsString(content, encoding: encoding, flush: true),
    part: part,
  );

  /// Writes raw [content] bytes to [path] atomically.
  static Future<File> save(
    String path,
    List<int> content, {
    String part = '.part',
  }) => atomic(
    path,
    (staging) => staging.writeAsBytes(content, flush: true),
    part: part,
  );

  /// Encodes [data] as JSON and writes it to [path] atomically.
  ///
  /// [data] accepts any value `jsonEncode` understands — maps, lists, numbers,
  /// strings, booleans and `null`. [pretty] indents the output by two spaces.
  static Future<File> dump(
    String path,
    Object? data, {
    bool pretty = true,
    String part = '.part',
    Encoding encoding = utf8,
  }) {
    return write(path, _encode(data, pretty), part: part, encoding: encoding);
  }

  /// Runs [fill] against a `.part` staging file, then renames it over [path].
  ///
  /// The staging file is registered with [Exit] so an interrupted run cannot
  /// leave it behind, and is only moved into place once [fill] completes. Any
  /// failure discards the staging file and rethrows. This is the single write
  /// path behind [write], [save], [dump] and [download].
  static Future<File> atomic(
    String path,
    Future<void> Function(File staging) fill, {
    String part = '.part',
  }) async {
    final file = File(path);
    await mkparent(path);
    final staging = File(_staging(path, part));
    Exit.track(staging);
    try {
      await fill(staging);
      await _swapAsync(staging, file);
      return file;
    } catch (_) {
      await _discardAsync(staging);
      rethrow;
    } finally {
      Exit.untrack(staging);
    }
  }

  /// Runs [fill] against a `.part` staging file, then renames it over [path].
  ///
  /// The blocking twin of [atomic], with the same guarantees.
  static File atomicSync(
    String path,
    void Function(File staging) fill, {
    String part = '.part',
  }) {
    final file = File(path);
    mkparentSync(path);
    final staging = File(_staging(path, part));
    Exit.track(staging);
    try {
      fill(staging);
      _swap(staging, file);
      return file;
    } catch (_) {
      _discard(staging);
      rethrow;
    } finally {
      Exit.untrack(staging);
    }
  }

  /// Writes [content] to [path] atomically, blocking until done.
  static File writeSync(
    String path,
    String content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) => atomicSync(
    path,
    (staging) =>
        staging.writeAsStringSync(content, encoding: encoding, flush: true),
    part: part,
  );

  /// Writes raw [content] bytes to [path] atomically, blocking until done.
  static File saveSync(
    String path,
    List<int> content, {
    String part = '.part',
  }) => atomicSync(
    path,
    (staging) => staging.writeAsBytesSync(content, flush: true),
    part: part,
  );

  /// Encodes [data] as JSON and writes it to [path] atomically, blocking.
  static File dumpSync(
    String path,
    Object? data, {
    bool pretty = true,
    String part = '.part',
    Encoding encoding = utf8,
  }) => writeSync(path, _encode(data, pretty), part: part, encoding: encoding);

  static String _encode(Object? data, bool pretty) => pretty
      ? const JsonEncoder.withIndent('  ').convert(data)
      : jsonEncode(data);

  // --- Non-blocking counterparts, reached through `io.async.*` -------------

  /// Whether [path] exists and holds at least one byte, without blocking.
  static Future<bool> hasAsync(String path, {bool match = false}) async {
    final file = File(path);
    if (await file.exists() && await file.length() > 0) return true;
    return match && await similarAsync(path);
  }

  /// Whether a loosely similarly-named non-empty file sits beside [path].
  static Future<bool> similarAsync(String path) async {
    if (await hasAsync(path)) return true;
    final dir = File(path).parent;
    if (!await dir.exists()) return false;
    final base = p.basenameWithoutExtension(path).toLowerCase();
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.part') || await entity.length() == 0) continue;
      final other = p.basenameWithoutExtension(entity.path).toLowerCase();
      if (other == base ||
          other.endsWith('_$base') ||
          base.endsWith('_$other')) {
        return true;
      }
    }
    return false;
  }

  /// Removes the file, link or directory at [path] without blocking.
  static Future<bool> removeAsync(String path) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.file ||
        type == FileSystemEntityType.link) {
      await File(path).delete();
      return true;
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
      return true;
    }
    return false;
  }

  /// Copies [source] to [destination] without blocking, directories included.
  ///
  /// The non-blocking twin of [copySync], with the same kind-preserving rule.
  static Future<FileSystemEntry> copyAsync(
    String source,
    String destination,
  ) async {
    final kind = await Entries.kindAsync(source);
    if (kind == null) {
      throw FileSystemException('Cannot copy, no entry at source', source);
    }
    if (kind != FileSystemEntryKind.directory) {
      await mkparent(destination);
      await _cloneAsync(source, destination, kind);
      return entryFor(destination);
    }
    await Directory(destination).create(recursive: true);
    await for (final entry in Entries.walkAsync(source, follow: false)) {
      final target = p.join(destination, p.relative(entry.path, from: source));
      if (entry.isdir) {
        await Directory(target).create(recursive: true);
        continue;
      }
      await mkparent(target);
      await _cloneAsync(entry.path, target, entry.kind);
    }
    return entryFor(destination);
  }

  /// Reproduces the one entry at [source] as [destination], kind and all.
  static Future<void> _cloneAsync(
    String source,
    String destination,
    FileSystemEntryKind kind,
  ) async {
    if (kind == FileSystemEntryKind.link) {
      await Link(destination).create(await Link(source).target());
      return;
    }
    await File(source).copy(destination);
  }

  /// Moves [source] to [destination] without blocking, crossing filesystems.
  ///
  /// The non-blocking twin of [moveSync], with the same two rules.
  static Future<FileSystemEntry> moveAsync(
    String source,
    String destination,
  ) async {
    final kind = await Entries.kindAsync(source);
    if (kind == null) {
      throw FileSystemException('Cannot move, no entry at source', source);
    }
    _refuseMerge(kind, await Entries.kindAsync(destination), destination);
    await mkparent(destination);
    try {
      await _renameAsync(source, destination, kind);
      return entryFor(destination);
    } on FileSystemException catch (error) {
      if (!_crossdevice(error)) rethrow;
      final copied = await copyAsync(source, destination);
      await removeAsync(source);
      return copied;
    }
  }

  static Future<void> _renameAsync(
    String source,
    String destination,
    FileSystemEntryKind kind,
  ) async {
    switch (kind) {
      case FileSystemEntryKind.directory:
        await Directory(source).rename(destination);
      case FileSystemEntryKind.link:
        await Link(source).rename(destination);
      case FileSystemEntryKind.file:
        await File(source).rename(destination);
    }
  }

  /// Copies [source] to [destination], blocking, directories included.
  ///
  /// **Kind-preserving**: a symlink is copied as a symlink, pointing where it
  /// pointed. Through 5.4.0 this walked with `Directory.list(recursive: true)`
  /// and branched on `is Directory` / `is File`, so a link to a file was
  /// dereferenced into a second copy of the content and a link to a directory
  /// matched neither branch and was dropped without a word. The walk is
  /// [Entries.walk] now, which has the three kinds and the cycle guard, and
  /// does not follow links out of the tree it was asked to copy.
  static FileSystemEntry copySync(String source, String destination) {
    final kind = Entries.kind(source);
    if (kind == null) {
      throw FileSystemException('Cannot copy, no entry at source', source);
    }
    if (kind != FileSystemEntryKind.directory) {
      mkparentSync(destination);
      _clone(source, destination, kind);
      return entryFor(destination);
    }
    Directory(destination).createSync(recursive: true);
    for (final entry in Entries.walk(source, follow: false)) {
      final target = p.join(destination, p.relative(entry.path, from: source));
      if (entry.isdir) {
        Directory(target).createSync(recursive: true);
        continue;
      }
      mkparentSync(target);
      _clone(entry.path, target, entry.kind);
    }
    return entryFor(destination);
  }

  /// Reproduces the one entry at [source] as [destination], kind and all.
  static void _clone(
    String source,
    String destination,
    FileSystemEntryKind kind,
  ) {
    if (kind == FileSystemEntryKind.link) {
      Link(destination).createSync(Link(source).targetSync());
      return;
    }
    File(source).copySync(destination);
  }

  /// Moves [source] to [destination], blocking, crossing filesystems.
  ///
  /// Two rules that were not there through 5.4.0.
  ///
  /// **A directory is never merged into an existing directory.** `rename`
  /// refuses that, and the old blanket `on FileSystemException` caught the
  /// refusal and fell back to copy-and-delete — which merged the two trees
  /// and deleted the source, silently, where the caller had asked for a move.
  ///
  /// **The fallback is for a cross-device move and nothing else.** Every
  /// other failure — a permission, a read-only target, a vanished source —
  /// is rethrown as itself rather than becoming a half-finished copy.
  static FileSystemEntry moveSync(String source, String destination) {
    final kind = Entries.kind(source);
    if (kind == null) {
      throw FileSystemException('Cannot move, no entry at source', source);
    }
    _refuseMerge(kind, Entries.kind(destination), destination);
    mkparentSync(destination);
    try {
      _rename(source, destination, kind);
      return entryFor(destination);
    } on FileSystemException catch (error) {
      if (!_crossdevice(error)) rethrow;
      final copied = copySync(source, destination);
      removeSync(source);
      return copied;
    }
  }

  static void _rename(
    String source,
    String destination,
    FileSystemEntryKind kind,
  ) {
    switch (kind) {
      case FileSystemEntryKind.directory:
        Directory(source).renameSync(destination);
      case FileSystemEntryKind.link:
        Link(source).renameSync(destination);
      case FileSystemEntryKind.file:
        File(source).renameSync(destination);
    }
  }

  /// Throws rather than let a directory move turn into a merge.
  static void _refuseMerge(
    FileSystemEntryKind source,
    FileSystemEntryKind? destination,
    String path,
  ) {
    if (source != FileSystemEntryKind.directory) return;
    if (destination != FileSystemEntryKind.directory) return;
    throw FileSystemException(
      'Cannot move a directory onto an existing directory',
      path,
    );
  }

  /// Whether [error] is the kernel saying *the two paths are on different
  /// filesystems* — `EXDEV`, and the one failure a copy-and-delete answers.
  static bool _crossdevice(FileSystemException error) {
    final code = error.osError?.errorCode;
    if (code == null) return false;
    // ERROR_NOT_SAME_DEVICE on Windows; EXDEV everywhere else.
    return code == (Platform.isWindows ? 17 : 18);
  }

  /// Removes the file, link or directory at [path]; `false` when absent.
  static bool removeSync(String path) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file ||
        type == FileSystemEntityType.link) {
      File(path).deleteSync();
      return true;
    }
    if (type == FileSystemEntityType.directory) {
      Directory(path).deleteSync(recursive: true);
      return true;
    }
    return false;
  }

  /// Appends [content] to [path], creating the file and its parents.
  ///
  /// The one write in this library that does not stage through a `.part`
  /// file: appending adds to what is already there, so there is nothing to
  /// swap into place. An interrupted append can leave a partial line.
  static FileSystemEntry appendSync(
    String path,
    String content, {
    Encoding encoding = utf8,
  }) {
    mkparentSync(path);
    File(path).writeAsStringSync(
      content,
      mode: FileMode.append,
      encoding: encoding,
      flush: true,
    );
    return entryFor(path);
  }

  /// Appends [content] to [path] without blocking. See [appendSync].
  static Future<FileSystemEntry> append(
    String path,
    String content, {
    Encoding encoding = utf8,
  }) async {
    await mkparent(path);
    await File(path).writeAsString(
      content,
      mode: FileMode.append,
      encoding: encoding,
      flush: true,
    );
    return entryFor(path);
  }

  /// Creates [path] empty when it is missing, or bumps its mtime when it is
  /// not.
  static FileSystemEntry touchSync(String path) {
    final file = File(path);
    if (file.existsSync()) {
      file.setLastModifiedSync(DateTime.now());
    } else {
      mkparentSync(path);
      file.createSync();
    }
    return entryFor(path);
  }

  /// The non-blocking twin of [touchSync].
  static Future<FileSystemEntry> touch(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.setLastModified(DateTime.now());
    } else {
      await mkparent(path);
      await file.create();
    }
    return entryFor(path);
  }

  /// Writes [lines] to [path] atomically, one element per line.
  ///
  /// The blocking twin of [pourLines]. The whole sequence is walked while the
  /// staging file is open, so nothing is held but the line being written.
  static File writeLinesSync(
    String path,
    Iterable<String> lines, {
    String newline = '\n',
    Encoding encoding = utf8,
    String part = '.part',
  }) => atomicSync(path, part: part, (staging) {
    // A `RandomAccessFile` rather than an `IOSink`: a sink is asynchronous,
    // so `close()` hands back a future and the rename would happen before
    // anything reached the disk. This is the blocking path.
    final handle = staging.openSync(mode: FileMode.writeOnly);
    try {
      for (final line in lines) {
        handle.writeFromSync(encoding.encode('$line$newline'));
      }
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
  });

  /// Writes [lines] to [path] atomically as they arrive, one per line.
  ///
  /// The file appears whole or not at all: lines go to a staging file that is
  /// renamed into place once the stream closes, and discarded if it fails.
  static Future<File> pourLines(
    String path,
    Stream<String> lines, {
    String newline = '\n',
    Encoding encoding = utf8,
    String part = '.part',
  }) => atomic(path, part: part, (staging) async {
    final sink = staging.openWrite(encoding: encoding);
    try {
      await for (final line in lines) {
        sink
          ..write(line)
          ..write(newline);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  });

  /// Writes [items] to [path] atomically as a JSON array, as they arrive.
  ///
  /// The brackets and commas are written around the elements rather than the
  /// whole array being built first, so a flow of any size becomes a JSON file
  /// without ever being a `List`.
  static Future<File> pourJson(
    String path,
    Stream<Object?> items, {
    bool pretty = true,
    Encoding encoding = utf8,
    String part = '.part',
  }) => atomic(path, part: part, (staging) async {
    final sink = staging.openWrite(encoding: encoding);
    final encoder = pretty
        ? const JsonEncoder.withIndent('  ')
        : const JsonEncoder();
    try {
      var first = true;
      sink.write(pretty ? '[\n' : '[');
      await for (final item in items) {
        if (!first) sink.write(pretty ? ',\n' : ',');
        first = false;
        final text = encoder.convert(item);
        sink.write(
          pretty ? text.split('\n').map((l) => '  $l').join('\n') : text,
        );
      }
      sink.write(pretty ? (first ? ']' : '\n]') : ']');
      await sink.flush();
    } finally {
      await sink.close();
    }
  });

  /// Streams [url] to [path] atomically via a `.part` staging file.
  ///
  /// [onProgress] receives `(received, total)` as bytes arrive; `total` is `-1`
  /// when the server sends no `Content-Length`. A short read against a known
  /// length fails rather than renaming a truncated file into place. Pass
  /// [client] to reuse an existing connection pool.
  static Future<File> download(
    Uri url,
    String path, {
    http.Client? pool,
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    String part = '.part',
  }) {
    final httpClient = pool ?? http.Client();
    final ownsClient = pool == null;
    return atomic(path, part: part, (staging) async {
      try {
        final request = http.Request('GET', url);
        if (headers != null) request.headers.addAll(headers);
        final response = await httpClient.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.drain<void>();
          throw HttpException('HTTP ${response.statusCode}', uri: url);
        }

        final total = response.contentLength ?? -1;
        var received = 0;
        final sink = staging.openWrite();
        try {
          await response.stream.listen((chunk) {
            sink.add(chunk);
            received += chunk.length;
            onProgress?.call(received, total);
          }).asFuture<void>();
          await sink.flush();
        } finally {
          // A transfer that dies mid-stream still holds an open handle on the
          // staging file; leaving it open leaks the descriptor and blocks the
          // cleanup unlink on Windows.
          await sink.close();
        }

        if (total != -1 && await staging.length() != total) {
          throw HttpException('Incomplete download', uri: url);
        }
      } finally {
        if (ownsClient) httpClient.close();
      }
    });
  }

  /// Streams [path] as decoded lines, without loading the whole file.
  static Stream<String> lines(String path, {Encoding encoding = utf8}) => File(
    path,
  ).openRead().transform(encoding.decoder).transform(const LineSplitter());

  /// Reads [path] as decoded lines, blocking — on the first walk, not before.
  ///
  /// A generator rather than `readAsLinesSync`, so `io.lines(path)` is the
  /// lazy view a [Sequence] promises: nothing is read until something walks
  /// it, a walk that stops early stops reading, and a second walk re-reads
  /// the file rather than replaying a snapshot of it.
  static Iterable<String> linesSync(
    String path, {
    Encoding encoding = utf8,
  }) sync* {
    yield* LineSplitter.split(File(path).readAsStringSync(encoding: encoding));
  }

  /// How much of a file is read at a time when hashing it.
  static const int _hashChunk = 64 * 1024;

  static crypto.Hash _digest(Algo algorithm) => switch (algorithm) {
    Algo.md5 => crypto.md5,
    Algo.sha256 => crypto.sha256,
  };

  /// Returns the hex digest of [path] using [algorithm].
  ///
  /// Reads the file in chunks, so hashing a file larger than memory works.
  static String hash(String path, [Algo algorithm = Algo.sha256]) {
    final handle = File(path).openSync();
    try {
      final sink = _CollectingSink();
      final input = _digest(algorithm).startChunkedConversion(sink);
      try {
        while (true) {
          final chunk = handle.readSync(_hashChunk);
          if (chunk.isEmpty) break;
          input.add(chunk);
        }
      } finally {
        input.close();
      }
      return sink.value.toString();
    } finally {
      handle.closeSync();
    }
  }

  /// Returns the hex digest of [path] using [algorithm] asynchronously.
  ///
  /// Streams the file rather than holding it in memory.
  static Future<String> hashAsync(
    String path, [
    Algo algorithm = Algo.sha256,
  ]) async {
    final sink = _CollectingSink();
    final input = _digest(algorithm).startChunkedConversion(sink);
    try {
      await for (final chunk in File(path).openRead()) {
        input.add(chunk);
      }
    } finally {
      input.close();
    }
    return sink.value.toString();
  }

  /// The entry at [path], or `null` when there is nothing there.
  static FileSystemEntry? stat(String path) => Entries.at(path);

  /// The entry at [path] without blocking, or `null` when nothing is there.
  static Future<FileSystemEntry?> statAsync(String path) =>
      Entries.atAsync(path);

  /// How many staging files this process has opened, so far.
  static int _staged = 0;

  /// The staging path a write to [path] gets, unique to this call.
  ///
  /// `'$path$part'` through 5.4.0, which meant two writes to one path shared
  /// one staging file: the second `atomic` deleted the first's file out from
  /// under it, and the first's rename then failed with an internal `.part`
  /// path in the message. The pid and a per-process counter make the staging
  /// file private to the call, so concurrent writers race only on the final
  /// rename — which POSIX makes atomic, so the last writer wins cleanly.
  ///
  /// [part] stays the suffix, so `io.dir.sweep(out, match: '*.part')` still
  /// finds an abandoned one.
  static String _staging(String path, String part) =>
      '$path.${pid.toRadixString(36)}${(_staged++).toRadixString(36)}$part';

  /// Moves [staging] over [destination] without exposing a gap.
  ///
  /// POSIX `rename` replaces the destination atomically, so a reader either
  /// sees the old file or the new one — never a moment with neither. Deleting
  /// first would open exactly that window, so the unlink happens only on
  /// Windows, where renaming onto an existing path fails.
  static void _swap(File staging, File destination) {
    if (Platform.isWindows && destination.existsSync()) {
      destination.deleteSync();
    }
    staging.renameSync(destination.path);
  }

  /// The non-blocking twin of [_swap], for the write path that promises not
  /// to block.
  static Future<void> _swapAsync(File staging, File destination) async {
    if (Platform.isWindows && await destination.exists()) {
      await destination.delete();
    }
    await staging.rename(destination.path);
  }

  /// Removes a staging file, ignoring failures during error unwinding.
  static void _discard(File staging) {
    if (!staging.existsSync()) return;
    try {
      staging.deleteSync();
    } catch (_) {}
  }

  /// The non-blocking twin of [_discard].
  static Future<void> _discardAsync(File staging) async {
    if (!await staging.exists()) return;
    try {
      await staging.delete();
    } catch (_) {}
  }
}

/// Captures the single digest a chunked hash conversion produces.
class _CollectingSink implements Sink<crypto.Digest> {
  late crypto.Digest value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

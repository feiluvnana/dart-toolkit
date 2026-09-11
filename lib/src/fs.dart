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

  /// Creates the directory at [path], including parents.
  ///
  /// Set [sync] to block instead of awaiting, for use in synchronous paths.
  static Future<Directory> mkdir(String path, {bool sync = false}) async {
    final dir = Directory(path);
    if (sync) {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Creates the parent directory of [path] if it is missing.
  static void parent(String path) {
    final dir = Directory(p.dirname(path));
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }

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
    parent(path);
    final staging = File('$path$part');
    if (staging.existsSync()) staging.deleteSync();
    Exit.track(staging);
    try {
      await fill(staging);
      _swap(staging, file);
      return file;
    } catch (_) {
      _discard(staging);
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
    parent(path);
    final staging = File('$path$part');
    if (staging.existsSync()) staging.deleteSync();
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

  /// Creates the parent directory of [path] if it is missing, without blocking.
  static Future<void> parentAsync(String path) async {
    final dir = Directory(p.dirname(path));
    if (!await dir.exists()) await dir.create(recursive: true);
  }

  /// Lists files under [dir] without blocking, optionally filtered by [pattern].
  static Future<List<File>> findAsync(
    String dir, {
    Pattern? pattern,
    bool recursive = true,
  }) async {
    final directory = Directory(dir);
    if (!await directory.exists()) return [];
    final files = <File>[];
    await for (final entity in directory.list(recursive: recursive)) {
      if (entity is! File) continue;
      if (pattern == null ||
          pattern.allMatches(p.basename(entity.path)).isNotEmpty) {
        files.add(entity);
      }
    }
    return files;
  }

  /// Deletes files under [dir] matching [pattern] without blocking.
  static Future<int> deleteAsync(
    String dir, {
    Pattern? pattern,
    bool recursive = false,
  }) async {
    var count = 0;
    for (final file in await findAsync(
      dir,
      pattern: pattern,
      recursive: recursive,
    )) {
      try {
        await file.delete();
        count++;
      } catch (_) {}
    }
    return count;
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
  static Future<FileSystemEntity> copyAsync(
    String source,
    String destination,
  ) async {
    if (await FileSystemEntity.type(source) == FileSystemEntityType.directory) {
      final destDir = await Directory(destination).create(recursive: true);
      await for (final entity in Directory(source).list(recursive: true)) {
        final target = p.join(
          destination,
          p.relative(entity.path, from: source),
        );
        if (entity is Directory) {
          await Directory(target).create(recursive: true);
        } else if (entity is File) {
          await Directory(p.dirname(target)).create(recursive: true);
          await entity.copy(target);
        }
      }
      return destDir;
    }
    await Directory(p.dirname(destination)).create(recursive: true);
    return File(source).copy(destination);
  }

  /// Moves [source] to [destination] without blocking, crossing filesystems.
  static Future<FileSystemEntity> moveAsync(
    String source,
    String destination,
  ) async {
    await Directory(p.dirname(destination)).create(recursive: true);
    try {
      if (await FileSystemEntity.type(source) ==
          FileSystemEntityType.directory) {
        return await Directory(source).rename(destination);
      }
      return await File(source).rename(destination);
    } on FileSystemException {
      final copied = await copyAsync(source, destination);
      await removeAsync(source);
      return copied;
    }
  }

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

        if (total != -1 && staging.lengthSync() != total) {
          throw HttpException('Incomplete download', uri: url);
        }
      } finally {
        if (ownsClient) httpClient.close();
      }
    });
  }

  /// Lists files under [dir], optionally filtered by [pattern] on the basename.
  ///
  /// Returns an empty list when [dir] does not exist.
  static List<File> find(
    String dir, {
    Pattern? pattern,
    bool recursive = true,
  }) {
    final directory = Directory(dir);
    if (!directory.existsSync()) return [];
    return directory
        .listSync(recursive: recursive)
        .whereType<File>()
        .where(
          (f) =>
              pattern == null ||
              pattern.allMatches(p.basename(f.path)).isNotEmpty,
        )
        .toList();
  }

  /// Deletes files under [dir] matching [pattern] and returns the count.
  ///
  /// Files that cannot be deleted are skipped rather than aborting the sweep.
  static int delete(String dir, {Pattern? pattern, bool recursive = false}) {
    var count = 0;
    for (final file in find(dir, pattern: pattern, recursive: recursive)) {
      try {
        file.deleteSync();
        count++;
      } catch (_) {}
    }
    return count;
  }

  /// Streams [path] as decoded lines, without loading the whole file.
  static Stream<String> lines(String path, {Encoding encoding = utf8}) => File(
    path,
  ).openRead().transform(encoding.decoder).transform(const LineSplitter());

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

  /// Returns filesystem metadata for [path].
  static FileStat stat(String path) => File(path).statSync();

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

  /// Removes a staging file, ignoring failures during error unwinding.
  static void _discard(File staging) {
    if (!staging.existsSync()) return;
    try {
      staging.deleteSync();
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

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../async/cancellation_token.dart';
import '../cli/console.dart';
import '../core/core.dart';

final _invalidPathChars = RegExp(r'[:*?"<>|\r\n\t]');
final _whitespaceCollapse = RegExp(r'\s+');

/// Represents the type of filesystem entity at a [Path].
///
/// {@category Files}
enum PathType { file, dir, link, none }

/// Progress state for an individual file download.
///
/// {@category Files}
class DownloadProgress {
  /// The source URL being downloaded.
  final Uri url;

  /// The destination path on disk.
  final Path path;

  /// Number of bytes received so far.
  final int received;

  /// Total expected bytes from Content-Length header, or `null` if unknown.
  final int? total;

  /// Whether the download has finished (either saved to disk, skipped, or failed).
  final bool isDone;

  /// Whether the download was skipped because the file already exists and overwrite is false.
  final bool isSkipped;

  /// Whether the download failed (e.g. 404, short read, or connection error).
  final bool isFailed;

  /// Optional error object if the download failed.
  final Object? error;

  const DownloadProgress({
    required this.url,
    required this.path,
    this.received = 0,
    this.total,
    this.isDone = false,
    this.isSkipped = false,
    this.isFailed = false,
    this.error,
  });

  /// Progress ratio from 0.0 to 1.0, or `null` if total content length is unknown.
  double? get ratio => (total != null && total! > 0) ? (received / total!).clamp(0.0, 1.0) : null;

  /// Progress percentage from 0 to 100, or `null` if total content length is unknown.
  int? get percent => ratio != null ? (ratio! * 100).round() : null;

  @override
  String toString() =>
      'DownloadProgress(path: $path, received: $received, total: $total, isDone: $isDone, isSkipped: $isSkipped, isFailed: $isFailed)';
}

/// Aggregated progress state during batch file downloads.
///
/// {@category Files}
class BatchDownloadProgress {
  /// Total number of files completed so far (downloaded + skipped + failed).
  final int completed;

  /// Total count of files in the batch.
  final int total;

  /// Number of files newly downloaded (not skipped).
  final int newDownloads;

  /// The current file's progress update.
  final DownloadProgress current;

  const BatchDownloadProgress({
    required this.completed,
    required this.total,
    required this.newDownloads,
    required this.current,
  });

  /// Overall completion ratio from 0.0 to 1.0.
  double get ratio => total > 0 ? (completed / total).clamp(0.0, 1.0) : 1.0;

  /// Overall completion percentage from 0 to 100.
  int get percent => (ratio * 100).round();

  @override
  String toString() =>
      'BatchDownloadProgress(completed: $completed/$total, newDownloads: $newDownloads, current: $current)';
}

/// Adapter extension bridging [BatchDownloadProgress] to [ConsoleMultiProgress].
///
/// {@category Files}
extension BatchDownloadProgressMultiProgressExtension on ConsoleMultiProgress {
  /// Updates multi-progress from a [BatchDownloadProgress] event.
  void update(BatchDownloadProgress progress) {
    setCompleted(progress.completed);
    final cur = progress.current;
    final status = cur.isSkipped
        ? 'skipped'
        : cur.isFailed
        ? 'failed'
        : (cur.isDone ? 'done' : null);

    updateTask(
      cur.path.path,
      label: cur.path.name,
      ratio: cur.ratio,
      received: cur.received,
      total: cur.total,
      status: status,
      isDone: cur.isDone,
    );
  }
}

/// A path representation on top of [String] with canonical normalization and filesystem helpers.
///
/// {@category Files}
extension type const Path(String path) implements String {
  /// The user's home directory.
  static Path get home =>
      Path(Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.current.path);

  /// The system temporary directory.
  static Path get temp => Path(Directory.systemTemp.path);

  /// The current working directory.
  static Path get current => Path(Directory.current.path);

  /// Appends [part] to this path.
  Path operator /(String part) => Path(p.join(path, part));

  /// The canonical form of this path, with `.` and `..` segments resolved.
  ///
  /// `Path` is an extension type over [String] and so cannot override `==`:
  /// `Path('/a/b/../b')` and `Path('/a/b')` are distinct map keys. **Normalize at
  /// map boundaries** — `map[p.normalized]` — to make them coincide.
  Path get normalized => Path(p.normalize(path));

  /// The final component of this path (e.g. `'song.mp3'` or `'folder'`).
  String get name => p.basename(path);

  /// The final component without its file extension (e.g. `'song'` from `'song.mp3'`).
  String get stem => p.basenameWithoutExtension(path);

  /// The file extension without leading dot (e.g. `'mp3'` from `'song.mp3'`), or empty string.
  String get ext {
    final e = p.extension(path);
    return e.startsWith('.') ? e.substring(1) : e;
  }

  /// The parent directory as a [Path].
  Path get parent => Path(p.dirname(path));

  /// The individual path segments.
  List<String> get segments => p.split(path);

  /// This path as a [Link]. See [links] for the links *inside* this directory.
  Link get asLink => Link(path);

  /// This path as a [File]. See [files] for the files *inside* this directory.
  File get asFile => File(path);

  /// This path as a [Directory]. See [dirs] for the directories *inside* it.
  Directory get asDir => Directory(path);

  /// Returns the current entity type.
  Future<PathType> type() async {
    final entityType = await FileSystemEntity.type(path, followLinks: false);
    return switch (entityType) {
      FileSystemEntityType.file => PathType.file,
      FileSystemEntityType.directory => PathType.dir,
      FileSystemEntityType.link => PathType.link,
      _ => PathType.none,
    };
  }

  /// Checks if this path exists on disk.
  Future<bool> exists() async {
    final t = await FileSystemEntity.type(path, followLinks: false);
    return t != FileSystemEntityType.notFound;
  }

  /// Returns the current entity type synchronously.
  PathType typeSync() {
    final entityType = FileSystemEntity.typeSync(path, followLinks: false);
    return switch (entityType) {
      FileSystemEntityType.file => PathType.file,
      FileSystemEntityType.directory => PathType.dir,
      FileSystemEntityType.link => PathType.link,
      _ => PathType.none,
    };
  }

  /// Checks synchronously if this path exists on disk.
  bool existsSync() {
    final t = FileSystemEntity.typeSync(path, followLinks: false);
    return t != FileSystemEntityType.notFound;
  }

  /// Calculates the file size or recursive directory size in bytes.
  Future<int> size() async {
    final t = await type();
    if (t == PathType.file) {
      return (await asFile.stat()).size;
    } else if (t == PathType.dir) {
      var total = 0;
      await for (final entity in asDir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          total += entity.lengthSync();
        }
      }
      return total;
    }
    return 0;
  }

  /// Calculates the file size or recursive directory size in bytes synchronously.
  int sizeSync() {
    final t = typeSync();
    if (t == PathType.file) {
      return asFile.lengthSync();
    } else if (t == PathType.dir) {
      var total = 0;
      for (final entity in asDir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          total += entity.lengthSync();
        }
      }
      return total;
    }
    return 0;
  }

  /// Returns a sanitized path with invalid filesystem characters removed from components.
  Path sanitized() {
    final parts = p.split(path);
    final sanitizedParts = parts.map((part) {
      if (part == '/' || part == '\\' || part.endsWith(':')) return part;
      return part.replaceAll(_invalidPathChars, '_').replaceAll(_whitespaceCollapse, ' ').trim();
    });
    return Path(p.joinAll(sanitizedParts));
  }

  /// Reads this file as a string.
  Future<String> readText([Encoding encoding = utf8]) => asFile.readAsString(encoding: encoding);

  /// Reads this file as a string synchronously.
  String readTextSync([Encoding encoding = utf8]) => asFile.readAsStringSync(encoding: encoding);

  /// Reads this file as raw bytes.
  Future<Uint8List> readBytes() => asFile.readAsBytes();

  /// Reads this file as raw bytes synchronously.
  Uint8List readBytesSync() => asFile.readAsBytesSync();

  /// Reads this file as a list of lines.
  Future<List<String>> readLines([Encoding encoding = utf8]) => asFile.readAsLines(encoding: encoding);

  /// Reads this file as a list of lines synchronously.
  List<String> readLinesSync([Encoding encoding = utf8]) => asFile.readAsLinesSync(encoding: encoding);

  /// Reads this file and parses it as a [JsonDocument].
  Future<JsonDocument> readJson() async => JsonDocument.parse(await readText());

  /// Reads this file and parses it as a [JsonDocument] synchronously.
  JsonDocument readJsonSync() => JsonDocument.parse(readTextSync());

  /// Reads this file and parses it as an [HtmlDocument].
  Future<HtmlDocument> readHtml([Encoding encoding = utf8]) async => HtmlDocument.parse(await readText(encoding));

  /// Reads this file and parses it as an [HtmlDocument] synchronously.
  HtmlDocument readHtmlSync([Encoding encoding = utf8]) => HtmlDocument.parse(readTextSync(encoding));

  /// Reads this file and parses it as an [XmlDocument].
  Future<XmlDocument> readXml([Encoding encoding = utf8]) async => XmlDocument.parse(await readText(encoding));

  /// Reads this file and parses it as an [XmlDocument] synchronously.
  XmlDocument readXmlSync([Encoding encoding = utf8]) => XmlDocument.parse(readTextSync(encoding));

  /// Writes [content] string to this file, creating parent directories if not present.
  Future<File> writeText(String content, {Encoding encoding = utf8}) async {
    await asFile.parent.create(recursive: true);
    return asFile.writeAsString(content, encoding: encoding);
  }

  /// Writes [content] string to this file synchronously, creating parent directories if not present.
  File writeTextSync(String content, {Encoding encoding = utf8}) {
    asFile.parent.createSync(recursive: true);
    asFile.writeAsStringSync(content, encoding: encoding);
    return asFile;
  }

  /// Writes raw [bytes] to this file, creating parent directories if not present.
  Future<File> writeBytes(List<int> bytes) async {
    await asFile.parent.create(recursive: true);
    return asFile.writeAsBytes(bytes);
  }

  /// Writes raw [bytes] to this file synchronously, creating parent directories if not present.
  File writeBytesSync(List<int> bytes) {
    asFile.parent.createSync(recursive: true);
    asFile.writeAsBytesSync(bytes);
    return asFile;
  }

  /// Writes [lines] to this file separated by newlines, creating parent directories if not present.
  Future<File> writeLines(Iterable<String> lines, {Encoding encoding = utf8}) async {
    await asFile.parent.create(recursive: true);
    return asFile.writeAsString(lines.map((l) => '$l\n').join(), encoding: encoding);
  }

  /// Writes [lines] to this file separated by newlines synchronously, creating parent directories if not present.
  File writeLinesSync(Iterable<String> lines, {Encoding encoding = utf8}) {
    asFile.parent.createSync(recursive: true);
    asFile.writeAsStringSync(lines.map((l) => '$l\n').join(), encoding: encoding);
    return asFile;
  }

  /// Serializes [data] to JSON and writes to this file, creating parent directories if not present.
  Future<File> writeJson(Object? data, {bool pretty = false, Encoding encoding = utf8}) async {
    final encoder = pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
    return writeText(encoder.convert(data), encoding: encoding);
  }

  /// Serializes [data] to JSON and writes to this file synchronously, creating parent directories if not present.
  File writeJsonSync(Object? data, {bool pretty = false, Encoding encoding = utf8}) {
    final encoder = pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
    return writeTextSync(encoder.convert(data), encoding: encoding);
  }

  /// Writes [content] HTML to this file, creating parent directories if not present.
  Future<File> writeHtml(Object content, {Encoding encoding = utf8}) =>
      writeText(content is HtmlDocument ? content.document.outerHtml : content.toString(), encoding: encoding);

  /// Writes [content] HTML to this file synchronously, creating parent directories if not present.
  File writeHtmlSync(Object content, {Encoding encoding = utf8}) =>
      writeTextSync(content is HtmlDocument ? content.document.outerHtml : content.toString(), encoding: encoding);

  /// Writes [content] XML to this file, creating parent directories if not present.
  Future<File> writeXml(Object content, {Encoding encoding = utf8}) =>
      writeText(content is XmlDocument ? content.raw.toXmlString() : content.toString(), encoding: encoding);

  /// Writes [content] XML to this file synchronously, creating parent directories if not present.
  File writeXmlSync(Object content, {Encoding encoding = utf8}) =>
      writeTextSync(content is XmlDocument ? content.raw.toXmlString() : content.toString(), encoding: encoding);

  /// Lists all entities in this directory.
  Stream<Path> list({bool recursive = false, bool followLinks = false}) =>
      asDir.list(recursive: recursive, followLinks: followLinks).map((e) => Path(e.path));

  /// Lists all entities in this directory synchronously.
  List<Path> listSync({bool recursive = false, bool followLinks = false}) =>
      asDir.listSync(recursive: recursive, followLinks: followLinks).map((e) => Path(e.path)).toList();

  /// Lists only files located in this directory.
  Stream<Path> files({bool recursive = false}) =>
      asDir.list(recursive: recursive, followLinks: false).where((e) => e is File).map((e) => Path(e.path));

  /// Lists only files located in this directory synchronously.
  List<Path> filesSync({bool recursive = false}) =>
      asDir.listSync(recursive: recursive, followLinks: false).whereType<File>().map((e) => Path(e.path)).toList();

  /// Lists only subdirectories located in this directory.
  Stream<Path> dirs({bool recursive = false}) =>
      asDir.list(recursive: recursive, followLinks: false).where((e) => e is Directory).map((e) => Path(e.path));

  /// Lists only subdirectories located in this directory synchronously.
  List<Path> dirsSync({bool recursive = false}) =>
      asDir.listSync(recursive: recursive, followLinks: false).whereType<Directory>().map((e) => Path(e.path)).toList();

  /// Lists only symbolic links located in this directory.
  Stream<Path> links({bool recursive = false}) =>
      asDir.list(recursive: recursive, followLinks: false).where((e) => e is Link).map((e) => Path(e.path));

  /// Lists only symbolic links located in this directory synchronously.
  List<Path> linksSync({bool recursive = false}) =>
      asDir.listSync(recursive: recursive, followLinks: false).whereType<Link>().map((e) => Path(e.path)).toList();

  /// Streams paths matching [pattern] (glob syntax, e.g. `'**/*.mp3'` or `'**/flac'`).
  ///
  /// Defaults to platform case sensitivity (case-sensitive on Linux, insensitive on Windows/macOS).
  /// Pass [caseSensitive] to override.
  Stream<Path> glob(String pattern, {bool? caseSensitive}) async* {
    final matcher = _globToRegex(pattern, caseSensitive: caseSensitive);
    await for (final entity in asDir.list(recursive: true, followLinks: false)) {
      final rel = p.relative(entity.path, from: path).replaceAll(r'\', '/');
      if (matcher.hasMatch(rel) || matcher.hasMatch(entity.path.replaceAll(r'\', '/'))) {
        yield Path(entity.path);
      }
    }
  }

  /// Lists paths matching [pattern] synchronously (glob syntax, e.g. `'**/*.mp3'` or `'**/flac'`).
  ///
  /// Defaults to platform case sensitivity (case-sensitive on Linux, insensitive on Windows/macOS).
  /// Pass [caseSensitive] to override.
  List<Path> globSync(String pattern, {bool? caseSensitive}) {
    final matcher = _globToRegex(pattern, caseSensitive: caseSensitive);
    final results = <Path>[];
    for (final entity in asDir.listSync(recursive: true, followLinks: false)) {
      final rel = p.relative(entity.path, from: path).replaceAll(r'\', '/');
      if (matcher.hasMatch(rel) || matcher.hasMatch(entity.path.replaceAll(r'\', '/'))) {
        results.add(Path(entity.path));
      }
    }
    return results;
  }

  /// Downloads content from [url] atomically using a `.part` temporary file and streams [DownloadProgress] updates.
  ///
  /// - Downloads to `<filename>.part` and renames to final destination only upon successful full download.
  /// - Verifies `Content-Length` header; incomplete or short reads are treated as errors.
  /// - Deletes `.part` file on failure to prevent permanent corruption of future runs.
  /// - Supports [cancelToken] for graceful cooperative cancellation.
  Stream<DownloadProgress> download(
    Uri url, {
    http.Client? client,
    bool overwrite = false,
    CancellationToken? cancelToken,
  }) async* {
    if (!overwrite && await exists()) {
      yield DownloadProgress(url: url, path: this, isDone: true, isSkipped: true);
      return;
    }

    if (cancelToken != null && cancelToken.isCancelled) {
      yield DownloadProgress(
        url: url,
        path: this,
        isDone: true,
        isFailed: true,
        error: CancellationException(cancelToken.reason?.toString() ?? 'Download cancelled'),
      );
      return;
    }

    final httpClient = client ?? http.Client();
    final partFile = File('${asFile.path}.part');
    var received = 0;
    int? total;

    try {
      final request = http.Request('GET', url);
      final streamed = await httpClient.send(request);

      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        yield DownloadProgress(
          url: url,
          path: this,
          isDone: true,
          isFailed: true,
          error: HttpException('Download failed with status ${streamed.statusCode}', uri: url),
        );
        return;
      }

      final headerContentLength = streamed.headers['content-length'];
      total = streamed.contentLength ?? (headerContentLength != null ? int.tryParse(headerContentLength) : null);

      await partFile.parent.create(recursive: true);
      final sink = partFile.openWrite();

      try {
        await for (final chunk in streamed.stream) {
          if (cancelToken != null && cancelToken.isCancelled) {
            throw CancellationException(cancelToken.reason?.toString() ?? 'Download cancelled');
          }
          sink.add(chunk);
          received += chunk.length;
          yield DownloadProgress(
            url: url,
            path: this,
            received: received,
            total: total,
            isDone: false,
            isSkipped: false,
          );
        }
      } finally {
        await sink.close();
      }

      if (total != null && received != total) {
        throw HttpException('Download incomplete: expected $total bytes but received $received bytes', uri: url);
      }

      if (await asFile.exists()) {
        await asFile.delete();
      }
      await partFile.rename(asFile.path);

      yield DownloadProgress(
        url: url,
        path: this,
        received: received,
        total: total ?? received,
        isDone: true,
        isSkipped: false,
      );
    } catch (e) {
      if (await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
      yield DownloadProgress(
        url: url,
        path: this,
        received: received,
        total: total ?? received,
        isDone: true,
        isFailed: true,
        error: e,
      );
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Creates a directory at this path.
  Future<Directory> mkdir({bool recursive = true}) => asDir.create(recursive: recursive);

  /// Creates a directory at this path synchronously.
  Directory mkdirSync({bool recursive = true}) {
    asDir.createSync(recursive: recursive);
    return asDir;
  }

  /// Creates a symlink at this path pointing to [target].
  Future<Link> symlink(String target) async {
    await asLink.parent.create(recursive: true);
    return asLink.create(target);
  }

  /// Creates a symlink at this path pointing to [target] synchronously.
  Link symlinkSync(String target) {
    asLink.parent.createSync(recursive: true);
    asLink.createSync(target);
    return asLink;
  }

  /// Copies this file or directory to [targetPath].
  Future<void> copy(String targetPath) async {
    final t = await type();
    if (t == PathType.file) {
      final dest = File(targetPath);
      await dest.parent.create(recursive: true);
      await asFile.copy(targetPath);
    } else if (t == PathType.dir) {
      await for (final entity in asDir.list(recursive: true, followLinks: false)) {
        final rel = p.relative(entity.path, from: path);
        final dest = p.join(targetPath, rel);
        if (entity is Directory) {
          await Directory(dest).create(recursive: true);
        } else if (entity is File) {
          await File(dest).parent.create(recursive: true);
          await entity.copy(dest);
        }
      }
    } else {
      throw FileSystemException('Cannot copy non-existent path', path);
    }
  }

  /// Copies this file or directory to [targetPath] synchronously.
  void copySync(String targetPath) {
    final t = typeSync();
    if (t == PathType.file) {
      final dest = File(targetPath);
      dest.parent.createSync(recursive: true);
      asFile.copySync(targetPath);
    } else if (t == PathType.dir) {
      for (final entity in asDir.listSync(recursive: true, followLinks: false)) {
        final rel = p.relative(entity.path, from: path);
        final dest = p.join(targetPath, rel);
        if (entity is Directory) {
          Directory(dest).createSync(recursive: true);
        } else if (entity is File) {
          File(dest).parent.createSync(recursive: true);
          entity.copySync(dest);
        }
      }
    } else {
      throw FileSystemException('Cannot copy non-existent path', path);
    }
  }

  /// Moves this file or directory to [targetPath].
  Future<void> move(String targetPath) async {
    final dest = File(targetPath);
    await dest.parent.create(recursive: true);
    final t = await type();
    if (t == PathType.file) {
      await asFile.rename(targetPath);
    } else if (t == PathType.dir) {
      await asDir.rename(targetPath);
    } else {
      throw FileSystemException('Cannot move non-existent path', path);
    }
  }

  /// Moves this file or directory to [targetPath] synchronously.
  void moveSync(String targetPath) {
    final dest = File(targetPath);
    dest.parent.createSync(recursive: true);
    final t = typeSync();
    if (t == PathType.file) {
      asFile.renameSync(targetPath);
    } else if (t == PathType.dir) {
      asDir.renameSync(targetPath);
    } else {
      throw FileSystemException('Cannot move non-existent path', path);
    }
  }

  /// Deletes this file, directory, or asLink.
  Future<void> delete({bool recursive = false}) async {
    final t = await type();
    if (t == PathType.file) {
      await asFile.delete();
    } else if (t == PathType.dir) {
      await asDir.delete(recursive: recursive);
    } else if (t == PathType.link) {
      await asLink.delete();
    }
  }

  /// Deletes this file, directory, or link synchronously.
  void deleteSync({bool recursive = false}) {
    final t = typeSync();
    if (t == PathType.file) {
      asFile.deleteSync();
    } else if (t == PathType.dir) {
      asDir.deleteSync(recursive: recursive);
    } else if (t == PathType.link) {
      asLink.deleteSync();
    }
  }

  /// Compresses this directory or file into a zip archive at [destination].
  Future<File> zipTo(String destination) async {
    final targetPath = destination;
    final zipFile = File(targetPath);
    await zipFile.parent.create(recursive: true);
    final encoder = ZipFileEncoder();
    final t = await type();
    if (t == PathType.dir) {
      await encoder.zipDirectory(asDir, filename: targetPath);
    } else {
      encoder.create(targetPath);
      await encoder.addFile(asFile);
      encoder.close();
    }
    return zipFile;
  }

  /// Compresses this directory or file into a zip archive at [destination] synchronously.
  File zipToSync(String destination) {
    final targetPath = destination;
    final zipFile = File(targetPath);
    zipFile.parent.createSync(recursive: true);
    final encoder = ZipFileEncoder();
    final t = typeSync();
    if (t == PathType.dir) {
      encoder.create(targetPath);
      for (final entity in asDir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          final rel = p.relative(entity.path, from: path);
          final bytes = entity.readAsBytesSync();
          encoder.addArchiveFile(ArchiveFile(rel, bytes.length, bytes));
        }
      }
      encoder.close();
    } else {
      encoder.create(targetPath);
      final bytes = asFile.readAsBytesSync();
      encoder.addArchiveFile(ArchiveFile(p.basename(asFile.path), bytes.length, bytes));
      encoder.close();
    }
    return zipFile;
  }

  /// Extracts the archive at this path into [destination].
  Future<Directory> extractTo(String destination) async {
    final destPath = destination;
    final dest = Directory(destPath);
    await dest.create(recursive: true);
    final bytes = await readBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entity in archive) {
      final outPath = p.join(destPath, entity.name);
      if (entity.isFile) {
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(entity.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
    return dest;
  }

  /// Extracts the archive at this path into [destination] synchronously.
  Directory extractToSync(String destination) {
    final destPath = destination;
    final dest = Directory(destPath);
    dest.createSync(recursive: true);
    final bytes = readBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entity in archive) {
      final outPath = p.join(destPath, entity.name);
      if (entity.isFile) {
        final outFile = File(outPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(entity.content as List<int>);
      } else {
        Directory(outPath).createSync(recursive: true);
      }
    }
    return dest;
  }

  /// Calculates the SHA-256 cryptographic hash of this asFile.
  Future<String> sha256() async {
    final bytes = await readBytes();
    return crypto.sha256.convert(bytes).toString();
  }

  /// Calculates the SHA-256 cryptographic hash of this file synchronously.
  String sha256Sync() {
    final bytes = readBytesSync();
    return crypto.sha256.convert(bytes).toString();
  }

  /// Calculates the MD5 cryptographic hash of this asFile.
  Future<String> md5() async {
    final bytes = await readBytes();
    return crypto.md5.convert(bytes).toString();
  }

  /// Calculates the MD5 cryptographic hash of this file synchronously.
  String md5Sync() {
    final bytes = readBytesSync();
    return crypto.md5.convert(bytes).toString();
  }

  /// Appends [content] to this file, creating parent directories and file if not present.
  Future<File> append(String content, {Encoding encoding = utf8}) async {
    await asFile.parent.create(recursive: true);
    return asFile.writeAsString(content, mode: FileMode.append, encoding: encoding);
  }

  /// Appends [content] to this file synchronously, creating parent directories and file if not present.
  File appendSync(String content, {Encoding encoding = utf8}) {
    asFile.parent.createSync(recursive: true);
    asFile.writeAsStringSync(content, mode: FileMode.append, encoding: encoding);
    return asFile;
  }

  /// Rewrites this file, replacing occurrences of [from] with [replacement].
  ///
  /// Writes to disk. The inherited [String.replaceAll] operates on the path text.
  Future<File> replaceInFile(Pattern from, String replacement, {Encoding encoding = utf8}) async {
    final text = await readText(encoding);
    return writeText(text.replaceAll(from, replacement), encoding: encoding);
  }

  /// Rewrites this file synchronously, replacing occurrences of [from] with [replacement].
  File replaceInFileSync(Pattern from, String replacement, {Encoding encoding = utf8}) {
    final text = readTextSync(encoding);
    return writeTextSync(text.replaceAll(from, replacement), encoding: encoding);
  }

  /// Watches this file or directory for filesystem changes.
  Stream<FileSystemEvent> watch({bool recursive = false, int events = FileSystemEvent.all}) =>
      asFile.watch(recursive: recursive, events: events);
}

/// Convenience extension on [String] to convert to [Path] or join paths.
///
/// {@category Files}
extension StringPathExtensions on String {
  /// Wraps this string into a [Path].
  Path get path => Path(this);

  /// Joins this path with [other].
  Path operator /(String other) => Path(this) / other;
}

RegExp _globToRegex(String pattern, {bool? caseSensitive}) {
  final normalized = pattern.replaceAll(r'\', '/');
  final buffer = StringBuffer('^');
  var i = 0;
  while (i < normalized.length) {
    final c = normalized[i];
    if (c == '*' && i + 1 < normalized.length && normalized[i + 1] == '*') {
      if (i + 2 < normalized.length && normalized[i + 2] == '/') {
        buffer.write('(?:.+/)?');
        i += 3;
        continue;
      } else {
        buffer.write('.*');
        i += 2;
        continue;
      }
    } else if (c == '*') {
      buffer.write('[^/]*');
    } else if (c == '?') {
      buffer.write('[^/]');
    } else if (r'.+()^$[]{}|'.contains(c)) {
      buffer.write('\\$c');
    } else {
      buffer.write(c);
    }
    i++;
  }
  buffer.write(r'$');
  final isSensitive = caseSensitive ?? (!Platform.isWindows && !Platform.isMacOS);
  return RegExp(buffer.toString(), caseSensitive: isSensitive);
}

Stream<BatchDownloadProgress> _batchDownload(
  Iterable<({Path path, Uri url})> pairs, {
  http.Client? client,
  int concurrency = 4,
  bool overwrite = false,
  CancellationToken? cancelToken,
}) async* {
  final items = pairs.toList();
  final totalFiles = items.length;
  if (totalFiles == 0) return;

  var completedCount = 0;
  var newCount = 0;
  final httpClient = client ?? http.Client();

  final controller = StreamController<BatchDownloadProgress>();
  final limit = concurrency > 0 ? concurrency : 1;
  final queue = Queue<({Path path, Uri url})>.from(items);
  final active = <Future<void>>{};

  void schedule() {
    if (controller.isClosed || (cancelToken != null && cancelToken.isCancelled)) return;

    while (queue.isNotEmpty && active.length < limit) {
      final item = queue.removeFirst();

      late final Future<void> task;
      task = Future<void>(() async {
        try {
          if (cancelToken != null && cancelToken.isCancelled) return;
          await for (final p in item.path.download(
            item.url,
            client: httpClient,
            overwrite: overwrite,
            cancelToken: cancelToken,
          )) {
            if (p.isDone) {
              completedCount++;
              if (!p.isSkipped && !p.isFailed) newCount++;
            }
            if (!controller.isClosed) {
              controller.add(
                BatchDownloadProgress(completed: completedCount, total: totalFiles, newDownloads: newCount, current: p),
              );
            }
          }
        } catch (e) {
          completedCount++;
          if (!controller.isClosed) {
            controller.add(
              BatchDownloadProgress(
                completed: completedCount,
                total: totalFiles,
                newDownloads: newCount,
                current: DownloadProgress(url: item.url, path: item.path, isDone: true, isFailed: true, error: e),
              ),
            );
          }
        } finally {
          active.remove(task);
          if (queue.isEmpty && active.isEmpty && !controller.isClosed) {
            if (client == null) httpClient.close();
            controller.close();
          } else {
            schedule();
          }
        }
      });
      active.add(task);
    }

    if (queue.isEmpty && active.isEmpty && !controller.isClosed) {
      if (client == null) httpClient.close();
      controller.close();
    }
  }

  controller.onListen = () {
    cancelToken?.onCancel(() {
      if (!controller.isClosed) {
        controller.close();
      }
    });
    schedule();
  };
  yield* controller.stream;
}

/// Batch download extensions on [Map<Path, Uri>].
///
/// {@category Files}
extension PathUriMapDownloadExtensions on Map<Path, Uri> {
  /// Downloads all path-URL pairs concurrently and streams [BatchDownloadProgress] updates.
  Stream<BatchDownloadProgress> downloadAll({
    http.Client? client,
    int concurrency = 4,
    bool overwrite = false,
    CancellationToken? cancelToken,
  }) => _batchDownload(
    entries.map((e) => (path: e.key, url: e.value)),
    client: client,
    concurrency: concurrency,
    overwrite: overwrite,
    cancelToken: cancelToken,
  );
}

/// Batch download extensions on [Map<Uri, Path>].
///
/// {@category Files}
extension UriPathMapDownloadExtensions on Map<Uri, Path> {
  /// Downloads all URL-path pairs concurrently and streams [BatchDownloadProgress] updates.
  Stream<BatchDownloadProgress> downloadAll({
    http.Client? client,
    int concurrency = 4,
    bool overwrite = false,
    CancellationToken? cancelToken,
  }) => _batchDownload(
    entries.map((e) => (path: e.value, url: e.key)),
    client: client,
    concurrency: concurrency,
    overwrite: overwrite,
    cancelToken: cancelToken,
  );
}

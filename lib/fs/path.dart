import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/core.dart';

/// Represents the type of filesystem entity at a [Path].
enum PathType { file, dir, link, none }

/// Progress state for an individual file download.
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

  /// Whether the download failed (e.g. 404 or connection error).
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
class BatchDownloadProgress {
  /// Total number of files completed so far (downloaded + skipped).
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

/// A zero-allocation path representation on top of [String].
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

  /// Returns a [Link] pointing to this path.
  Link get link => Link(path);

  /// Returns a [File] pointing to this path.
  File get file => File(path);

  /// Returns a [Directory] pointing to this path.
  Directory get dir => Directory(path);

  /// Returns the current entity type.
  Future<PathType> type() async {
    final entityType = await FileSystemEntity.type(path, followLinks: false);
    return switch (entityType) {
      .file => .file,
      .directory => .dir,
      .link => .link,
      _ => .none,
    };
  }

  /// Checks if this path exists on disk.
  Future<bool> exist() async {
    final t = await FileSystemEntity.type(path, followLinks: false);
    return t != .notFound;
  }

  /// Calculates the file size or recursive directory size in bytes.
  Future<int> size() async {
    final t = await type();
    if (t == .file) {
      return (await file.stat()).size;
    } else if (t == .dir) {
      var total = 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          total += (await entity.stat()).size;
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
      return part.replaceAll(RegExp(r'[:*?"<>|\r\n\t]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
    });
    return Path(p.joinAll(sanitizedParts));
  }

  /// Reads this file as a string.
  Future<String> readText([Encoding encoding = utf8]) => file.readAsString(encoding: encoding);

  /// Reads this file as raw bytes.
  Future<Uint8List> readBytes() => file.readAsBytes();

  /// Reads this file as a list of lines.
  Future<List<String>> readLines([Encoding encoding = utf8]) => file.readAsLines(encoding: encoding);

  /// Reads this file and parses it as a [JsonDocument].
  Future<JsonDocument> readJson() async => JsonDocument.parse(await readText());

  /// Reads this file and parses it as an [HtmlDocument].
  Future<HtmlDocument> readHtml([Encoding encoding = utf8]) async =>
      HtmlDocument.parse(await readText(encoding));

  /// Reads this file and parses it as an [XmlDocument].
  Future<XmlDocument> readXml([Encoding encoding = utf8]) async =>
      XmlDocument.parse(await readText(encoding));

  /// Writes [content] to this file, creating parent directories if needed.
  Future<File> writeText(String content, {Encoding encoding = utf8}) async {
    await file.parent.create(recursive: true);
    return file.writeAsString(content, encoding: encoding);
  }

  /// Writes [bytes] to this file, creating parent directories if needed.
  Future<File> writeBytes(Iterable<int> bytes) async {
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes is List<int> ? bytes : bytes.toList());
  }

  /// Writes [lines] to this file, creating parent directories if needed.
  Future<File> writeLines(Iterable<String> lines, {Encoding encoding = utf8}) async {
    await file.parent.create(recursive: true);
    return file.writeAsString(lines.join('\n'), encoding: encoding);
  }

  /// Serializes and writes [data] as JSON and returns a [JsonDocument].
  Future<JsonDocument> writeJson(Object? data) async {
    await writeText(jsonEncode(data));
    return JsonDocument(data);
  }

  /// Serializes and writes [doc] as HTML, creating parent directories if needed.
  Future<HtmlDocument> writeHtml(HtmlDocument doc, {Encoding encoding = utf8}) async {
    await writeText(doc.document.outerHtml, encoding: encoding);
    return doc;
  }

  /// Serializes and writes [doc] as XML, creating parent directories if needed.
  Future<XmlDocument> writeXml(XmlDocument doc, {Encoding encoding = utf8}) async {
    await writeText(doc.raw.toXmlString(pretty: true), encoding: encoding);
    return doc;
  }

  /// Lists filesystem entities in this directory as a stream of [Path] objects.
  Stream<Path> list({bool recursive = false, bool followLinks = false}) async* {
    await for (final entity in dir.list(recursive: recursive, followLinks: followLinks)) {
      yield Path(entity.path);
    }
  }

  /// Streams only files located in this directory.
  Stream<Path> files({bool recursive = false, bool followLinks = false}) async* {
    await for (final entity in dir.list(recursive: recursive, followLinks: followLinks)) {
      if (entity is File) {
        yield Path(entity.path);
      }
    }
  }

  /// Streams only directories located in this directory.
  Stream<Path> dirs({bool recursive = false, bool followLinks = false}) async* {
    await for (final entity in dir.list(recursive: recursive, followLinks: followLinks)) {
      if (entity is Directory) {
        yield Path(entity.path);
      }
    }
  }

  /// Streams only symbolic links located in this directory.
  Stream<Path> links({bool recursive = false}) async* {
    await for (final entity in dir.list(recursive: recursive, followLinks: false)) {
      if (entity is Link) {
        yield Path(entity.path);
      }
    }
  }

  /// Streams paths matching [pattern] (glob syntax, e.g. `'**/*.mp3'` or `'**/flac'`).
  Stream<Path> glob(String pattern) async* {
    final matcher = _globToRegex(pattern);
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      final rel = p.relative(entity.path, from: path).replaceAll(r'\', '/');
      if (matcher.hasMatch(rel) || matcher.hasMatch(entity.path.replaceAll(r'\', '/'))) {
        yield Path(entity.path);
      }
    }
  }

  /// Downloads content from [url] and streams [DownloadProgress] updates.
  Stream<DownloadProgress> download(Uri url, {http.Client? client, bool overwrite = false}) async* {
    if (!overwrite && await exist()) {
      yield DownloadProgress(url: url, path: this, isDone: true, isSkipped: true);
      return;
    }

    final httpClient = client ?? http.Client();
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

      final total = streamed.contentLength;
      var received = 0;

      await file.parent.create(recursive: true);
      final sink = file.openWrite();

      try {
        await for (final chunk in streamed.stream) {
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

      yield DownloadProgress(
        url: url,
        path: this,
        received: received,
        total: total ?? received,
        isDone: true,
        isSkipped: false,
      );
    } catch (e) {
      yield DownloadProgress(
        url: url,
        path: this,
        isDone: true,
        isFailed: true,
        error: e,
      );
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Creates a directory at this path.
  Future<Directory> mkdir({bool recursive = true}) => dir.create(recursive: recursive);

  /// Creates a symlink at this path pointing to [target].
  Future<Link> mklink(String target) async {
    await link.parent.create(recursive: true);
    return link.create(target);
  }

  /// Copies this file or directory to [targetPath].
  Future<void> copy(String targetPath) async {
    final t = await type();
    if (t == .file) {
      final dest = File(targetPath);
      await dest.parent.create(recursive: true);
      await file.copy(targetPath);
    } else if (t == .dir) {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        final rel = p.relative(entity.path, from: path);
        final dest = p.join(targetPath, rel);
        if (entity is Directory) {
          await Directory(dest).create(recursive: true);
        } else if (entity is File) {
          await File(dest).parent.create(recursive: true);
          await entity.copy(dest);
        }
      }
    }
  }

  /// Moves this file or directory to [targetPath].
  Future<void> move(String targetPath) async {
    final dest = File(targetPath);
    await dest.parent.create(recursive: true);
    final t = await type();
    if (t == .file) {
      await file.rename(targetPath);
    } else if (t == .dir) {
      await dir.rename(targetPath);
    }
  }

  /// Deletes this file, directory, or link.
  Future<void> delete({bool recursive = false}) async {
    final t = await type();
    if (t == .file) {
      await file.delete();
    } else if (t == .dir) {
      await dir.delete(recursive: recursive);
    } else if (t == .link) {
      await link.delete();
    }
  }

  /// Compresses this directory or file into a zip file at [zipPath].
  Future<File> zip(String zipPath) async {
    final zipFile = File(zipPath);
    await zipFile.parent.create(recursive: true);
    final encoder = ZipFileEncoder();
    final t = await type();
    if (t == .dir) {
      encoder.zipDirectory(dir, filename: zipPath);
    } else {
      encoder.create(zipPath);
      encoder.addFile(file);
      encoder.close();
    }
    return zipFile;
  }

  /// Extracts the zip archive at this path into [targetDir].
  Future<Directory> unzip(String targetDir) async {
    final destination = Directory(targetDir);
    await destination.create(recursive: true);
    await extractFileToDisk(path, targetDir);
    return destination;
  }

  /// Calculates the SHA-256 cryptographic hash of this file.
  Future<String> sha256() async {
    final bytes = await readBytes();
    return crypto.sha256.convert(bytes).toString();
  }

  /// Calculates the MD5 cryptographic hash of this file.
  Future<String> md5() async {
    final bytes = await readBytes();
    return crypto.md5.convert(bytes).toString();
  }

  /// Appends [content] to this file, creating parent directories and file if not present.
  Future<File> append(String content, {Encoding encoding = utf8}) async {
    await file.parent.create(recursive: true);
    return file.writeAsString(content, mode: FileMode.append, encoding: encoding);
  }

  /// In-place replaces occurrences of [from] with [replacement] in this file.
  Future<File> replace(Pattern from, String replacement, {Encoding encoding = utf8}) async {
    final text = await readText(encoding);
    return writeText(text.replaceAll(from, replacement), encoding: encoding);
  }

  /// Watches this file or directory for filesystem changes.
  Stream<FileSystemEvent> watch({bool recursive = false, int events = FileSystemEvent.all}) =>
      file.watch(recursive: recursive, events: events);
}

/// Convenience extension on [String] to convert to [Path] or join paths.
extension PathStringExtension on String {
  /// Wraps this string into a [Path].
  Path get path => Path(this);

  /// Joins this path with [other].
  Path operator /(String other) => Path(this) / other;
}

RegExp _globToRegex(String pattern) {
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
  return RegExp(buffer.toString(), caseSensitive: false);
}

Stream<BatchDownloadProgress> _batchDownload(
  Iterable<({Path path, Uri url})> pairs, {
  http.Client? client,
  int concurrency = 4,
  bool overwrite = false,
}) async* {
  final items = pairs.toList();
  final totalFiles = items.length;
  if (totalFiles == 0) return;

  var completedCount = 0;
  var newCount = 0;
  final httpClient = client ?? http.Client();

  final controller = StreamController<BatchDownloadProgress>();
  final limit = concurrency > 0 ? concurrency : 1;
  final queue = List<({Path path, Uri url})>.from(items);
  final active = <Future<void>>{};

  void schedule() {
    if (controller.isClosed) return;

    while (queue.isNotEmpty && active.length < limit) {
      final item = queue.removeAt(0);

      late final Future<void> task;
      task = Future<void>(() async {
        try {
          await for (final p in item.path.download(item.url, client: httpClient, overwrite: overwrite)) {
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

  controller.onListen = schedule;
  yield* controller.stream;
}

/// Batch download extensions on [Map<Path, Uri>].
extension PathUriMapDownloadExtensions on Map<Path, Uri> {
  /// Downloads all path-URL pairs concurrently and streams [BatchDownloadProgress] updates.
  Stream<BatchDownloadProgress> downloadAll({
    http.Client? client,
    int concurrency = 4,
    bool overwrite = false,
  }) =>
      _batchDownload(
        entries.map((e) => (path: e.key, url: e.value)),
        client: client,
        concurrency: concurrency,
        overwrite: overwrite,
      );
}

/// Batch download extensions on [Map<Uri, Path>].
extension UriPathMapDownloadExtensions on Map<Uri, Path> {
  /// Downloads all URL-path pairs concurrently and streams [BatchDownloadProgress] updates.
  Stream<BatchDownloadProgress> downloadAll({
    http.Client? client,
    int concurrency = 4,
    bool overwrite = false,
  }) =>
      _batchDownload(
        entries.map((e) => (path: e.value, url: e.key)),
        client: client,
        concurrency: concurrency,
        overwrite: overwrite,
      );
}

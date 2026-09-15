import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../async/parallelize.dart';
import '../core/core.dart';

/// Represents the type of filesystem entity at a [Path].
enum PathType { file, dir, link, none }

/// A zero-allocation path representation on top of [String].
extension type const Path(String path) implements String {
  /// Appends [part] to this path.
  Path operator /(String part) => Path(p.join(path, part));

  /// Returns a [File] pointing to this path.
  File get file => File(path);

  /// Returns a [Directory] pointing to this path.
  Directory get dir => Directory(path);

  /// Returns a [Link] pointing to this path.
  Link get link => Link(path);

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
  Future<bool> exist() async {
    final t = await FileSystemEntity.type(path, followLinks: false);
    return t != FileSystemEntityType.notFound;
  }

  /// Calculates the file size or recursive directory size in bytes.
  Future<int> size() async {
    final t = await type();
    if (t == PathType.file) {
      return (await file.stat()).size;
    } else if (t == PathType.dir) {
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

  /// Downloads content from [url] and writes it to this path.
  ///
  /// Returns `true` if downloaded, or `false` if the file already exists (unless [overwrite] is true) or request failed.
  Future<bool> download(Uri url, {http.Client? client, bool overwrite = false}) async {
    if (!overwrite && await exist()) return false;
    final httpClient = client ?? http.Client();
    try {
      final res = await httpClient.get(url);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        await writeBytes(res.bodyBytes);
        return true;
      }
    } finally {
      if (client == null) httpClient.close();
    }
    return false;
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
    if (t == PathType.file) {
      final dest = File(targetPath);
      await dest.parent.create(recursive: true);
      await file.copy(targetPath);
    } else if (t == PathType.dir) {
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
    if (t == PathType.file) {
      await file.rename(targetPath);
    } else if (t == PathType.dir) {
      await dir.rename(targetPath);
    }
  }

  /// Deletes this file, directory, or link.
  Future<void> delete({bool recursive = false}) async {
    final t = await type();
    if (t == PathType.file) {
      await file.delete();
    } else if (t == PathType.dir) {
      await dir.delete(recursive: recursive);
    } else if (t == PathType.link) {
      await link.delete();
    }
  }

  /// Compresses this directory or file into a zip file at [zipPath].
  Future<File> zip(String zipPath) async {
    final zipFile = File(zipPath);
    await zipFile.parent.create(recursive: true);
    final encoder = ZipFileEncoder();
    final t = await type();
    if (t == PathType.dir) {
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
}

/// Convenience extension on [String] to convert to [Path] or join paths.
extension PathStringExtension on String {
  /// Wraps this string into a [Path].
  Path get path => Path(this);

  /// Joins this path with [other].
  Path operator /(String other) => Path(this) / other;
}

/// Batch download extensions on [Map<Path, Uri>].
extension PathUriMapDownloadExtensions on Map<Path, Uri> {
  /// Downloads all path-URL pairs concurrently and returns the count of new files downloaded.
  Future<int> downloadAll({http.Client? client, int concurrency = 4, bool overwrite = false}) async {
    final entriesList = entries.toList();
    var count = 0;
    final outcomes = await entriesList.parallelize((entry) async {
      return await entry.key.download(entry.value, client: client, overwrite: overwrite);
    }, concurrency: concurrency);
    for (final outcome in outcomes) {
      if (outcome case Right(:final value) when value) {
        count++;
      }
    }
    return count;
  }
}

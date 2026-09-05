import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../sys/sys.dart';
import 'archive.dart';

export 'archive.dart';

// ============================================================================
// FILESYSTEM, PATHS & STORAGE (fs.* / Fs.*)
// ============================================================================

/// Top-level filesystem and path manipulation accessor singleton.
///
/// Provides convenient, fluent access to atomic file writing, streaming downloads,
/// directory creation, file search, path utilities, and 7-Zip archiving:
/// ```dart
/// // Atomic file writing with .part protection
/// await fs.write('data/output.json', jsonString);
///
/// // Download streaming asset
/// await fs.download(Uri.parse('https://example.com/file.zip'), 'downloads/file.zip');
///
/// // Path helpers without extra imports
/// final full = fs.join('parent', 'child', 'file.txt');
/// final name = fs.name(full); // 'file'
/// final ext = fs.ext(full);   // '.txt'
/// ```
const FsAccessor fs = FsAccessor();

/// Filesystem and path namespace accessor.
class FsAccessor {
  const FsAccessor();

  /// Creates or manages an [Archive] for the specified file [path].
  ///
  /// ```dart
  /// final arch = fs.archive('backups/data.7z');
  /// await arch.sync('data/');
  /// ```
  Archive archive(String path) => Fs.archive(path);

  // --- Path utilities directly under fs namespace ---

  /// Safely joins path segments using the host platform's path separator.
  ///
  /// ```dart
  /// final p = fs.join('dir', 'subdir', 'file.txt');
  /// ```
  String join(
    String part1, [
    String? part2,
    String? part3,
    String? part4,
    String? part5,
    String? part6,
    String? part7,
    String? part8,
  ]) =>
      p.join(
        part1,
        part2,
        part3,
        part4,
        part5,
        part6,
        part7,
        part8,
      );

  /// Returns the basename of [path] (e.g. `'file.txt'` from `'/dir/file.txt'`).
  String base(String path) => p.basename(path);

  /// Returns the basename of [path] without its extension (e.g. `'file'` from `'/dir/file.txt'`).
  String name(String path) => p.basenameWithoutExtension(path);

  /// Returns the extension of [path] including the dot (e.g. `'.txt'` from `'/dir/file.txt'`).
  String ext(String path) => p.extension(path);

  /// Returns the directory component of [path] (e.g. `'/dir'` from `'/dir/file.txt'`).
  String dir(String path) => p.dirname(path);

  // --- File and directory operations ---

  /// Sanitizes a file or folder [name] to be valid across Windows, macOS, and Linux.
  ///
  /// Replaces illegal characters (`:`, `"`, `/`, `\`, `*`, `?`, `<`, `>`, `|`) with [replace],
  /// or with full-width equivalents if [full] is true.
  /// Strips control characters and trailing dots.
  ///
  /// ```dart
  /// final safe = fs.sanitize('AC/DC: Back in Black?.mp3'); // 'AC_DC_ Back in Black_.mp3'
  /// ```
  String sanitize(
    String name, {
    String replace = '_',
    bool full = false,
  }) =>
      Fs.sanitize(name, replace: replace, full: full);

  /// Formats byte count into a human-readable size string (e.g. `'1.5 MB'`, `'250 KB'`).
  String size(int bytes, {int decimals = 1}) =>
      Fs.size(bytes, decimals: decimals);

  /// Parses human-readable size strings (e.g. `'10MB'`, `'2.5 GB'`, `'500K'`) into bytes.
  int parse(String text) => Fs.parse(text);

  /// Formats a [Duration] into `mm:ss` or `hh:mm:ss` format.
  String time(Duration duration) => Fs.time(duration);

  /// Ensures that [path] exists as a directory, creating missing parent folders recursively.
  Future<Directory> mkdir(String path, {bool sync = false}) =>
      Fs.mkdir(path, sync: sync);

  /// Ensures the parent directory of [filePath] exists, creating it recursively if needed.
  void parent(String filePath) => Fs.parent(filePath);

  /// Checks whether [target] file exists and has non-zero byte size.
  ///
  /// If [match] is true, also checks whether a file with matching basename exists in the folder.
  bool has(dynamic target, {bool match = false}) =>
      Fs.has(target, match: match);

  /// Matches existing files in the directory by basename ignoring common prefix/suffix differences.
  bool match(dynamic target) => Fs.match(target);

  /// Writes string or byte [content] atomically to [target] with temporary `.part` tracking.
  ///
  /// If interrupted or aborted, partial files are automatically cleaned up.
  ///
  /// ```dart
  /// await fs.write('output.json', jsonEncode(data));
  /// ```
  Future<File> write(
    dynamic target,
    dynamic content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) {
    final file = target is File ? target : File(target.toString());
    return Fs.write(file, content, part: part, encoding: encoding);
  }

  /// Reads [target] file synchronously as a string with [encoding].
  String read(dynamic target, {Encoding encoding = utf8}) {
    final file = target is File ? target : File(target.toString());
    return file.readAsStringSync(encoding: encoding);
  }

  /// Reads [target] file synchronously as raw bytes.
  List<int> bytes(dynamic target) {
    final file = target is File ? target : File(target.toString());
    return file.readAsBytesSync();
  }

  /// Copies [source] file to [destination], creating parent directories as necessary.
  File copy(dynamic source, dynamic destination) {
    final src = source is File ? source : File(source.toString());
    final dest = destination is File ? destination : File(destination.toString());
    Fs.parent(dest.path);
    return src.copySync(dest.path);
  }

  /// Moves or renames [source] file to [destination], creating parent directories as necessary.
  File move(dynamic source, dynamic destination) {
    final src = source is File ? source : File(source.toString());
    final dest = destination is File ? destination : File(destination.toString());
    Fs.parent(dest.path);
    return src.renameSync(dest.path);
  }

  /// Creates a unique temporary directory in the system temp location.
  Directory temp([String prefix = 'tmp_']) =>
      Directory.systemTemp.createTempSync(prefix);

  /// Downloads [url] directly to [destination] file with atomic `.part` writing and progress callback.
  ///
  /// If the download fails or process exits, the partial `.part` file is cleanly discarded.
  Future<File> download(
    Uri url,
    dynamic destination, {
    http.Client? client,
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    String part = '.part',
  }) {
    final dest = destination is File ? destination : File(destination.toString());
    return Fs.download(
      url,
      dest,
      client: client,
      headers: headers,
      onProgress: onProgress,
      part: part,
    );
  }

  /// Recursively finds files in [dir] matching an optional regex or string [pattern].
  List<File> find(
    dynamic dir, {
    Pattern? pattern,
    bool recursive = true,
  }) {
    final d = dir is Directory ? dir : Directory(dir.toString());
    return Fs.find(d, pattern: pattern, recursive: recursive);
  }

  /// Deletes files in [dir] matching an optional [pattern] and returns the count of deleted files.
  int delete(
    dynamic dir, {
    Pattern? pattern,
    bool recursive = false,
  }) {
    final d = dir is Directory ? dir : Directory(dir.toString());
    return Fs.delete(d, pattern: pattern, recursive: recursive);
  }
}

/// Static filesystem utilities class (also available via lowercase `fs.*`).
class Fs {
  /// Creates or manages an [Archive] for the specified file [path].
  static Archive archive(String path) => Archive(path);

  /// Sanitizes [name] for use in filenames, replacing illegal characters with [replace] or full-width equivalents.
  static String sanitize(
    String name, {
    String replace = '_',
    bool full = false,
  }) {
    var s = name;
    if (full) {
      s = s
          .replaceAll(':', '：')
          .replaceAll('"', '”')
          .replaceAll('/', '／')
          .replaceAll('\\', '＼')
          .replaceAll('*', '＊')
          .replaceAll('?', '？')
          .replaceAll('<', '＜')
          .replaceAll('>', '＞')
          .replaceAll('|', '｜');
    } else {
      s = s.replaceAll(RegExp(r'[:"\/\\*?<>|]'), replace);
    }
    s = s.replaceAll(RegExp(r'[\x00-\x1F\x7F\r\n\t]'), '').trim();
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1).trim();
    }
    return s.isEmpty ? 'unnamed' : s;
  }

  /// Formats byte count into a human-readable size string.
  static String size(int bytes, {int decimals = 1}) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    final i = (math.log(bytes) / math.log(1024)).floor().clamp(0, units.length - 1);
    final val = bytes / math.pow(1024, i);
    return '${val.toStringAsFixed(decimals)} ${units[i]}';
  }

  /// Parses human-readable size strings (e.g. `'10MB'`) into byte counts.
  static int parse(String text) {
    final match = RegExp(r'^([\d.]+)\s*([A-Za-z]+)?$').firstMatch(text.trim());
    if (match == null) return 0;
    final value = double.tryParse(match.group(1)!) ?? 0;
    final unit = (match.group(2) ?? 'B').toUpperCase();
    const map = {
      'B': 1,
      'KB': 1024,
      'K': 1024,
      'MB': 1024 * 1024,
      'M': 1024 * 1024,
      'GB': 1024 * 1024 * 1024,
      'G': 1024 * 1024 * 1024,
      'TB': 1024 * 1024 * 1024 * 1024,
      'T': 1024 * 1024 * 1024 * 1024,
    };
    return (value * (map[unit] ?? 1)).round();
  }

  /// Formats a [Duration] into `mm:ss` or `hh:mm:ss`.
  static String time(Duration duration) {
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60);
    final s = duration.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  /// Recursively creates directory at [path] asynchronously.
  static Future<Directory> mkdir(String path, {bool sync = false}) async {
    final dir = Directory(path);
    if (sync) {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Recursively creates directory at [path] synchronously.
  static Directory mkdirSync(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Ensures the parent directory of [filePath] exists.
  static void parent(String filePath) {
    final dir = Directory(p.dirname(filePath));
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }

  /// Checks whether [target] file exists and has content > 0 bytes.
  static bool has(dynamic target, {bool match = false}) {
    final file = target is File ? target : File(target.toString());
    if (file.existsSync() && file.lengthSync() > 0) return true;
    if (match) return Fs.match(file);
    return false;
  }

  /// Matches existing files in the directory by basename ignoring minor variations.
  static bool match(dynamic target) {
    final file = target is File ? target : File(target.toString());
    if (has(file)) return true;
    final par = file.parent;
    if (!par.existsSync()) return false;
    final base = p.basenameWithoutExtension(file.path).toLowerCase();
    for (final entity in par.listSync().whereType<File>()) {
      if (entity.lengthSync() == 0 || entity.path.endsWith('.part')) continue;
      final fb = p.basenameWithoutExtension(entity.path).toLowerCase();
      if (fb == base || fb.endsWith('_$base') || base.endsWith('_$fb')) {
        return true;
      }
    }
    return false;
  }

  /// Atomically writes [content] to [target] with temporary `.part` file protection.
  static Future<File> write(
    File target,
    dynamic content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) async {
    parent(target.path);
    final partFile = File('${target.path}$part');
    if (partFile.existsSync()) partFile.deleteSync();

    Exit.track(partFile);
    try {
      if (content is List<int>) {
        await partFile.writeAsBytes(content, flush: true);
      } else if (content is String) {
        await partFile.writeAsString(content, encoding: encoding, flush: true);
      } else {
        throw ArgumentError('content must be List<int> or String');
      }

      if (target.existsSync()) target.deleteSync();
      partFile.renameSync(target.path);
      return target;
    } catch (_) {
      if (partFile.existsSync()) {
        try {
          partFile.deleteSync();
        } catch (_) {}
      }
      rethrow;
    } finally {
      Exit.untrack(partFile);
    }
  }

  /// Downloads [url] directly to [destination] with atomic `.part` writing and signal tracking.
  static Future<File> download(
    Uri url,
    File destination, {
    http.Client? client,
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    String part = '.part',
  }) async {
    parent(destination.path);
    final partFile = File('${destination.path}$part');
    if (partFile.existsSync()) partFile.deleteSync();

    Exit.track(partFile);
    final httpCli = client ?? http.Client();
    final ownsCli = client == null;

    try {
      final req = http.Request('GET', url);
      if (headers != null) req.headers.addAll(headers);

      final res = await httpCli.send(req);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        await res.stream.drain<void>();
        throw HttpException('HTTP ${res.statusCode}', uri: url);
      }

      final total = res.contentLength ?? -1;
      var received = 0;
      final sink = partFile.openWrite();

      await res.stream.listen((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null) onProgress(received, total);
      }).asFuture<void>();

      await sink.flush();
      await sink.close();

      if (total != -1 && partFile.lengthSync() != total) {
        throw HttpException('Incomplete download', uri: url);
      }

      if (destination.existsSync()) destination.deleteSync();
      partFile.renameSync(destination.path);
      return destination;
    } catch (_) {
      if (partFile.existsSync()) {
        try {
          partFile.deleteSync();
        } catch (_) {}
      }
      rethrow;
    } finally {
      Exit.untrack(partFile);
      if (ownsCli) httpCli.close();
    }
  }

  /// Recursively finds files in [dir] matching an optional [pattern].
  static List<File> find(
    Directory dir, {
    Pattern? pattern,
    bool recursive = true,
  }) {
    if (!dir.existsSync()) return [];
    return dir
        .listSync(recursive: recursive)
        .whereType<File>()
        .where((f) => pattern == null || pattern.allMatches(p.basename(f.path)).isNotEmpty)
        .toList();
  }

  /// Deletes files in [dir] matching [pattern] and returns the count of deleted files.
  static int delete(
    Directory dir, {
    Pattern? pattern,
    bool recursive = false,
  }) {
    if (!dir.existsSync()) return 0;
    var count = 0;
    for (final file in find(dir, pattern: pattern, recursive: recursive)) {
      try {
        file.deleteSync();
        count++;
      } catch (_) {}
    }
    return count;
  }
}

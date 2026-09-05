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

/// Top-level filesystem accessor instance (`fs.write(...)`, `fs.archive(...)`).
const FsAccessor fs = FsAccessor();

/// Filesystem and path namespace accessor.
class FsAccessor {
  const FsAccessor();

  /// Create or manage archive for path (1-word).
  Archive archive(String path) => Fs.archive(path);

  // --- Path utilities directly under fs namespace ---

  /// Join path segments safely without needing package:path (1-word).
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

  /// Return basename of path (e.g. 'foo.txt' from '/path/foo.txt') (1-word).
  String base(String path) => p.basename(path);

  /// Return basename without extension (e.g. 'foo' from '/path/foo.txt') (1-word).
  String name(String path) => p.basenameWithoutExtension(path);

  /// Return extension of path (e.g. '.txt') (1-word).
  String ext(String path) => p.extension(path);

  /// Return directory name of path (e.g. '/path' from '/path/foo.txt') (1-word).
  String dir(String path) => p.dirname(path);

  // --- File and directory operations ---

  /// Sanitize filename for local OS (ASCII or Japanese full-width) (1-word).
  String sanitize(
    String name, {
    String replace = '_',
    bool full = false,
  }) =>
      Fs.sanitize(name, replace: replace, full: full);

  /// Format bytes into human-readable size string (1-word).
  String size(int bytes, {int decimals = 1}) =>
      Fs.size(bytes, decimals: decimals);

  /// Parse human-readable size string into bytes (1-word).
  int parse(String text) => Fs.parse(text);

  /// Format duration into standard timer string mm:ss or hh:mm:ss (1-word).
  String time(Duration duration) => Fs.time(duration);

  /// Ensure directory exists (creates recursively) (1-word).
  Future<Directory> mkdir(String path, {bool sync = false}) =>
      Fs.mkdir(path, sync: sync);

  /// Ensure parent directory for filePath exists (1-word).
  void parent(String filePath) => Fs.parent(filePath);

  /// Check if file exists and has content > 0 bytes (1-word).
  bool has(dynamic target, {bool match = false}) =>
      Fs.has(target, match: match);

  /// Match existing file by basename ignoring prefix/suffix differences (1-word).
  bool match(dynamic target) => Fs.match(target);

  /// Write string or byte content atomically with .part tracking (1-word).
  Future<File> write(
    dynamic target,
    dynamic content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) {
    final file = target is File ? target : File(target.toString());
    return Fs.write(file, content, part: part, encoding: encoding);
  }

  /// Read file content as string (1-word).
  String read(dynamic target, {Encoding encoding = utf8}) {
    final file = target is File ? target : File(target.toString());
    return file.readAsStringSync(encoding: encoding);
  }

  /// Read file content as byte buffer (1-word).
  List<int> bytes(dynamic target) {
    final file = target is File ? target : File(target.toString());
    return file.readAsBytesSync();
  }

  /// Copy source file to destination (1-word).
  File copy(dynamic source, dynamic destination) {
    final src = source is File ? source : File(source.toString());
    final dest = destination is File ? destination : File(destination.toString());
    Fs.parent(dest.path);
    return src.copySync(dest.path);
  }

  /// Move/rename source file to destination (1-word).
  File move(dynamic source, dynamic destination) {
    final src = source is File ? source : File(source.toString());
    final dest = destination is File ? destination : File(destination.toString());
    Fs.parent(dest.path);
    return src.renameSync(dest.path);
  }

  /// Create a temporary directory (1-word).
  Directory temp([String prefix = 'tmp_']) =>
      Directory.systemTemp.createTempSync(prefix);

  /// Download URL directly to destination file with atomic .part tracking (1-word).
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

  /// Find files matching pattern within directory (1-word).
  List<File> find(
    dynamic dir, {
    Pattern? pattern,
    bool recursive = true,
  }) {
    final d = dir is Directory ? dir : Directory(dir.toString());
    return Fs.find(d, pattern: pattern, recursive: recursive);
  }

  /// Delete files matching pattern within directory (1-word).
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
  /// Create or manage archive for path (1-word).
  static Archive archive(String path) => Archive(path);

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

  static String size(int bytes, {int decimals = 1}) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    final i = (math.log(bytes) / math.log(1024)).floor().clamp(0, units.length - 1);
    final val = bytes / math.pow(1024, i);
    return '${val.toStringAsFixed(decimals)} ${units[i]}';
  }

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

  static Future<Directory> mkdir(String path, {bool sync = false}) async {
    final dir = Directory(path);
    if (sync) {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Directory mkdirSync(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static void parent(String filePath) {
    final dir = Directory(p.dirname(filePath));
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }

  static bool has(dynamic target, {bool match = false}) {
    final file = target is File ? target : File(target.toString());
    if (file.existsSync() && file.lengthSync() > 0) return true;
    if (match) return Fs.match(file);
    return false;
  }

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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../system/sys.dart';
import '../util/console/console.dart';

// ============================================================================
// FILESYSTEM, PATHS & STORAGE UTILITIES (Fs)
// ============================================================================

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
    final i = (math.log(bytes) / math.log(1024)).floor().clamp(
      0,
      units.length - 1,
    );
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

  /// Ensures the parent directory of [filePath] exists.
  static void parent(String filePath) {
    final dir = Directory(p.dirname(filePath));
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }

  /// Checks whether [target] file exists and has content > 0 bytes.
  static bool has(Object target, {bool match = false}) {
    final file = target is File ? target : File(target.toString());
    if (file.existsSync() && file.lengthSync() > 0) return true;
    if (match) return Fs.match(file);
    return false;
  }

  /// Matches existing files in the directory by basename ignoring minor variations.
  static bool match(Object target) {
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
    Object target,
    Object content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) async {
    final file = target is File ? target : File(target.toString());
    parent(file.path);
    final partFile = File('${file.path}$part');
    if (partFile.existsSync()) partFile.deleteSync();

    Exit.track(partFile);
    try {
      if (content is List<int>) {
        await partFile.writeAsBytes(content, flush: true);
      } else if (content is String) {
        await partFile.writeAsString(content, encoding: encoding, flush: true);
      } else {
        final text = const JsonEncoder.withIndent('  ').convert(content);
        await partFile.writeAsString(text, encoding: encoding, flush: true);
      }

      if (file.existsSync()) file.deleteSync();
      partFile.renameSync(file.path);
      return file;
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
        .where(
          (f) =>
              pattern == null ||
              pattern.allMatches(p.basename(f.path)).isNotEmpty,
        )
        .toList();
  }

  /// Deletes files in [dir] matching [pattern] and returns the count of deleted files.
  static int delete(Directory dir, {Pattern? pattern, bool recursive = false}) {
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

  /// Reads or writes JSON data.
  static T json<T>(Object target, [Object? data, bool pretty = false]) {
    final file = target is File ? target : File(target.toString());
    if (data != null) {
      final encoder = pretty
          ? const JsonEncoder.withIndent('  ')
          : const JsonEncoder();
      return write(file, encoder.convert(data)) as T;
    }
    return jsonDecode(file.readAsStringSync()) as T;
  }

  /// Streams lines from [target] file asynchronously using [encoding].
  static Stream<String> lines(Object target, {Encoding encoding = utf8}) {
    final file = target is File ? target : File(target.toString());
    return file
        .openRead()
        .transform(encoding.decoder)
        .transform(const LineSplitter());
  }

  /// Computes the cryptographic checksum (SHA-256 or MD5) of [target] file.
  static String hash(Object target, [String algorithm = 'sha256']) {
    final file = target is File ? target : File(target.toString());
    final b = file.readAsBytesSync();
    if (algorithm.toLowerCase() == 'md5') {
      return md5.convert(b).toString();
    }
    return sha256.convert(b).toString();
  }

  /// Retrieves status and timestamp metadata for [target].
  static FileStat stat(Object target) {
    final file = target is File ? target : File(target.toString());
    return file.statSync();
  }
}

/// Archive compression, integrity testing, and volume management utility.
///
/// Wraps 7-Zip CLI (`7z`) with 1-word methods (`check`, `zip`, `wipe`, `sync`).
/// Automatically discovers `7z.exe` in `PATH` or standard installation locations.
class Archive {
  /// Target archive file path.
  final String path;

  /// Creates an [Archive] bound to [path].
  Archive(this.path);

  /// Whether the archive file exists and is non-empty.
  bool get exists => Fs.has(File(path));

  /// Locates the 7-Zip (`7z`) binary in `PATH` or standard program directories.
  static String? which({List<String>? paths}) {
    return Sys.which(
      '7z',
      paths: [
        r'D:\dev\winget\7zip.7zip\7z.exe',
        r'C:\Program Files\7-Zip\7z.exe',
        r'C:\Program Files (x86)\7-Zip\7z.exe',
        ...?paths,
      ],
    );
  }

  /// Tests the structural integrity of [archivePath] using 7-Zip's test command (`7z t`).
  static Future<bool> test(String archivePath, {String? exe}) async {
    final bin = exe ?? which();
    if (bin == null) return false;
    final res = await Sys.run(bin, ['t', archivePath]);
    return res.ok;
  }

  /// Compresses [sourcePath] into [archivePath] with compression [level] (0-9).
  static Future<SysResult> pack(
    String archivePath,
    String sourcePath, {
    int level = 5,
    bool inherit = true,
    String? exe,
  }) async {
    final bin = exe ?? which();
    if (bin == null) {
      return SysResult(code: 1, stdout: '', stderr: '7z executable not found');
    }
    return Sys.run(bin, [
      'a',
      '-mx=$level',
      '-bsp1',
      archivePath,
      sourcePath,
    ], inherit: inherit);
  }

  /// Deletes [archivePath] and any matching split multi-volume parts (e.g. `.7z.001`, `.7z.002`).
  static int clean(String archivePath) {
    final file = File(archivePath);
    final dir = file.parent;
    final name = file.uri.pathSegments.last;
    return Fs.delete(
      dir,
      pattern: RegExp(
        '^${RegExp.escape(name)}(\\.\\d+)?\$',
        caseSensitive: false,
      ),
    );
  }

  /// Verifies the integrity of this archive file.
  Future<bool> check({String? exe}) => Archive.test(path, exe: exe);

  /// Compresses [sourcePath] into this archive file.
  Future<SysResult> zip(
    String sourcePath, {
    int level = 5,
    bool inherit = true,
    String? exe,
  }) =>
      Archive.pack(path, sourcePath, level: level, inherit: inherit, exe: exe);

  /// Wipes this archive file and any split volume segments.
  int wipe() => Archive.clean(path);

  /// Synchronizes [source] directory into this archive.
  Future<String> sync(
    String source, {
    bool force = false,
    bool changed = true,
    int level = 5,
  }) async {
    final sourceDir = Directory(source);
    if (!sourceDir.existsSync()) {
      Console.logger.warn(
        '"$source" directory not found, skipping compression.',
      );
      return 'Source folder missing';
    }

    final bin = which();
    if (bin == null) {
      Console.logger.error('7z.exe not found in PATH or standard folders.');
      return '7z not found';
    }

    final file = File(path);
    if (!force && !changed && file.existsSync()) {
      Console.logger.write('Checking existing archive ($path)... ');
      if (await check(exe: bin)) {
        Console.logger.ok(
          'Archive is intact and up-to-date, skipping compression.',
        );
        return 'Intact (up to date)';
      }
      Console.logger.warn('Archive check failed. Recreating archive...');
    }

    Console.logger.step(7, 7, 'Compressing "$source" into $path (1 volume)...');
    wipe();

    final res = await zip(source, level: level, exe: bin, inherit: true);
    if (res.ok) {
      Console.logger.ok('Successfully compressed $path into project root.');
      return 'Created / Updated';
    } else {
      Console.logger.error('Compression failed with exit code ${res.code}.');
      return 'Failed (${res.code})';
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

final _invalidPathChars = RegExp(r'[:*?"<>|\r\n\t]');
final _invalidNameChars = RegExp(r'[/\\:*?"<>|\r\n\t]');
final _whitespaceCollapse = RegExp(r'\s+');

/// Represents the type of filesystem entity at a [Path].
///
/// {@category Files}
enum PathType { file, dir, link, none }

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
  ///
  /// Separators survive, because this is a path. For a single component — a scraped
  /// title that may contain `/` — use [StringPathExtensions.filename].
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
      if (matcher.hasMatch(_relative(entity.path))) yield Path(entity.path);
    }
  }

  /// Lists paths matching [pattern] synchronously (glob syntax, e.g. `'**/*.mp3'` or `'**/flac'`).
  ///
  /// Defaults to platform case sensitivity (case-sensitive on Linux, insensitive on Windows/macOS).
  /// Pass [caseSensitive] to override.
  List<Path> globSync(String pattern, {bool? caseSensitive}) {
    final matcher = _globToRegex(pattern, caseSensitive: caseSensitive);
    return [
      for (final entity in asDir.listSync(recursive: true, followLinks: false))
        if (matcher.hasMatch(_relative(entity.path))) Path(entity.path),
    ];
  }

  /// [child] relative to this directory, with forward slashes, for glob matching.
  String _relative(String child) {
    final rel = p.relative(child, from: path);
    return Platform.isWindows ? rel.replaceAll(r'\', '/') : rel;
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

  /// Deletes this file, directory, or link.
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

  /// This string as a single path component, safe to join with [Path.operator /].
  ///
  /// Separators and reserved characters become `_`, whitespace runs collapse, and
  /// the result is never empty. Use [Path.sanitized] for a whole path, which keeps
  /// its separators.
  Path get filename {
    final cleaned = replaceAll(_invalidNameChars, '_').replaceAll(_whitespaceCollapse, ' ').trim();
    return Path(cleaned.isEmpty ? '_' : cleaned);
  }
}

final _globCache = <(String, bool), RegExp>{};

RegExp _globToRegex(String pattern, {bool? caseSensitive}) {
  final isSensitive = caseSensitive ?? (!Platform.isWindows && !Platform.isMacOS);
  final cached = _globCache[(pattern, isSensitive)];
  if (cached != null) return cached;
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
  return _globCache[(pattern, isSensitive)] = RegExp(buffer.toString(), caseSensitive: isSensitive);
}

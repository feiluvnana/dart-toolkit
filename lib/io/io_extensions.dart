/// # Native dart:io Extensions
///
/// Fluent extensions on standard `dart:io` types ([File], [Directory], [FileSystemEntity])
/// bringing the toolkit's atomic write guarantees, JSON helpers, and traversal
/// directly to native Dart types.
library;

import 'dart:convert';
import 'dart:io';

import '../format/format.dart';
import '../src/fs.dart';
import '../src/json.dart';
import 'entry.dart';

/// Fluent extensions on standard `dart:io` [File].
extension ToolkitFileExtensions on File {
  /// Reads this file as decoded lines.
  Future<List<String>> readLines({Encoding encoding = utf8}) async =>
      readAsLines(encoding: encoding);

  /// Reads this file as decoded lines synchronously.
  List<String> readLinesSync({Encoding encoding = utf8}) =>
      readAsLinesSync(encoding: encoding);

  /// Reads and parses this file as a JSON document cursor.
  Future<Json> readJson() async => format.json.parse(await readAsString());

  /// Reads and parses this file as a JSON document cursor synchronously.
  Json readJsonSync() => format.json.parse(readAsStringSync());

  /// Decodes this file's JSON content directly as typed [T].
  Future<T> readDecoded<T>() async => jsonDecode(await readAsString()) as T;

  /// Decodes this file's JSON content directly as typed [T] synchronously.
  T readDecodedSync<T>() => jsonDecode(readAsStringSync()) as T;

  /// Writes [content] atomically to this file staging through [part].
  Future<File> writeAtomic(
    String content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) async {
    await Fs.write(path, content, encoding: encoding, part: part);
    return this;
  }

  /// Writes [content] atomically to this file synchronously staging through [part].
  File writeAtomicSync(
    String content, {
    String part = '.part',
    Encoding encoding = utf8,
  }) {
    Fs.writeSync(path, content, encoding: encoding, part: part);
    return this;
  }

  /// Writes [bytes] atomically to this file staging through [part].
  Future<File> writeBytesAtomic(
    List<int> bytes, {
    String part = '.part',
  }) async {
    await Fs.save(path, bytes, part: part);
    return this;
  }

  /// Writes [bytes] atomically to this file synchronously staging through [part].
  File writeBytesAtomicSync(
    List<int> bytes, {
    String part = '.part',
  }) {
    Fs.saveSync(path, bytes, part: part);
    return this;
  }

  /// Appends [line] followed by a newline to this file.
  Future<File> appendLine(String line, {Encoding encoding = utf8}) async {
    final endsWithNewline = !existsSync() || (await readAsString(encoding: encoding)).endsWith('\n');
    final prefix = endsWithNewline ? '' : '\n';
    await Fs.append(path, '$prefix$line\n', encoding: encoding);
    return this;
  }

  /// Appends [line] followed by a newline to this file synchronously.
  File appendLineSync(String line, {Encoding encoding = utf8}) {
    final endsWithNewline = !existsSync() || readAsStringSync(encoding: encoding).endsWith('\n');
    final prefix = endsWithNewline ? '' : '\n';
    Fs.appendSync(path, '$prefix$line\n', encoding: encoding);
    return this;
  }

  /// Serializes [data] as JSON and writes it atomically to this file.
  Future<File> writeJson(
    Object? data, {
    bool indent = true,
    String part = '.part',
  }) async {
    final text = indent
        ? const JsonEncoder.withIndent('  ').convert(data)
        : jsonEncode(data);
    return writeAtomic(text, part: part);
  }
}

/// Fluent extensions on standard `dart:io` [Directory].
extension ToolkitDirectoryExtensions on Directory {
  /// Walks this directory recursively or shallowly, filtering by [matching] when provided.
  Stream<FileSystemEntity> walk({
    Pattern? matching,
    bool recursive = true,
    bool followLinks = true,
  }) {
    final stream = list(recursive: recursive, followLinks: followLinks);
    if (matching == null) return stream;
    return stream.where((entity) => matching.allMatches(entity.path).isNotEmpty);
  }

  /// Lists entries in this directory yielding [FileSystemEntry] objects.
  Stream<FileSystemEntry> listEntries({
    bool recursive = false,
    bool followLinks = true,
  }) => list(recursive: recursive, followLinks: followLinks)
      .map((entity) => Fs.entryFor(entity.path));

  /// Ensures this directory exists asynchronously.
  Future<Directory> ensure() async => create(recursive: true);

  /// Ensures this directory exists synchronously.
  Directory ensureSync() {
    createSync(recursive: true);
    return this;
  }
}

/// Fluent extensions on standard `dart:io` [FileSystemEntity].
extension ToolkitFileSystemEntityExtensions on FileSystemEntity {
  /// The [FileSystemEntry] metadata for this entity.
  FileSystemEntry get entry => Fs.entryFor(path);

  /// Whether this entity is a file.
  bool get isFile => this is File || FileSystemEntity.isFileSync(path);

  /// Whether this entity is a directory.
  bool get isDir => this is Directory || FileSystemEntity.isDirectorySync(path);

  /// Whether this entity is a symbolic link.
  bool get isLink => this is Link || FileSystemEntity.isLinkSync(path);
}

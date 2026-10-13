/// Archives and gzip. Thin facade over `package:archive` and `dart:io`.
///
/// ```dart
/// await (Archive.pack('site', ArchiveFormat.zip) > Fs.file('site.zip'));
/// await (Http.get(url) > Archive.unpack('vendor'));
/// await (Http.get(url) | Archive.gunzip() > Fs.file('dump.sql'));
/// ```
///
/// Public surface is exactly: [Archive], [ArchiveFormat].
/// - `Archive.pack()` is a [Reader] of the archive, `unpack()` a [Writer].
/// - `Archive.gzip()`/`gunzip()` are streaming [Pipe]s.
/// Everything else is private.
library;

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:archive/archive.dart' as a;

import 'core.dart';
export 'core.dart';

/// Archive formats for [Archive.pack].
enum ArchiveFormat { zip, tar, tgz }

/// Entry point: pack a folder, unpack a stream, gzip on the way.
abstract final class Archive {
  /// A [Reader] of the archive holding the contents of [dir] (not [dir]
  /// itself), paths relative to it. Built when read.
  static Reader pack(String dir, ArchiveFormat format) => _Packed(dir, format);

  /// A [Writer] extracting what it is given into [dir], creating it.
  /// The format comes from the magic bytes (zip, tar, gzip-compressed tar).
  static Writer unpack(String dir) => _Unpacker(dir);

  /// Streaming gzip compression.
  static Pipe gzip() => _GzipPipe(compress: true);

  /// Streaming gzip decompression. Bad data fails the run with a
  /// [FormatException].
  static Pipe gunzip() => _GzipPipe(compress: false);
}

final class _Packed with Reader {
  _Packed(this._dir, this._format);

  final String _dir;
  final ArchiveFormat _format;

  @override
  Stream<List<int>> stream() async* {
    final archive = a.Archive();
    final root = io.Directory(_dir);
    if (!await root.exists()) {
      throw io.PathNotFoundException(_dir, const io.OSError());
    }
    await for (final e in root.list(recursive: true, followLinks: false)) {
      final t = await io.FileSystemEntity.type(e.path, followLinks: false);
      if (t == io.FileSystemEntityType.link) continue;
      var rel = e.path;
      final prefix = _dir.endsWith(io.Platform.pathSeparator)
          ? _dir
          : _dir + io.Platform.pathSeparator;
      if (rel.startsWith(prefix)) rel = rel.substring(prefix.length);
      rel = rel.replaceAll('\\', '/');
      if (t == io.FileSystemEntityType.directory) {
        if (rel.isNotEmpty) archive.addFile(a.ArchiveFile('$rel/', 0, const []));
        continue;
      }
      if (t != io.FileSystemEntityType.file) continue;
      final data = await io.File(e.path).readAsBytes();
      archive.addFile(a.ArchiveFile(rel, data.length, data));
    }
    List<int> out;
    switch (_format) {
      case ArchiveFormat.zip:
        out = a.ZipEncoder().encode(archive);
      case ArchiveFormat.tar:
        out = a.TarEncoder().encode(archive);
      case ArchiveFormat.tgz:
        out = a.GZipEncoder().encode(a.TarEncoder().encode(archive));
    }
    yield out;
  }
}

final class _Unpacker implements Writer {
  _Unpacker(this._dir);

  final String _dir;

  @override
  Future<void> consume(Stream<List<int>> input) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in input) {
      bytes.add(chunk);
    }
    final archive = _decode(bytes.takeBytes());
    // Check every member before writing anything.
    for (final f in archive.files) {
      _checkMember(f.name);
      if (f.isSymbolicLink) {
        throw FormatException('archive member is a link: ${f.name}');
      }
    }
    final tmp = '$_dir.tmp${DateTime.now().microsecondsSinceEpoch}';
    final tmpDir = io.Directory(tmp);
    try {
      await tmpDir.create(recursive: true);
      for (final f in archive.files) {
        final dest = '${tmpDir.path}${io.Platform.pathSeparator}${f.name}';
        // Names ending in '/' are folders (tar emits explicit dir entries);
        // the engine does not always clear isFile on them.
        if (f.name.endsWith('/')) {
          await io.Directory(dest).create(recursive: true);
        } else if (f.isFile) {
          final parent = io.File(dest).parent;
          await parent.create(recursive: true);
          await io.File(dest).writeAsBytes(f.content as List<int>);
        } else {
          await io.Directory(dest).create(recursive: true);
        }
      }
      final target = io.Directory(_dir);
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      final parent = target.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      await tmpDir.rename(_dir);
    } catch (_) {
      try {
        if (await tmpDir.exists()) {
          await tmpDir.delete(recursive: true);
        }
      } catch (_) {}
      rethrow;
    }
  }

  static a.Archive _decode(List<int> bytes) {
    try {
      if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
        final tar = a.GZipDecoder().decodeBytes(bytes);
        return a.TarDecoder().decodeBytes(tar);
      }
      if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4b) {
        return a.ZipDecoder().decodeBytes(bytes);
      }
      // No magic matched: try zip, then tar. The zip decoder answers empty
      // instead of throwing on non-zip input, so only a non-empty hit counts.
      try {
        final zip = a.ZipDecoder().decodeBytes(bytes);
        if (zip.files.isNotEmpty) return zip;
      } on a.ArchiveException {
        // Not a zip; try tar below.
      }
      try {
        final tar = a.TarDecoder().decodeBytes(bytes);
        if (tar.files.isNotEmpty) return tar;
      } on a.ArchiveException catch (e) {
        throw FormatException('corrupt archive: $e');
      }
      throw const FormatException('corrupt archive: unknown format');
    } on FormatException catch (e) {
      // The engine's ArchiveException already is a FormatException; add the
      // subject unless this is one of ours.
      if (e.message.startsWith('corrupt archive')) rethrow;
      throw FormatException('corrupt archive: ${e.message}');
    } catch (e) {
      throw FormatException('corrupt archive: $e');
    }
  }

  static void _checkMember(String name) {
    if (name.isEmpty) {
      throw FormatException('archive member has an empty name');
    }
    if (name.startsWith('/') ||
        name.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(name)) {
      throw FormatException('archive member escapes: $name');
    }
    for (final part in name.replaceAll('\\', '/').split('/')) {
      if (part == '..') {
        throw FormatException('archive member escapes: $name');
      }
    }
  }
}

final class _GzipPipe implements Pipe {
  _GzipPipe({required this.compress});

  final bool compress;

  @override
  Stream<List<int>> transform(Stream<List<int>> input) {
    final codec = compress ? io.gzip.encoder : io.gzip.decoder;
    Stream<List<int>> out;
    try {
      out = input.transform(codec);
    } catch (e) {
      throw FormatException('bad gzip data: $e');
    }
    if (compress) return out;
    return out.handleError((Object e) {
      if (e is FormatException) throw e;
      throw FormatException('bad gzip data: $e');
    });
  }
}

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
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' as a;
import 'package:path/path.dart' as p;

import 'core.dart';
export 'core.dart';

/// Archive formats for [Archive.pack].
enum ArchiveFormat { zip, tar, tgz }

/// Entry point: pack a folder, unpack a stream, gzip on the way.
abstract final class Archive {
  /// A [Reader] of the archive holding the contents of [dir] (not [dir]
  /// itself), paths relative to it. Built when read.
  ///
  /// Links are refused with a [FormatException], the same as [unpack]:
  /// an archive never silently drops entries.
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
      // Pack refuses links with a FormatException, the same as unpack:
      // silently dropping them would lose data.
      if (t == io.FileSystemEntityType.link) {
        throw FormatException('pack refuses links: ${e.path}');
      }
      var rel = e.path;
      final prefix = _dir.endsWith(io.Platform.pathSeparator)
          ? _dir
          : _dir + io.Platform.pathSeparator;
      if (rel.startsWith(prefix)) rel = rel.substring(prefix.length);
      rel = rel.replaceAll('\\', '/');
      if (t == io.FileSystemEntityType.directory) {
        if (rel.isNotEmpty) {
          final af = a.ArchiveFile('$rel/', 0, const []);
          try {
            final st = await io.FileStat.stat(e.path);
            af.mode = st.mode & 0x1FF;
            if (af.mode != 0 && (af.mode & 0x111) == 0) {
              af.mode |= 0x111;
            }
          } catch (_) {}
          archive.addFile(af);
        }
        continue;
      }
      if (t != io.FileSystemEntityType.file) continue;
      final data = await io.File(e.path).readAsBytes();
      final af = a.ArchiveFile(rel, data.length, data);
      try {
        final st = await io.FileStat.stat(e.path);
        final m = st.mode & 0x1FF;
        if (m != 0) af.mode = m;
      } catch (_) {}
      archive.addFile(af);
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
    // Normalise the target; the temp folder is a SIBLING of the target,
    // never inside it (F2). Use the absolute path so '.' (whose dirname is
    // '.') still gets a sibling outside itself.
    final d = p.normalize(_dir);
    final abs = p.normalize(p.absolute(d));
    final tmp = p.join(
      p.dirname(abs),
      '.${p.basename(abs)}.tmp${io.pid}.${DateTime.now().microsecondsSinceEpoch}.${Random().nextInt(1 << 32)}',
    );
    final tmpDir = io.Directory(tmp);
    try {
      await tmpDir.create(recursive: true);
      for (final f in archive.files) {
        // Split on '/' so member names work on every platform.
        final relParts = f.name.split('/').where((s) => s.isNotEmpty);
        if (relParts.isEmpty) continue; // trailing '/' dir entry root?
        final dest = p.joinAll([tmpDir.path, ...relParts]);
        // Names ending in '/' are folders (tar emits explicit dir entries);
        // the engine does not always clear isFile on them.
        if (f.name.endsWith('/')) {
          await io.Directory(dest).create(recursive: true);
          await _chmodMember(dest, f.mode, isDir: true);
        } else if (f.isFile) {
          final parent = io.File(dest).parent;
          await parent.create(recursive: true);
          await io.File(dest).writeAsBytes(f.content as List<int>);
          await _chmodMember(dest, f.mode, isDir: false);
        } else {
          await io.Directory(dest).create(recursive: true);
          await _chmodMember(dest, f.mode, isDir: true);
        }
      }
      // Never delete the target (F1): create it and merge each top-level
      // member in (rename, copy fallback). Existing files are kept.
      await io.Directory(d).create(recursive: true);
      await for (final e in tmpDir.list(
        recursive: false,
        followLinks: false,
      )) {
        final dest = p.join(d, p.basename(e.path));
        await _moveInto(e.path, dest);
      }
    } finally {
      try {
        if (await tmpDir.exists()) {
          await tmpDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  /// Move [src] (inside the temp dir) into [dest] (inside the target),
  /// merging folders so existing files are never deleted.
  static Future<void> _moveInto(String src, String dest) async {
    final srcType = await io.FileSystemEntity.type(src, followLinks: false);
    final destType = await io.FileSystemEntity.type(dest, followLinks: false);
    if (srcType == io.FileSystemEntityType.directory &&
        destType == io.FileSystemEntityType.directory) {
      await for (final child in io.Directory(src).list(
        recursive: false,
        followLinks: false,
      )) {
        await _moveInto(child.path, p.join(dest, p.basename(child.path)));
      }
      try {
        await io.Directory(src).delete(recursive: false);
      } catch (_) {}
      return;
    }
    if (destType != io.FileSystemEntityType.notFound) {
      try {
        if (destType == io.FileSystemEntityType.directory) {
          await io.Directory(dest).delete(recursive: true);
        } else {
          try {
            await io.File(dest).delete();
          } catch (_) {
            await io.Link(dest).delete();
          }
        }
      } catch (_) {}
    }
    try {
      if (srcType == io.FileSystemEntityType.directory) {
        await io.Directory(src).rename(dest);
      } else {
        await io.File(src).rename(dest);
      }
    } on io.FileSystemException {
      // Rename across devices (or over an existing entry on some
      // platforms): copy then delete.
      if (srcType == io.FileSystemEntityType.directory) {
        await _copyTree(src, dest);
        await io.Directory(src).delete(recursive: true);
      } else {
        await io.File(src).copy(dest);
        try {
          final st = await io.FileStat.stat(src);
          try {
            await io.File(dest).setLastModified(st.modified);
          } catch (_) {}
          await _chmodPath(dest, st.mode & 0xFFF);
        } catch (_) {}
        await io.File(src).delete();
      }
    }
  }

  static Future<void> _copyTree(String from, String to) async {
    await io.Directory(to).create(recursive: true);
    await for (final e in io.Directory(
      from,
    ).list(recursive: false, followLinks: false)) {
      final dest = p.join(to, p.basename(e.path));
      final t = await io.FileSystemEntity.type(e.path, followLinks: false);
      if (t == io.FileSystemEntityType.directory) {
        await _copyTree(e.path, dest);
      } else if (t == io.FileSystemEntityType.file) {
        await io.File(e.path).copy(dest);
        try {
          final st = await io.FileStat.stat(e.path);
          try {
            await io.File(dest).setLastModified(st.modified);
          } catch (_) {}
          await _chmodPath(dest, st.mode & 0xFFF);
        } catch (_) {}
      }
    }
    try {
      final st = await io.FileStat.stat(from);
      await _touchTime(to, st.modified);
      await _chmodPath(to, st.mode & 0xFFF);
    } catch (_) {}
  }

  static a.Archive _decode(List<int> bytes) {
    try {
      if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
        _verifyGzip(bytes);
        List<int> tar;
        try {
          tar = a.GZipDecoder().decodeBytes(bytes);
        } catch (e) {
          throw FormatException('bad gzip data: $e');
        }
        if (!_looksLikeTar(tar)) {
          throw const FormatException(
            'corrupt archive: gzip data is not a tar archive',
          );
        }
        try {
          return a.TarDecoder().decodeBytes(tar);
        } catch (e) {
          throw FormatException('corrupt archive: $e');
        }
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
      if (_looksLikeTar(bytes)) {
        try {
          // An empty tar (all-zero blocks) decodes to an empty archive:
          // unpacking it creates the target and merges nothing.
          return a.TarDecoder().decodeBytes(bytes);
        } on a.ArchiveException catch (e) {
          throw FormatException('corrupt archive: $e');
        }
      }
      throw const FormatException('corrupt archive: unknown format');
    } on FormatException catch (e) {
      // The engine's ArchiveException already is a FormatException; add the
      // subject unless this is one of ours.
      if (e.message.startsWith('corrupt archive') ||
          e.message.startsWith('bad gzip data')) {
        rethrow;
      }
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

/// True when [bytes] look like a (possibly empty) tar: an empty input, an
/// all-zero block (the empty-tar end), `ustar` magic at offset 257, or a
/// first 512-byte header block with a valid tar checksum. The checksum test
/// matters because the engine's own tar writer leaves the magic field zero.
bool _looksLikeTar(List<int> bytes) {
  if (bytes.isEmpty) return true;
  if (bytes.length >= 262 &&
      bytes[257] == 0x75 && // u
      bytes[258] == 0x73 && // s
      bytes[259] == 0x74 && // t
      bytes[260] == 0x61 && // a
      bytes[261] == 0x72) {
    // r
    return true;
  }
  // Empty tar: one or two all-zero 512-byte end blocks.
  if (bytes.length >= 512) {
    var allZero = true;
    for (final b in bytes) {
      if (b != 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) return true;
    return _tarChecksumOk(bytes, 0);
  }
  return false;
}

/// The classic tar sniff: the header checksum (the octal value in bytes
/// 148..156) equals the sum of the 512 header bytes with the checksum field
/// itself read as spaces.
bool _tarChecksumOk(List<int> bytes, int offset) {
  if (bytes.length < offset + 512) return false;
  var stored = 0;
  var digits = 0;
  for (var i = offset + 148; i < offset + 156; i++) {
    final b = bytes[i];
    if (b == 0 || b == 0x20) continue;
    if (b < 0x30 || b > 0x37) return false;
    stored = stored * 8 + (b - 0x30);
    digits++;
  }
  if (digits == 0) return false;
  var sum = 0;
  for (var i = offset; i < offset + 512; i++) {
    sum += (i >= offset + 148 && i < offset + 156) ? 0x20 : bytes[i];
  }
  return sum == stored;
}

/// Verify the gzip trailer (CRC32 + ISIZE) of single-member [compressed].
/// Throws a [FormatException] when the trailer is missing or mismatched
/// (truncated or corrupt data).
void _verifyGzip(List<int> compressed) {
  if (compressed.length < 18) {
    throw const FormatException('bad gzip data: truncated (no trailer)');
  }
  if (compressed[0] != 0x1f || compressed[1] != 0x8b) {
    throw const FormatException('bad gzip data: not a gzip stream');
  }
  List<int> decompressed;
  try {
    decompressed = io.gzip.decode(compressed);
  } catch (e) {
    throw FormatException('bad gzip data: $e');
  }
  final trailer = compressed.sublist(compressed.length - 8);
  final view = ByteData.sublistView(Uint8List.fromList(trailer));
  final wantCrc = view.getUint32(0, Endian.little);
  final wantSize = view.getUint32(4, Endian.little);
  final gotCrc = _crc32(decompressed);
  final gotSize = decompressed.length & 0xFFFFFFFF;
  if (gotCrc != wantCrc || gotSize != wantSize) {
    throw const FormatException(
      'bad gzip data: trailer mismatch (truncated or corrupt)',
    );
  }
}

/// IEEE CRC-32 over [data].
int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

final _crcTable = (() {
  const poly = 0xEDB88320;
  final t = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? poly ^ (c >> 1) : c >> 1;
    }
    t[i] = c & 0xFFFFFFFF;
  }
  return t;
})();

/// chmod an unpacked member to `mode & 0x1ff` (POSIX only, best-effort).
/// Skipped when the stored mode carries no permission bits.
Future<void> _chmodMember(String path, int mode, {required bool isDir}) async {
  var m = mode & 0x1FF;
  if (m == 0) return;
  if (isDir) m |= 0x100; // never leave a folder untraversable
  await _chmodPath(path, m);
}

Future<void> _chmodPath(String path, int mode) async {
  if (io.Platform.isWindows) return;
  try {
    final r = await io.Process.run(
      'chmod',
      [(mode & 0xFFF).toRadixString(8), path],
    );
    if (r.exitCode != 0) return;
  } catch (_) {}
}

/// Set a folder's mtime (dart:io has no Directory.setLastModified):
/// `touch` on POSIX, no-op on Windows. Best-effort.
Future<void> _touchTime(String path, DateTime mtime) async {
  if (io.Platform.isWindows) return;
  try {
    final List<String> args;
    if (io.Platform.isMacOS) {
      String two(int n) => n.toString().padLeft(2, '0');
      final t =
          '${mtime.year.toString().padLeft(4, '0')}${two(mtime.month)}${two(mtime.day)}${two(mtime.hour)}${two(mtime.minute)}.${two(mtime.second)}';
      args = ['-t', t, path];
    } else {
      args = [
        '-d',
        '@${mtime.millisecondsSinceEpoch ~/ 1000}',
        path,
      ];
    }
    await io.Process.run('touch', args);
  } catch (_) {}
}

final class _GzipPipe implements Pipe {
  _GzipPipe({required this.compress});

  final bool compress;

  @override
  Stream<List<int>> transform(Stream<List<int>> input) {
    if (compress) {
      try {
        return input.transform(io.gzip.encoder);
      } catch (e) {
        throw FormatException('bad gzip data: $e');
      }
    }
    // Decompression verifies the gzip trailer (CRC32 + ISIZE): truncated
    // or corrupt data fails the run with a FormatException instead of
    // silently yielding partial bytes.
    return _gunzipChecked(input);
  }

  Stream<List<int>> _gunzipChecked(Stream<List<int>> input) async* {
    final raw = BytesBuilder(copy: false);
    await for (final chunk in input) {
      raw.add(chunk);
    }
    final compressed = raw.takeBytes();
    _verifyGzip(compressed);
    List<int> decompressed;
    try {
      decompressed = io.gzip.decode(compressed);
    } catch (e) {
      if (e is FormatException) rethrow;
      throw FormatException('bad gzip data: $e');
    }
    yield decompressed;
  }
}

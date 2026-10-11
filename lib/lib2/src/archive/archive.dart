import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/native.dart' as l2native;
import '../core/traits.dart';
import '../fs/io.dart' as fs;

/// Pack, unpack, list, extract and open archives through the rewritten native
/// engine (`tk_archive_*`, ABI 1): ZIP, TAR and gzip plus 7z/RAR and the
/// xz/zst/bz2 streams. In-memory `zip`/`unzip`/`gzip`/`gunzip` go through the
/// same engine (via temporary files where the ABI is file-oriented).
///
/// ```dart
/// await Archive.pack('project', 'backup.zip');
/// await Archive.unpack('backup.zip', 'restored/');
/// final names = await Archive.list('backup.zip');
/// ```
abstract final class Archive {
  /// Packs the file or directory at [src] into [dst]. The extension of [dst] picks the
  /// format: `.zip`, `.tar`, `.tar.gz`/`.tgz` or `.gz` (a single stream).
  static Future<void> pack(Object src, Object dst, {int level = 6}) async {
    final target = _path(dst);
    final lower = target.toLowerCase();
    if (lower.endsWith('.gz') && !lower.endsWith('.tar.gz') && !lower.endsWith('.tgz')) {
      // A single stream: compress the file (or the first file of a folder).
      final type = await io.FileSystemEntity.type(_path(src));
      final file = type == io.FileSystemEntityType.directory
          ? (await fs.Dir(_path(src)).find('**', recursive: true)).first.str
          : _path(src);
      await _compressFile(file, target, level);
      return;
    }
    final format = _formatCode(target);
    final tmp = '$target.tmp_${DateTime.now().microsecondsSinceEpoch}';
    try {
      final rc = l2native.Lib2Native.withText(_absolute(_path(src)), (s, sn) {
        return l2native.Lib2Native.withText(_absolute(target), (d, dn) {
          return l2native.Lib2Native.withText(tmp, (o, on) {
            return _ArchiveNative.create(
              format,
              s,
              sn,
              d,
              dn,
              o,
              on,
              ffi.nullptr,
              0,
              ffi.nullptr,
              0,
              level,
              ffi.nullptr,
              ffi.nullptr,
            );
          });
        });
      });
      if (rc < 0) throw _archiveError(l2native.Lib2Native.lastError(), target);
      // The engine wrote a temporary (so the destination is never half-written);
      // the destination is skipped when it sits under the source, so packing into
      // one's own tree never archives the half-written output.
      await fs.renameFile(tmp, target);
    } catch (_) {
      await _gone(tmp);
      rethrow;
    }
  }

  /// Unpacks [src] into [dst]. The container is detected from magic bytes.
  ///
  /// Every member is validated before anything is written: an absolute
  /// member, one holding a NUL byte, one escaping [dst] (`..` past the root),
  /// or a symlink/hardlink entry is a [SecurityException] and nothing is
  /// written. Directory entries are created; anything else lands as a file.
  static Future<void> unpack(Object src, [Object? dst]) async {
    final path = _absolute(_path(src));
    final root = dst == null ? io.Directory.current.path : _absolute(_path(dst));
    // Validate every name (and refuse links) before the engine writes a byte.
    final members = await _listRecords(path);
    for (final m in members) {
      await fs.sandbox(root, m.name);
      if (m.isLink) throw SecurityException('Refused link member: ${m.name}');
    }
    final rc = l2native.Lib2Native.withText(path, (p, n) {
      return l2native.Lib2Native.withText(root, (d, dn) {
        return _ArchiveNative.extract(
          p,
          n,
          d,
          dn,
          ffi.nullptr,
          0,
          ffi.nullptr,
          0,
          _foldCase(),
          ffi.nullptr,
          ffi.nullptr,
        );
      });
    });
    if (rc < 0) throw _archiveError(l2native.Lib2Native.lastError(), path);
  }

  /// Extracts the single member [target] from [src] and answers its bytes.
  /// A missing member is a [MissingException]; a link member is a
  /// [SecurityException], as links are never materialized.
  static Future<Uint8List> extract(Object src, String target) async {
    final path = _absolute(_path(src));
    final members = await _listRecords(path);
    final want = target.replaceAll('\\', '/');
    _MemberRecord? hit;
    try {
      hit = members.firstWhere((m) => m.name.replaceAll('\\', '/') == want);
    } on StateError {
      throw MissingException(target, where: _path(src));
    }
    if (hit.isLink) throw SecurityException('Refused link member: ${hit.name}');
    if (hit.isDir) throw MissingException(target, where: _path(src));
    // `read` hands its bytes over whole (`own`): freed with `tk_release`, never `tk_free`.
    final taken = l2native.Lib2Native.withText(path, (p, n) {
      return l2native.Lib2Native.withText(hit!.name, (m, mn) {
        return l2native.Lib2Native.takeOwn('read ${hit!.name}', (out, len) {
          return _ArchiveNative.read(p, n, m, mn, ffi.nullptr, 0, _foldCase(), out, len, ffi.nullptr);
        });
      });
    });
    return taken;
  }

  /// Opens the single member [member] of [src] as a [Reader], so it streams
  /// out without materializing the rest of the archive.
  ///
  /// A missing member is a [MissingException]; a link member is a
  /// [SecurityException], as links are never materialized.
  static Future<Reader> open(Object src, String member) async => _MemberReader(await extract(src, member));

  /// Lists the entry names inside [src] (files, not directories or links).
  static Future<List<String>> list(Object src) async => [
    for (final m in await _listRecords(_absolute(_path(src))))
      if (!m.isDir && !m.isLink) m.name,
  ];

  /// Packs an in-memory map of names to bytes as a ZIP.
  static Uint8List zip(Map<String, List<int>> files, {int level = 6}) {
    final h = _ArchiveNative.packCreate(0, level);
    if (h == ffi.nullptr) throw l2native.NativeException('pack zip', l2native.Lib2Native.lastError());
    try {
      for (final e in files.entries) {
        final name = utf8.encode(e.key);
        final data = e.value is Uint8List ? e.value as Uint8List : Uint8List.fromList(e.value);
        final rc = l2native.Lib2Native.withBytes(name, (np, nn) {
          return l2native.Lib2Native.withBytes(data, (dp, dn) {
            return _ArchiveNative.packAdd(h, np, nn, dp, dn);
          });
        });
        if (rc < 0) throw l2native.NativeException('pack ${e.key}', l2native.Lib2Native.lastError());
      }
      return l2native.Lib2Native.take('pack zip', (out, len) => _ArchiveNative.packFinish(h, out, len));
    } catch (_) {
      _ArchiveNative.packFree(h);
      rethrow;
    }
  }

  /// Unpacks ZIP [bytes] into a map of names to bytes, via the stepped reader.
  static Map<String, Uint8List> unzip(List<int> bytes) => _stepAll(Uint8List.fromList(bytes));

  /// Deflates [data] as a gzip stream.
  static Uint8List gzip(List<int> data) => _codec(data, true);

  /// Inflates a gzip stream.
  static Uint8List gunzip(List<int> data) => _codec(data, false);

  /// Steps a whole archive at [path] into a name-to-bytes map (files only).
  static Map<String, Uint8List> _stepAll(Uint8List bytes) {
    // The stepper is file-oriented: stage, step, delete.
    final tmp = io.File('${io.Directory.systemTemp.path}/tk_unzip_${DateTime.now().microsecondsSinceEpoch}.zip')
      ..writeAsBytesSync(bytes);
    try {
      final out = <String, Uint8List>{};
      final h = l2native.Lib2Native.withText(tmp.path, (p, n) {
        return _ArchiveNative.open(p, n, ffi.nullptr, 0, 0);
      });
      if (h == ffi.nullptr) throw l2native.NativeException('open archive', l2native.Lib2Native.lastError());
      try {
        final nameBuf = l2native.Lib2Native.alloc(4096);
        try {
          while (true) {
            final nameLenPtr = l2native.Lib2Native.alloc(8).cast<ffi.IntPtr>();
            final sizePtr = l2native.Lib2Native.alloc(8).cast<ffi.Uint64>();
            final dirPtr = l2native.Lib2Native.alloc(1);
            try {
              final rc = _ArchiveNative.next(h, nameBuf, 4096, nameLenPtr, sizePtr, dirPtr);
              if (rc < 0) throw l2native.NativeException('step archive', l2native.Lib2Native.lastError());
              if (rc == 0) break;
              final name = utf8.decode(nameBuf.asTypedList(nameLenPtr.value));
              final builder = BytesBuilder(copy: true);
              final chunk = l2native.Lib2Native.alloc(65536);
              try {
                while (true) {
                  final n = _ArchiveNative.entryRead(h, chunk, 65536);
                  if (n < 0) throw l2native.NativeException('read $name', l2native.Lib2Native.lastError());
                  if (n == 0) break;
                  builder.add(chunk.asTypedList(n));
                }
              } finally {
                l2native.Lib2Native.free(chunk, 65536);
              }
              if (dirPtr.value == 0) out[name] = builder.takeBytes();
            } finally {
              l2native.Lib2Native.free(nameLenPtr.cast(), 8);
              l2native.Lib2Native.free(sizePtr.cast(), 8);
              l2native.Lib2Native.free(dirPtr, 1);
            }
          }
        } finally {
          l2native.Lib2Native.free(nameBuf, 4096);
        }
      } finally {
        _ArchiveNative.free(h);
      }
      return out;
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }

  /// Gzip-compresses ([zipIt]) or inflates [data] through temporary files.
  static Uint8List _codec(List<int> data, bool zipIt) {
    final dir = io.Directory.systemTemp.createTempSync('tk_gzip_');
    try {
      final src = io.File('${dir.path}/in')..writeAsBytesSync(data);
      final dst = io.File('${dir.path}/out');
      if (zipIt) {
        final rc = l2native.Lib2Native.withText(src.path, (s, sn) {
          return l2native.Lib2Native.withText(dst.path, (d, dn) {
            return _ArchiveNative.compress(0, s, sn, d, dn, -1, ffi.nullptr, ffi.nullptr);
          });
        });
        if (rc < 0) throw l2native.NativeException('gzip', l2native.Lib2Native.lastError());
      } else {
        final rc = l2native.Lib2Native.withText(src.path, (s, sn) {
          return l2native.Lib2Native.withText(dst.path, (d, dn) {
            return _ArchiveNative.decompress(0xFFFFFFFF, s, sn, d, dn, 0, ffi.nullptr, ffi.nullptr);
          });
        });
        if (rc < 0) {
          throw FormatException('Invalid gzip stream: ${l2native.Lib2Native.lastError()}');
        }
      }
      return dst.readAsBytesSync();
    } finally {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }

  static String _path(Object o) => o is io.File ? o.path : (o is io.Directory ? o.path : o.toString());

  static String _absolute(String path) => io.File(path).absolute.path;

  /// The create format code for a destination's extension (zip=0, tar=2, tgz=3).
  static int _formatCode(String dst) {
    final p = dst.toLowerCase();
    if (p.endsWith('.tar.gz') || p.endsWith('.tgz')) return 3;
    if (p.endsWith('.tar')) return 2;
    return 0;
  }

  static int _foldCase() => (io.Platform.isWindows || io.Platform.isMacOS) ? 2 : 0;

  /// Deletes the file at [path] when there is one; never throws.
  static Future<void> _gone(String path) async {
    try {
      await io.File(path).delete();
    } catch (_) {
      // Nothing there, or already gone.
    }
  }

  /// Compresses the file at [src] as a gzip stream into [dst].
  static Future<void> _compressFile(String src, String dst, int level) async {
    final rc = l2native.Lib2Native.withText(src, (s, sn) {
      return l2native.Lib2Native.withText(dst, (d, dn) {
        return _ArchiveNative.compress(0, s, sn, d, dn, level, ffi.nullptr, ffi.nullptr);
      });
    });
    if (rc < 0) throw _archiveError(l2native.Lib2Native.lastError(), dst);
  }
}

/// One listed member with its kind bits.
final class _MemberRecord {
  final String name;
  final bool isDir;
  final bool isLink;

  _MemberRecord(this.name, this.isDir, this.isLink);
}

/// The `tk_archive_list` records of the archive at [path] (files, folders and links).
Future<List<_MemberRecord>> _listRecords(String path) async {
  final raw = l2native.Lib2Native.take('list $path', (out, len) {
    return l2native.Lib2Native.withText(path, (p, n) {
      return _ArchiveNative.list(p, n, ffi.nullptr, 0, out, len);
    });
  });
  final out = <_MemberRecord>[];
  final view = ByteData.sublistView(raw);
  var at = 0;
  while (at + 29 <= raw.length) {
    at += 16; // size + compressed: sizes travel with the data, not the listing.
    final flags = raw[at + 8];
    final nameLen = view.getUint32(at + 9, Endian.little);
    at += 13;
    if (at + nameLen > raw.length) throw FormatException('Invalid archive in $path: truncated listing');
    final name = utf8.decode(raw.sublist(at, at + nameLen), allowMalformed: true);
    at += nameLen;
    out.add(_MemberRecord(name, flags & 2 != 0, flags & 4 != 0));
  }
  return out;
}

/// What the native layer said about [path], as the exception it means.
Exception _archiveError(String message, String path) {
  if (message.contains('escapes destination') ||
      message.contains('leads out') ||
      message.contains('link to') ||
      message.contains('link that leaves')) {
    final at = message.indexOf(': ');
    return SecurityException(at < 0 ? message : message.substring(at + 2));
  }
  final m = RegExp(r'\(os error (\d+)\)').firstMatch(message);
  if (m != null) {
    final code = int.parse(m[1]!);
    final said = message.substring(0, m.start).trim();
    final at = said.lastIndexOf(': ');
    final error = io.OSError(at < 0 ? said : said.substring(at + 2), code);
    if (code == 2 || code == 3) return io.PathNotFoundException(path, error, 'Cannot open');
    return io.FileSystemException('Cannot open', path, error);
  }
  if (message.contains('no entry')) {
    final at = message.lastIndexOf(': no entry ');
    return MissingException(at < 0 ? message : message.substring(at + 11), where: path);
  }
  return FormatException('Invalid archive in $path: $message');
}

/// The native `tk_archive_*` calls behind [Archive] (Phase C rewrite, ABI 1).
abstract final class _ArchiveNative {
  static ffi.DynamicLibrary get _lib => l2native.Lib2Native.require();

  static final list = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
        )
      >('tk_archive_list');

  static final extract = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint32,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
        )
      >('tk_archive_extract');

  static final read = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint32,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
          ffi.Pointer<ffi.Uint8>,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
          ffi.Pointer<ffi.Uint8>,
        )
      >('tk_archive_read');

  static final create = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Uint32,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Int32,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
        ),
        int Function(
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
        )
      >('tk_archive_create');

  static final compress = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Uint32,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Int32,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
        ),
        int Function(
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
        )
      >('tk_compress');

  static final decompress = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Uint32,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint32,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
        ),
        int Function(
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
        )
      >('tk_decompress');

  static final open = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint32,
        ),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int, int)
      >('tk_archive_open');

  static final next = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.IntPtr>,
          ffi.Pointer<ffi.Uint64>,
          ffi.Pointer<ffi.Uint8>,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.IntPtr>,
          ffi.Pointer<ffi.Uint64>,
          ffi.Pointer<ffi.Uint8>,
        )
      >('tk_archive_next');

  static final entryRead = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int)
      >('tk_archive_entry_read');

  static final free = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>), void Function(ffi.Pointer<ffi.Void>)>(
        'tk_archive_free',
      );

  static final packCreate = _lib
      .lookupFunction<ffi.Pointer<ffi.Void> Function(ffi.Uint32, ffi.Int32), ffi.Pointer<ffi.Void> Function(int, int)>(
        'tk_archive_pack_create',
      );

  static final packAdd = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
        ),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int)
      >('tk_archive_pack_add');

  static final packFinish = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.IntPtr>),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.IntPtr>)
      >('tk_archive_pack_finish');

  static final packFree = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>), void Function(ffi.Pointer<ffi.Void>)>(
        'tk_archive_pack_free',
      );
}

/// A single member's bytes as a [Reader]: `pipe` moves them in chunks, so a
/// large member never needs a second copy beside the decoded bytes.
final class _MemberReader implements Reader {
  final Uint8List _data;
  int _pos = 0;

  _MemberReader(this._data);

  @override
  Future<int> read(Uint8List buf) async {
    if (_pos >= _data.length) return 0;
    final n = buf.length < _data.length - _pos ? buf.length : _data.length - _pos;
    buf.setRange(0, n, _data, _pos);
    _pos += n;
    return n;
  }
}

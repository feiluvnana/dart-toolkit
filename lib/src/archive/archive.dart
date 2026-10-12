import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/jobs.dart';
import '../core/native.dart' as l2native;
import '../core/traits.dart';
import '../fs/io.dart' as fs;

export '../core/errors.dart';
export '../core/pipe.dart';
export '../core/traits.dart';

/// Pack, unpack, list and read archives through the rewritten native
/// engine (`tk_archive_*`, ABI 2): ZIP, TAR and gzip plus 7z/RAR and the
/// xz/zst/bz2 streams. In-memory `zip`/`unzip`/`gzip`/`gunzip` go through the
/// same engine (via temporary files where the ABI is file-oriented).
///
/// ```dart
/// await Dir('site').pack(File('site.tar.zst'));
/// await File('site.tar.zst').unpack(Dir('out'));
/// final names = await File('site.tar.zst').entries();
/// ```
abstract final class Archive {
  /// Packs an in-memory map of names to bytes as a ZIP.
  ///
  /// A name over 65535 bytes is an [ArgumentError] (the zip format cannot
  /// store it). A finish failure never frees twice: the handle is owned by
  /// `packFinish` once called.
  static Uint8List zip(Map<String, List<int>> files, {int level = 6}) {
    _checkLevel(level);
    final h = _ArchiveNative.packCreate(0, level);
    if (h == ffi.nullptr) throw l2native.NativeException('pack zip', l2native.lastError());
    var finished = false;
    try {
      for (final e in files.entries) {
        final name = utf8.encode(e.key);
        final data = e.value is Uint8List ? e.value as Uint8List : Uint8List.fromList(e.value);
        final rc = l2native.withBytes(name, (np, nn) {
          return l2native.withBytes(data, (dp, dn) {
            return _ArchiveNative.packAdd(h, np, nn, dp, dn);
          });
        });
        if (rc < 0) {
          final message = l2native.lastError();
          if (message.contains('too long')) throw ArgumentError.value(e.key, 'files', message);
          throw l2native.NativeException('pack ${e.key}', message);
        }
      }
      finished = true;
      return l2native.take('pack zip', (out, len) => _ArchiveNative.packFinish(h, out, len));
    } catch (_) {
      if (!finished) _ArchiveNative.packFree(h);
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
      final h = l2native.withText(tmp.path, (p, n) {
        return _ArchiveNative.open(p, n, ffi.nullptr, 0, 0);
      });
      if (h == ffi.nullptr) throw _archiveError(l2native.lastError(), tmp.path);
      try {
        // Hoisted out of the walk: one entry costs two FFI calls, no allocs.
        final nameBuf = l2native.alloc(4096);
        final nameLenPtr = l2native.alloc(8).cast<ffi.IntPtr>();
        final sizePtr = l2native.alloc(8).cast<ffi.Uint64>();
        final dirPtr = l2native.alloc(1);
        final chunk = l2native.alloc(65536);
        try {
          while (true) {
            final rc = _ArchiveNative.next(h, nameBuf, 4096, nameLenPtr, sizePtr, dirPtr);
            if (rc < 0) throw _archiveError(l2native.lastError(), tmp.path);
            if (rc == 0) break;
            final name = utf8.decode(nameBuf.asTypedList(nameLenPtr.value));
            final builder = BytesBuilder(copy: true);
            while (true) {
              final n = _ArchiveNative.entryRead(h, chunk, 65536);
              if (n < 0) throw _archiveError(l2native.lastError(), tmp.path);
              if (n == 0) break;
              builder.add(chunk.asTypedList(n));
            }
            if (dirPtr.value == 0) out[name] = builder.takeBytes();
          }
        } finally {
          l2native.free(nameBuf, 4096);
          l2native.free(nameLenPtr.cast(), 8);
          l2native.free(sizePtr.cast(), 8);
          l2native.free(dirPtr, 1);
          l2native.free(chunk, 65536);
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
        final rc = l2native.withText(src.path, (s, sn) {
          return l2native.withText(dst.path, (d, dn) {
            return _ArchiveNative.compress(0, s, sn, d, dn, -1, ffi.nullptr, ffi.nullptr);
          });
        });
        if (rc < 0) throw _archiveError(l2native.lastError(), src.path);
      } else {
        final rc = l2native.withText(src.path, (s, sn) {
          return l2native.withText(dst.path, (d, dn) {
            return _ArchiveNative.decompress(0xFFFFFFFF, s, sn, d, dn, 0, ffi.nullptr, ffi.nullptr);
          });
        });
        if (rc < 0) {
          throw FormatException('Invalid gzip stream: ${l2native.lastError()}');
        }
      }
      return dst.readAsBytesSync();
    } finally {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }

  static String _absolute(String path) => io.File(path).absolute.path;

  /// The create format code for a destination's extension. NOTE: create codes
  /// differ from read codes — tar.xz=4, tar.zst=5, tar.bz2=6 here.
  static int _formatCode(String dst) {
    final p = dst.toLowerCase();
    if (p.endsWith('.tar.gz') || p.endsWith('.tgz')) return 3;
    if (p.endsWith('.tar.xz') || p.endsWith('.txz')) return 4;
    if (p.endsWith('.tar.zst') || p.endsWith('.tzst')) return 5;
    if (p.endsWith('.tar.bz2') || p.endsWith('.tbz2')) return 6;
    if (p.endsWith('.tar')) return 2;
    return 0;
  }

  static int _foldCase() => (io.Platform.isWindows || io.Platform.isMacOS) ? 2 : 0;

  /// Compression levels run 0..9 (anything else is an [ArgumentError] here,
  /// not a native failure there).
  static void _checkLevel(int level) {
    if (level < 0 || level > 9) throw ArgumentError.value(level, 'level', 'Compression level is 0..9');
  }

  /// Deletes the file at [path] when there is one; never throws.
  static Future<void> _gone(String path) async {
    try {
      await io.File(path).delete();
    } catch (_) {
      // Nothing there, or already gone.
    }
  }

  /// Compresses the file at [src] as a [codec] stream into [dst], on a native thread.
  static Future<void> _compressFile(String src, String dst, int level, int codec) async {
    try {
      await nativeCount(
        'compress $src',
        l2native.engineJobs,
        (done, stop, progress, id) => l2native.withText(
          src,
          (s, sn) => l2native.withText(
            dst,
            (d, dn) => _ArchiveNative.compressFile(codec, s, sn, d, dn, level, done, stop, progress, id),
          ),
        ),
      );
    } on l2native.NativeException catch (e) {
      throw _archiveError(e.message, dst);
    }
  }
}

/// Unpacks any archive source into a directory.
extension SourceUnpack on Source {
  /// Unpacks into [dir] (made if missing), streaming: nothing lands on disk first. Every
  /// member is checked before it is written: escapes are a SecurityException, and every
  /// symlink/hardlink member is refused unless [trusted]. A failed stream removes what
  /// it created, leaving the destination as it was. Answers the number of files written.
  ///
  /// [onProgress] hears an archive file's bytes unpacked and the total; a streamed source
  /// reports through its own reads instead.
  Future<int> unpack(fs.Dir dir, {bool trusted = false, void Function(int done, int total)? onProgress}) async {
    if (this case final fs.File f) {
      return _unpackFile(f.path, dir.path, trusted: trusted, onProgress: onProgress);
    }
    final r = await reader();
    try {
      final hint = lengthHint ?? 0;
      final flags = Archive._foldCase() | (trusted ? 1 : 0);
      final h = l2native.withText(dir.path, (dp, dn) {
        return _ArchiveNative.unpackOpen(dp, dn, flags, hint, ffi.nullptr, 0);
      });
      if (h == ffi.nullptr) throw l2native.NativeException('open unpack', l2native.lastError());
      var finishQueued = false;
      try {
        final chunk = Uint8List(64 * 1024);
        Object? readError;
        var writeBroken = false;
        while (readError == null && !writeBroken) {
          int n;
          try {
            n = await r.read(chunk);
          } catch (e) {
            readError = e;
            break;
          }
          if (n <= 0) break;
          final bytes = Uint8List.sublistView(chunk, 0, n);
          final rc = l2native.withBytes(bytes, (p, len) {
            return _ArchiveNative.unpackWrite(h, p, len);
          });
          // The worker may end early (trailing padding) or fail mid-stream: either
          // way `unpackFinish` holds the truth (the count, or the real refusal).
          if (rc < 0) {
            writeBroken = true;
          } else if (rc == 1) {
            // Queue full: send on a worker thread with backpressure instead of
            // blocking the event loop (the sync write never waits).
            try {
              await nativeCount(
                'unpack into ${dir.path}',
                l2native.engineJobs,
                (done, stop, progress, id) => l2native.withBytes(bytes, (p, len) {
                  return _ArchiveNative.unpackWriteAsync(h, p, len, done, stop);
                }),
              );
            } on l2native.NativeException catch (e) {
              if (e.message.contains('worker is gone')) {
                writeBroken = true;
              } else {
                readError ??= _archiveError(e.message, dir.path);
                break;
              }
            }
          }
        }
        // Join the worker even when the source failed: its cleanup (removing what
        // a failed stream created) runs before this returns, so no partial output
        // races the caller. The source's own error still wins below.
        // Ownership moves to the finish job: never free after queueing it.
        int count;
        try {
          finishQueued = true;
          count = await nativeCount(
            'unpack into ${dir.path}',
            l2native.engineJobs,
            (done, stop, progress, id) => _ArchiveNative.unpackFinish(h, done, stop),
          );
        } on l2native.NativeException catch (e) {
          if (readError != null) throw readError;
          throw _archiveError(e.message, dir.path);
        }
        if (readError != null) throw readError;
        return count;
      } finally {
        if (!finishQueued) _ArchiveNative.unpackFree(h);
      }
    } finally {
      await r.close();
    }
  }
}

/// Archives of one file: its entries, one entry as a [Source], packing.
extension FileArchive on fs.File {
  /// The entry names inside (files, not directories or links).
  Future<List<String>> entries() async => [
    for (final m in await _listRecords(Archive._absolute(path)))
      if (!m.isDir && !m.isLink) m.name,
  ];

  /// The single member [name] as a [Source], streaming through the native
  /// stepper without materializing the rest. A missing member is a
  /// [MissingException]; a link member is a [SecurityException], as links are
  /// never materialized.
  Source entry(String name) => _EntrySource(Archive._absolute(path), name);

  /// Packs this file as a single `.gz`/`.zst` stream into [to].
  Future<void> pack(fs.File to, {int level = 6}) async {
    Archive._checkLevel(level);
    final lower = to.path.toLowerCase();
    final codec = lower.endsWith('.gz')
        ? 0
        : lower.endsWith('.zst') || lower.endsWith('.zstd')
        ? 2
        : throw ArgumentError.value(to.path, 'to', 'A file packs to .gz or .zst');
    await Archive._compressFile(path, to.path, level, codec);
  }
}

/// Packing a directory.
extension DirArchive on fs.Dir {
  /// Packs this directory into [to]. The extension of [to] picks the format:
  /// `.zip`, `.tar`, `.tar.gz`/`.tgz`, `.tar.xz`/`.txz`, `.tar.zst`/`.tzst`
  /// or `.tar.bz2`/`.tbz2`. A bare `.gz` is an [ArgumentError] (a directory
  /// needs a container), as are `.rar` and `.7z` (pack cannot write them).
  /// Packing runs on a native thread; [onProgress] hears bytes packed and the
  /// total.
  Future<void> pack(fs.File to, {int level = 6, void Function(int done, int total)? onProgress}) async {
    Archive._checkLevel(level);
    final target = to.path;
    final lower = target.toLowerCase();
    if (lower.endsWith('.gz') && !lower.endsWith('.tar.gz') && !lower.endsWith('.tgz')) {
      throw ArgumentError.value(
        to.path,
        'to',
        'A directory packs to a container (.zip, .tar, .tar.gz …), not a bare .gz',
      );
    }
    if (lower.endsWith('.rar')) {
      throw ArgumentError.value(to.path, 'to', 'rar can only be read; write .zip or .tar.gz instead');
    }
    if (lower.endsWith('.7z')) {
      throw ArgumentError.value(to.path, 'to', '7z can only be read; write .zip or .tar.gz instead');
    }
    final format = Archive._formatCode(target);
    final tmp = '$target.tmp_${DateTime.now().microsecondsSinceEpoch}';
    try {
      try {
        await nativeCount(
          'pack $target',
          l2native.engineJobs,
          (done, stop, progress, id) => l2native.withText(Archive._absolute(path), (s, sn) {
            return l2native.withText(Archive._absolute(target), (d, dn) {
              return l2native.withText(tmp, (o, on) {
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
                  done,
                  stop,
                  progress,
                  id,
                );
              });
            });
          }),
          onProgress: onProgress,
        );
      } on l2native.NativeException catch (e) {
        throw _archiveError(e.message, target);
      }
      // The engine wrote a temporary (so the destination is never half-written);
      // the destination is skipped when it sits under the source, so packing into
      // one's own tree never archives the half-written output.
      await fs.renameFile(tmp, target);
    } catch (_) {
      await Archive._gone(tmp);
      rethrow;
    }
  }
}

/// Unpacks the archive file at [src] into [dst] (made if missing): the
/// container is detected from magic bytes, every member validated before
/// anything is written. Every link member is refused unless [trusted].
/// Answers the number of files written.
Future<int> _unpackFile(
  String src,
  String dst, {
  bool trusted = false,
  void Function(int done, int total)? onProgress,
}) async {
  final path = Archive._absolute(src);
  final root = Archive._absolute(dst);
  final members = await _listRecords(path);
  for (final m in members) {
    await fs.sandbox(root, m.name);
    if (m.isLink && !trusted) throw SecurityException('Refused link member: ${m.name}');
  }
  final flags = Archive._foldCase() | (trusted ? 1 : 0);
  try {
    return await nativeCount(
      'unpack $path',
      l2native.engineJobs,
      (done, stop, progress, id) => l2native.withText(path, (p, n) {
        return l2native.withText(root, (d, dn) {
          return _ArchiveNative.extract(p, n, d, dn, ffi.nullptr, 0, ffi.nullptr, 0, flags, done, stop, progress, id);
        });
      }),
      onProgress: onProgress,
    );
  } on l2native.NativeException catch (e) {
    throw _archiveError(e.message, path);
  }
}

/// One archive member as a [Source]: opened on first read, streamed through
/// the native stepper, so a large member never lands on disk whole.
final class _EntrySource implements Source {
  final String _archive;
  final String _member;

  _EntrySource(this._archive, this._member);

  /// A member's length is not listed up front.
  @override
  int? get lengthHint => null;

  @override
  Future<Reader> reader({int from = 0}) async {
    if (from < 0) throw ArgumentError.value(from, 'from', 'Must be non-negative');
    final members = await _listRecords(_archive);
    final want = _member.replaceAll('\\', '/');
    _MemberRecord? hit;
    try {
      hit = members.firstWhere((m) => m.name.replaceAll('\\', '/') == want);
    } on StateError {
      throw MissingException(_member, where: _archive);
    }
    if (hit.isLink) throw SecurityException('Refused link member: ${hit.name}');
    if (hit.isDir) throw MissingException(_member, where: _archive);
    final name = hit.name;
    final h = l2native.withText(_archive, (p, n) {
      return _ArchiveNative.open(p, n, ffi.nullptr, 0, 0);
    });
    if (h == ffi.nullptr) throw l2native.NativeException('open archive', l2native.lastError());
    var done = false;
    try {
      final nameBuf = l2native.alloc(4096);
      try {
        while (true) {
          final entryName = _stepNext(h, nameBuf);
          if (entryName == null) throw MissingException(_member, where: _archive);
          if (entryName == name) break;
          _discardEntry(h);
        }
      } finally {
        l2native.free(nameBuf, 4096);
      }
      var skip = from;
      if (skip > 0) {
        final buf = l2native.alloc(65536);
        try {
          while (skip > 0) {
            final n = _ArchiveNative.entryRead(h, buf, skip < 65536 ? skip : 65536);
            if (n < 0) throw l2native.NativeException('read $_member', l2native.lastError());
            if (n == 0) break;
            skip -= n;
          }
        } finally {
          l2native.free(buf, 65536);
        }
      }
      done = true;
      return _EntryReader(h, _member);
    } finally {
      if (!done) _ArchiveNative.free(h);
    }
  }
}

/// Steps the stepper [h] once, answering the entry name (null at the end).
String? _stepNext(ffi.Pointer<ffi.Void> h, ffi.Pointer<ffi.Uint8> nameBuf) {
  final nameLenPtr = l2native.alloc(8).cast<ffi.IntPtr>();
  final sizePtr = l2native.alloc(8).cast<ffi.Uint64>();
  final dirPtr = l2native.alloc(1);
  try {
    final rc = _ArchiveNative.next(h, nameBuf, 4096, nameLenPtr, sizePtr, dirPtr);
    if (rc < 0) throw l2native.NativeException('step archive', l2native.lastError());
    if (rc == 0) return null;
    return utf8.decode(nameBuf.asTypedList(nameLenPtr.value));
  } finally {
    l2native.free(nameLenPtr.cast(), 8);
    l2native.free(sizePtr.cast(), 8);
    l2native.free(dirPtr, 1);
  }
}

/// Reads the current stepper entry to its end, discarding the bytes.
void _discardEntry(ffi.Pointer<ffi.Void> h) {
  final buf = l2native.alloc(65536);
  try {
    while (true) {
      final n = _ArchiveNative.entryRead(h, buf, 65536);
      if (n < 0) throw l2native.NativeException('skip archive entry', l2native.lastError());
      if (n == 0) break;
    }
  } finally {
    l2native.free(buf, 65536);
  }
}

/// A [Reader] over one archive member, streaming through the stepper handle.
/// A finalizer frees the stepper when the reader is dropped without [close].
final class _EntryReader implements Reader, ffi.Finalizable {
  final ffi.Pointer<ffi.Void> _h;
  final String _member;
  var _closed = false;

  static final _finalizer = ffi.NativeFinalizer(
    l2native.require().lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>('tk_archive_free').cast(),
  );

  _EntryReader(this._h, this._member) {
    _finalizer.attach(this, _h, detach: this);
  }

  @override
  Future<int> read(Uint8List buf) async {
    if (_closed) throw StateError('Cannot read: entry is closed');
    if (buf.isEmpty) return 0;
    final ptr = l2native.alloc(buf.length);
    try {
      final n = _ArchiveNative.entryRead(_h, ptr, buf.length);
      if (n < 0) throw l2native.NativeException('read $_member', l2native.lastError());
      if (n == 0) return 0;
      buf.setRange(0, n, ptr.asTypedList(n));
      return n;
    } finally {
      l2native.free(ptr, buf.length);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _finalizer.detach(this);
    _ArchiveNative.free(_h);
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
  final Uint8List raw;
  try {
    raw = await nativeJob(
      'list $path',
      l2native.engineJobs,
      (done, stop, progress, id) =>
          l2native.withText(path, (p, n) => _ArchiveNative.list(p, n, ffi.nullptr, 0, done, stop)),
    );
  } on l2native.NativeException catch (e) {
    throw _archiveError(e.message, path);
  }
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
      message.contains('link that leaves') ||
      message.contains('link member') ||
      message.contains('refused link')) {
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

/// The native `tk_archive_*` calls behind [Archive] (native ABI 2).
abstract final class _ArchiveNative {
  static ffi.DynamicLibrary get _lib => l2native.require();

  static final list = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
        )
      >('tk_archive_list_async');

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
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
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
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_archive_extract_async');

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
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
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
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_archive_create_async');

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

  static final compressFile = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Uint32,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Int32,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_compress_async');

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

  static final unpackOpen = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint32,
          ffi.Uint64,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          int,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_unpack_open');

  static final unpackWrite = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int)
      >('tk_unpack_write');

  static final unpackWriteAsync = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
        )
      >('tk_unpack_write_async');

  static final unpackFinish = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.NativeFunction<DoneFn>>, ffi.Pointer<ffi.Uint8>),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.NativeFunction<DoneFn>>, ffi.Pointer<ffi.Uint8>)
      >('tk_unpack_finish_async');

  static final unpackFree = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>), void Function(ffi.Pointer<ffi.Void>)>('tk_unpack_free');
}

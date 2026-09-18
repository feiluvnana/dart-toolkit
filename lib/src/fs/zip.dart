// The zip container: local headers, a central directory, an end record, ZIP64 when sizes
// or counts overflow. Compression is dart:io's native zlib.

part of '../../fs.dart';

const _sigLocal = 0x04034b50;
const _sigCentral = 0x02014b50;
const _sigEnd = 0x06054b50;
const _sigDescriptor = 0x08074b50;
const _sigZip64End = 0x06064b50;
const _sigZip64Locator = 0x07064b50;
const _max32 = 0xFFFFFFFF;
const _max16 = 0xFFFF;
const _methodStored = 0;
const _methodDeflate = 8;
const _flagDescriptor = 0x0008;
const _flagUtf8 = 0x0800;
const _flagEncrypted = 0x0001;

/// Bytes written to a zip before the writer waits for the disk; see `download`.
const _zipFlushEvery = 4 * 1024 * 1024;

/// One entry of a zip archive, as its central directory describes it.
///
/// {@category Files}
final class ZipEntry {
  /// The path inside the archive, `/`-separated; a directory ends in `/`.
  final String name;

  /// Uncompressed bytes.
  final int size;

  /// Bytes as stored in the archive.
  final int compressedSize;

  /// CRC-32 of the uncompressed bytes.
  final int crc32;

  /// Last modification, to DOS precision (two seconds).
  final DateTime modified;

  final int _method;
  final int _flags;
  final int _offset;

  const ZipEntry._({
    required this.name,
    required this.size,
    required this.compressedSize,
    required this.crc32,
    required this.modified,
    required int method,
    required int flags,
    required int offset,
  }) : _method = method,
       _flags = flags,
       _offset = offset;

  /// Whether this entry is a directory.
  bool get isDir => name.endsWith('/');

  @override
  String toString() => '$name ($size bytes)';
}

// ---------------------------------------------------------------------------------------------
// Little-endian record building and parsing
// ---------------------------------------------------------------------------------------------

final class _Bytes {
  final BytesBuilder _b = BytesBuilder(copy: false);
  final ByteData _scratch = ByteData(8);

  void u16(int v) {
    _scratch.setUint16(0, v, Endian.little);
    _b.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 2)));
  }

  void u32(int v) {
    _scratch.setUint32(0, v, Endian.little);
    _b.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 4)));
  }

  void u64(int v) {
    _scratch.setUint64(0, v, Endian.little);
    _b.add(Uint8List.fromList(_scratch.buffer.asUint8List(0, 8)));
  }

  void bytes(List<int> v) => _b.add(v);

  Uint8List take() => _b.takeBytes();
}

(int date, int time) _dosDateTime(DateTime t) {
  final l = t.toLocal();
  final year = l.year.clamp(1980, 2107);
  final date = ((year - 1980) << 9) | (l.month << 5) | l.day;
  final time = (l.hour << 11) | (l.minute << 5) | (l.second >> 1);
  return (date, time);
}

DateTime _fromDosDateTime(int date, int time) =>
    DateTime(1980 + (date >> 9), (date >> 5) & 0xf, date & 0x1f, time >> 11, (time >> 5) & 0x3f, (time & 0x1f) << 1);

/// A conversion sink that hands every produced chunk to [_out] as it appears.
final class _ChunkSink extends ByteConversionSink {
  final void Function(List<int> chunk) _out;

  _ChunkSink(this._out);

  @override
  void add(List<int> chunk) => _out(chunk);

  @override
  void close() {}
}

// ---------------------------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------------------------

final class _PendingEntry {
  final String name;
  final int method;
  final int flags;
  final int date;
  final int time;
  final int offset;
  final bool zip64;
  final int externalAttributes;
  int crc = 0;
  int compressedSize = 0;
  int size = 0;

  _PendingEntry(
    this.name,
    this.method,
    this.flags,
    this.date,
    this.time,
    this.offset, {
    required this.zip64,
    required this.externalAttributes,
  });
}

/// Builds the records of a zip archive; the caller supplies the bytes and the byte sink.
final class _ZipWriter {
  final List<_PendingEntry> _entries = [];
  int written = 0;

  /// The local header; sizes and CRC follow the data in a descriptor.
  Uint8List localHeader(_PendingEntry e) {
    final name = utf8.encode(e.name);
    final b = _Bytes()
      ..u32(_sigLocal)
      ..u16(e.zip64 ? 45 : 20)
      ..u16(e.flags)
      ..u16(e.method)
      ..u16(e.time)
      ..u16(e.date)
      ..u32(0)
      ..u32(e.zip64 ? _max32 : 0)
      ..u32(e.zip64 ? _max32 : 0)
      ..u16(name.length)
      ..u16(e.zip64 ? 20 : 0)
      ..bytes(name);
    if (e.zip64) {
      b
        ..u16(0x0001)
        ..u16(16)
        ..u64(0)
        ..u64(0);
    }
    return b.take();
  }

  Uint8List descriptor(_PendingEntry e) {
    final b = _Bytes()
      ..u32(_sigDescriptor)
      ..u32(e.crc);
    if (e.zip64) {
      b
        ..u64(e.compressedSize)
        ..u64(e.size);
    } else {
      b
        ..u32(e.compressedSize)
        ..u32(e.size);
    }
    return b.take();
  }

  _PendingEntry begin(
    String name, {
    required DateTime modified,
    required int size,
    required bool isDir,
    required int mode,
  }) {
    final (date, time) = _dosDateTime(modified);
    // Deflate can grow an incompressible input by a fraction of a percent; leave room.
    final zip64 = size >= _max32 - (1 << 20) || written >= _max32;
    final e = _PendingEntry(
      name,
      isDir ? _methodStored : _methodDeflate,
      _flagUtf8 | (isDir ? 0 : _flagDescriptor),
      date,
      time,
      written,
      zip64: zip64,
      externalAttributes: mode << 16,
    );
    _entries.add(e);
    return e;
  }

  /// The central directory and end records, once every entry has been written.
  Uint8List finish() {
    final cdOffset = written;
    final b = _Bytes();
    var needZip64 = _entries.length >= _max16 || cdOffset >= _max32;
    for (final e in _entries) {
      final name = utf8.encode(e.name);
      final bigSize = e.size >= _max32, bigCSize = e.compressedSize >= _max32, bigOffset = e.offset >= _max32;
      final extra = _Bytes();
      if (bigSize || bigCSize || bigOffset) {
        needZip64 = true;
        final fields = _Bytes();
        if (bigSize) fields.u64(e.size);
        if (bigCSize) fields.u64(e.compressedSize);
        if (bigOffset) fields.u64(e.offset);
        final f = fields.take();
        extra
          ..u16(0x0001)
          ..u16(f.length)
          ..bytes(f);
      }
      final extraBytes = extra.take();
      b
        ..u32(_sigCentral)
        ..u16((3 << 8) | 45) // made by: unix, 4.5
        ..u16(e.zip64 || extraBytes.isNotEmpty ? 45 : 20)
        ..u16(e.flags)
        ..u16(e.method)
        ..u16(e.time)
        ..u16(e.date)
        ..u32(e.crc)
        ..u32(bigCSize ? _max32 : e.compressedSize)
        ..u32(bigSize ? _max32 : e.size)
        ..u16(name.length)
        ..u16(extraBytes.length)
        ..u16(0)
        ..u16(0)
        ..u16(0)
        ..u32(e.externalAttributes)
        ..u32(bigOffset ? _max32 : e.offset)
        ..bytes(name)
        ..bytes(extraBytes);
    }
    final cd = b.take();
    final end = _Bytes();
    if (needZip64 || cd.length >= _max32) {
      final zip64EndOffset = cdOffset + cd.length;
      end
        ..u32(_sigZip64End)
        ..u64(44)
        ..u16((3 << 8) | 45)
        ..u16(45)
        ..u32(0)
        ..u32(0)
        ..u64(_entries.length)
        ..u64(_entries.length)
        ..u64(cd.length)
        ..u64(cdOffset)
        ..u32(_sigZip64Locator)
        ..u32(0)
        ..u64(zip64EndOffset)
        ..u32(1);
    }
    final count = _entries.length >= _max16 ? _max16 : _entries.length;
    end
      ..u32(_sigEnd)
      ..u16(0)
      ..u16(0)
      ..u16(count)
      ..u16(count)
      ..u32(cd.length >= _max32 ? _max32 : cd.length)
      ..u32(cdOffset >= _max32 ? _max32 : cdOffset)
      ..u16(0);
    final tail = end.take();
    final out = BytesBuilder(copy: false)
      ..add(cd)
      ..add(tail);
    return out.takeBytes();
  }
}

/// The files and directories under [root], as `(relative name, entity)` in a stable order.
Future<List<(String, FileSystemEntity)>> _walk(Directory root) async {
  final out = <(String, FileSystemEntity)>[];
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is File || e is Directory) out.add((_entryName(root.path, e), e));
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}

List<(String, FileSystemEntity)> _walkSync(Directory root) {
  final out = <(String, FileSystemEntity)>[
    for (final e in root.listSync(recursive: true, followLinks: false))
      if (e is File || e is Directory) (_entryName(root.path, e), e),
  ];
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}

String _entryName(String root, FileSystemEntity e) {
  var rel = p.relative(e.path, from: root);
  if (Platform.isWindows) rel = rel.replaceAll(r'\', '/');
  return e is Directory ? '$rel/' : rel;
}

int _modeOf(FileSystemEntity e, FileStat stat) =>
    e is Directory ? 0x41ED : (stat.mode & 0xFFF) | 0x8000; // 040755 / 0100xxx

Future<File> _zip(Path source, String destination, int level) async {
  final zipFile = File(destination);
  await zipFile.parent.create(recursive: true);
  final type = await source.type();
  final items = switch (type) {
    PathType.dir => await _walk(source.asDir),
    PathType.file => [(source.name, source.asFile as FileSystemEntity)],
    _ => throw FileSystemException('Cannot zip a path that does not exist', source),
  };
  final sink = zipFile.openWrite();
  final w = _ZipWriter();
  var unflushed = 0;
  Future<void> add(List<int> bytes) async {
    sink.add(bytes);
    w.written += bytes.length;
    unflushed += bytes.length;
    if (unflushed >= _zipFlushEvery) {
      unflushed = 0;
      await sink.flush();
    }
  }

  try {
    for (final (name, entity) in items) {
      final stat = await entity.stat();
      final isDir = entity is Directory;
      final e = w.begin(
        name,
        modified: stat.modified,
        size: isDir ? 0 : stat.size,
        isDir: isDir,
        mode: _modeOf(entity, stat),
      );
      await add(w.localHeader(e));
      if (isDir) continue;
      final crc = Crc32();
      var compressed = 0;
      final pending = <List<int>>[];
      final deflate = ZLibEncoder(raw: true, level: level).startChunkedConversion(_ChunkSink(pending.add));
      await for (final chunk in (entity as File).openRead()) {
        crc.add(chunk);
        deflate.add(chunk);
        for (final c in pending) {
          compressed += c.length;
          await add(c);
        }
        pending.clear();
      }
      deflate.close();
      for (final c in pending) {
        compressed += c.length;
        await add(c);
      }
      e
        ..crc = crc.value
        ..size = crc.length
        ..compressedSize = compressed;
      await add(w.descriptor(e));
    }
    await add(w.finish());
  } finally {
    await sink.close();
  }
  return zipFile;
}

File _zipSync(Path source, String destination, int level) {
  final zipFile = File(destination);
  zipFile.parent.createSync(recursive: true);
  final items = switch (source.typeSync()) {
    PathType.dir => _walkSync(source.asDir),
    PathType.file => [(source.name, source.asFile as FileSystemEntity)],
    _ => throw FileSystemException('Cannot zip a path that does not exist', source),
  };
  final raf = zipFile.openSync(mode: FileMode.write);
  final w = _ZipWriter();
  void add(List<int> bytes) {
    raf.writeFromSync(bytes);
    w.written += bytes.length;
  }

  try {
    final buffer = Uint8List(64 * 1024);
    for (final (name, entity) in items) {
      final stat = entity.statSync();
      final isDir = entity is Directory;
      final e = w.begin(
        name,
        modified: stat.modified,
        size: isDir ? 0 : stat.size,
        isDir: isDir,
        mode: _modeOf(entity, stat),
      );
      add(w.localHeader(e));
      if (isDir) continue;
      final crc = Crc32();
      var compressed = 0;
      final deflate = ZLibEncoder(raw: true, level: level).startChunkedConversion(
        _ChunkSink((c) {
          compressed += c.length;
          add(c);
        }),
      );
      final input = (entity as File).openSync();
      try {
        while (true) {
          final n = input.readIntoSync(buffer);
          if (n == 0) break;
          final chunk = Uint8List.sublistView(buffer, 0, n);
          crc.add(chunk);
          deflate.add(Uint8List.fromList(chunk));
        }
      } finally {
        input.closeSync();
      }
      deflate.close();
      e
        ..crc = crc.value
        ..size = crc.length
        ..compressedSize = compressed;
      add(w.descriptor(e));
    }
    add(w.finish());
  } finally {
    raf.closeSync();
  }
  return zipFile;
}

// ---------------------------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------------------------

final class _ZipReader {
  final RandomAccessFile _file;
  final int _length;

  _ZipReader._(this._file, this._length);

  static Future<_ZipReader> open(File file) async => _ZipReader._(await file.open(), await file.length());

  static _ZipReader openSync(File file) => _ZipReader._(file.openSync(), file.lengthSync());

  Future<void> close() => _file.close();
  void closeSync() => _file.closeSync();

  Future<Uint8List> _read(int offset, int length) async {
    await _file.setPosition(offset);
    return _file.read(length);
  }

  Uint8List _readSync(int offset, int length) {
    _file.setPositionSync(offset);
    return _file.readSync(length);
  }

  Future<List<ZipEntry>> entries() async {
    final tailStart = _length - (_length < 66 * 1024 ? _length : 66 * 1024);
    final tail = await _read(tailStart, _length - tailStart);
    final (cdOffset, cdSize) = await _directoryLocation(tail, tailStart, (o, n) => _read(o, n));
    return _parseDirectory(await _read(cdOffset, cdSize));
  }

  List<ZipEntry> entriesSync() {
    final tailStart = _length - (_length < 66 * 1024 ? _length : 66 * 1024);
    final tail = _readSync(tailStart, _length - tailStart);
    final (cdOffset, cdSize) = _directoryLocationSync(tail, tailStart);
    return _parseDirectory(_readSync(cdOffset, cdSize));
  }

  /// Finds the end record in [tail] and returns where the central directory is.
  (int, int) _directoryLocationSync(Uint8List tail, int tailStart) {
    final eocd = _findEnd(tail);
    final d = ByteData.sublistView(tail);
    var count = d.getUint16(eocd + 10, Endian.little);
    var cdSize = d.getUint32(eocd + 12, Endian.little);
    var cdOffset = d.getUint32(eocd + 16, Endian.little);
    if (count == _max16 || cdSize == _max32 || cdOffset == _max32) {
      final loc = eocd - 20;
      if (loc >= 0 && d.getUint32(loc, Endian.little) == _sigZip64Locator) {
        final z64 = d.getUint64(loc + 8, Endian.little);
        final rec = _readSync(z64, 56);
        final r = ByteData.sublistView(rec);
        if (r.getUint32(0, Endian.little) != _sigZip64End) throw const FormatException('Bad ZIP64 end record');
        cdSize = r.getUint64(40, Endian.little);
        cdOffset = r.getUint64(48, Endian.little);
      }
    }
    return (cdOffset, cdSize);
  }

  Future<(int, int)> _directoryLocation(
    Uint8List tail,
    int tailStart,
    Future<Uint8List> Function(int, int) read,
  ) async {
    final eocd = _findEnd(tail);
    final d = ByteData.sublistView(tail);
    final count = d.getUint16(eocd + 10, Endian.little);
    var cdSize = d.getUint32(eocd + 12, Endian.little);
    var cdOffset = d.getUint32(eocd + 16, Endian.little);
    if (count == _max16 || cdSize == _max32 || cdOffset == _max32) {
      final loc = eocd - 20;
      if (loc >= 0 && d.getUint32(loc, Endian.little) == _sigZip64Locator) {
        final z64 = d.getUint64(loc + 8, Endian.little);
        final r = ByteData.sublistView(await read(z64, 56));
        if (r.getUint32(0, Endian.little) != _sigZip64End) throw const FormatException('Bad ZIP64 end record');
        cdSize = r.getUint64(40, Endian.little);
        cdOffset = r.getUint64(48, Endian.little);
      }
    }
    return (cdOffset, cdSize);
  }

  static int _findEnd(Uint8List tail) {
    final d = ByteData.sublistView(tail);
    for (var i = tail.length - 22; i >= 0; i--) {
      if (d.getUint32(i, Endian.little) == _sigEnd) return i;
    }
    throw const FormatException('Not a zip archive: no end record');
  }

  static List<ZipEntry> _parseDirectory(Uint8List cd) {
    final d = ByteData.sublistView(cd);
    final out = <ZipEntry>[];
    var i = 0;
    while (i + 46 <= cd.length && d.getUint32(i, Endian.little) == _sigCentral) {
      final flags = d.getUint16(i + 8, Endian.little);
      final method = d.getUint16(i + 10, Endian.little);
      final time = d.getUint16(i + 12, Endian.little);
      final date = d.getUint16(i + 14, Endian.little);
      final crc = d.getUint32(i + 16, Endian.little);
      var csize = d.getUint32(i + 20, Endian.little);
      var size = d.getUint32(i + 24, Endian.little);
      final nameLen = d.getUint16(i + 28, Endian.little);
      final extraLen = d.getUint16(i + 30, Endian.little);
      final commentLen = d.getUint16(i + 32, Endian.little);
      var offset = d.getUint32(i + 42, Endian.little);
      final nameBytes = Uint8List.sublistView(cd, i + 46, i + 46 + nameLen);
      final name = _decodeName(nameBytes, flags);
      // ZIP64 extra: the fields marked 0xFFFFFFFF, in order size, compressed size, offset.
      var x = i + 46 + nameLen;
      final xEnd = x + extraLen;
      while (x + 4 <= xEnd) {
        final id = d.getUint16(x, Endian.little);
        final len = d.getUint16(x + 2, Endian.little);
        if (id == 0x0001) {
          var f = x + 4;
          if (size == _max32 && f + 8 <= x + 4 + len) {
            size = d.getUint64(f, Endian.little);
            f += 8;
          }
          if (csize == _max32 && f + 8 <= x + 4 + len) {
            csize = d.getUint64(f, Endian.little);
            f += 8;
          }
          if (offset == _max32 && f + 8 <= x + 4 + len) offset = d.getUint64(f, Endian.little);
        }
        x += 4 + len;
      }
      out.add(
        ZipEntry._(
          name: name,
          size: size,
          compressedSize: csize,
          crc32: crc,
          modified: _fromDosDateTime(date, time),
          method: method,
          flags: flags,
          offset: offset,
        ),
      );
      i += 46 + nameLen + extraLen + commentLen;
    }
    return out;
  }

  /// Where an entry's data starts: past its local header, name and extra field.
  int _dataStart(Uint8List local, ZipEntry e) {
    final d = ByteData.sublistView(local);
    if (d.getUint32(0, Endian.little) != _sigLocal) throw FormatException('Bad local header for ${e.name}');
    return e._offset + 30 + d.getUint16(26, Endian.little) + d.getUint16(28, Endian.little);
  }

  void _check(ZipEntry e) {
    if ((e._flags & _flagEncrypted) != 0) throw UnsupportedError('Encrypted entry: ${e.name}');
    if (e._method != _methodStored && e._method != _methodDeflate) {
      throw UnsupportedError('Compression method ${e._method} on ${e.name}');
    }
  }

  Future<void> extract(ZipEntry e, File target, File source) async {
    _check(e);
    final start = _dataStart(await _read(e._offset, 30), e);
    await target.parent.create(recursive: true);
    final out = target.openWrite();
    final crc = Crc32();
    try {
      var data = source.openRead(start, start + e.compressedSize);
      if (e._method == _methodDeflate) data = data.transform(ZLibDecoder(raw: true));
      var unflushed = 0;
      await for (final chunk in data) {
        crc.add(chunk);
        out.add(chunk);
        unflushed += chunk.length;
        if (unflushed >= _zipFlushEvery) {
          unflushed = 0;
          await out.flush();
        }
      }
    } finally {
      await out.close();
    }
    _verify(e, crc);
  }

  void extractSync(ZipEntry e, File target) {
    _check(e);
    final start = _dataStart(_readSync(e._offset, 30), e);
    target.parent.createSync(recursive: true);
    final out = target.openSync(mode: FileMode.write);
    final crc = Crc32();
    try {
      final sink = _ChunkSink((c) {
        crc.add(c);
        out.writeFromSync(c);
      });
      final inflate = e._method == _methodDeflate ? ZLibDecoder(raw: true).startChunkedConversion(sink) : sink;
      _file.setPositionSync(start);
      var left = e.compressedSize;
      final buffer = Uint8List(64 * 1024);
      while (left > 0) {
        final n = _file.readIntoSync(buffer, 0, left < buffer.length ? left : buffer.length);
        if (n == 0) throw FormatException('Truncated entry: ${e.name}');
        inflate.add(Uint8List.fromList(Uint8List.sublistView(buffer, 0, n)));
        left -= n;
      }
      inflate.close();
    } finally {
      out.closeSync();
    }
    _verify(e, crc);
  }

  static void _verify(ZipEntry e, Crc32 crc) {
    if (crc.length != e.size || crc.value != e.crc32) {
      throw FormatException('Corrupt entry ${e.name}: expected ${e.size} bytes, CRC ${e.crc32.toRadixString(16)}');
    }
  }
}

/// UTF-8 when the flag says so or the bytes happen to be valid UTF-8 (most writers never set
/// the flag), else Latin-1 as the nearest thing to the CP437 the format assumes.
String _decodeName(Uint8List bytes, int flags) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// The destination of [entry] under [root], or a [FileSystemException] when it escapes.
String _target(String root, ZipEntry entry) {
  final outPath = p.normalize(p.join(root, entry.name));
  if (!p.isWithin(root, outPath)) throw FileSystemException('Archive entry escapes destination', entry.name);
  return outPath;
}

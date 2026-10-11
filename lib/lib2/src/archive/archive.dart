import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import '../hash/hash.dart';

/// Pack, unpack and list archives in pure Dart: ZIP, TAR and gzip.
///
/// ```dart
/// await Archive.pack('project', 'backup.zip');
/// await Archive.unpack('backup.zip', 'restored/');
/// final names = await Archive.list('backup.zip');
/// ```
abstract final class Archive {
  /// Packs the file or directory at [src] into [dst]. The extension of [dst] picks the
  /// format: `.zip`, `.tar`, `.tar.gz`/`.tgz` or `.gz`.
  static Future<void> pack(Object src, Object dst, {int level = 6}) async {
    final files = await _collect(src);
    final data = _encode(files, _extension(dst), level);
    await _writeFile(dst, data);
  }

  /// Unpacks [src] into [dst]. The container is detected from magic bytes.
  static Future<void> unpack(Object src, [Object? dst]) async {
    final bytes = await _readFile(src);
    final files = _decode(bytes);
    final root = dst == null ? io.Directory.current.path : _path(dst);
    for (final entry in files.entries) {
      final target = io.File(
        '$root${io.Platform.pathSeparator}${entry.key.replaceAll('/', io.Platform.pathSeparator)}',
      );
      await target.parent.create(recursive: true);
      await target.writeAsBytes(entry.value);
    }
  }

  /// Lists the entry names inside [src].
  static Future<List<String>> list(Object src) async => _decode(await _readFile(src)).keys.toList();

  /// Packs an in-memory map of names to bytes as a ZIP.
  static Uint8List zip(Map<String, List<int>> files, {int level = 6}) {
    final entries = [for (final e in files.entries) (e.key, Uint8List.fromList(e.value))];
    return _encodeZip(entries, level);
  }

  /// Unpacks ZIP [bytes] into a map of names to bytes.
  static Map<String, Uint8List> unzip(List<int> bytes) => _decodeZip(Uint8List.fromList(bytes));

  /// Deflates [data] as a gzip stream.
  static Uint8List gzip(List<int> data) => Uint8List.fromList(io.GZipCodec().encode(data));

  /// Inflates a gzip stream.
  static Uint8List gunzip(List<int> data) => Uint8List.fromList(io.GZipCodec().decode(data));

  static String _path(Object o) => o is io.File ? o.path : (o is io.Directory ? o.path : o.toString());

  static Future<void> _writeFile(Object dst, Uint8List data) async {
    final f = io.File(_path(dst));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(data);
  }

  static Future<Uint8List> _readFile(Object src) => io.File(_path(src)).readAsBytes();

  static String _extension(Object dst) {
    final p = _path(dst).toLowerCase();
    if (p.endsWith('.tar.gz') || p.endsWith('.tgz')) return 'tgz';
    if (p.endsWith('.tar')) return 'tar';
    if (p.endsWith('.gz')) return 'gz';
    if (p.endsWith('.zip')) return 'zip';
    return 'zip';
  }

  static Future<Map<String, Uint8List>> _collect(Object src) async {
    final path = _path(src);
    final type = await io.FileSystemEntity.type(path);
    final out = <String, Uint8List>{};
    if (type == io.FileSystemEntityType.file) {
      out[_basename(path)] = await io.File(path).readAsBytes();
      return out;
    }
    final base = io.Directory(path);
    await for (final entity in base.list(recursive: true, followLinks: false)) {
      if (entity is io.File) {
        final rel = entity.path.substring(path.length).replaceAll('\\', '/').replaceAll(RegExp('^/+'), '');
        out[rel] = await entity.readAsBytes();
      }
    }
    return out;
  }

  static String _basename(String path) {
    final clean = path.replaceAll('\\', '/');
    return clean.substring(clean.lastIndexOf('/') + 1);
  }

  static Uint8List _encode(Map<String, Uint8List> files, String format, int level) => switch (format) {
    'tar' => _encodeTar([for (final e in files.entries) (e.key, e.value)]),
    'tgz' => Uint8List.fromList(io.GZipCodec().encode(_encodeTar([for (final e in files.entries) (e.key, e.value)]))),
    'gz' => Uint8List.fromList(io.GZipCodec().encode(files.values.first)),
    _ => _encodeZip([for (final e in files.entries) (e.key, e.value)], level),
  };

  static Map<String, Uint8List> _decode(Uint8List bytes) {
    if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) return _decodeZip(bytes);
    if (bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
      final inner = Uint8List.fromList(io.GZipCodec().decode(bytes));
      if (inner.length >= 262 && String.fromCharCodes(inner.sublist(257, 262)) == 'ustar') return _decodeTar(inner);
      return {'file': inner};
    }
    if (bytes.length >= 262 && String.fromCharCodes(bytes.sublist(257, 262)) == 'ustar') return _decodeTar(bytes);
    throw const FormatException('Unrecognised archive format');
  }
}

// ---------------------------------------------------------------------------
// ZIP
// ---------------------------------------------------------------------------

Uint8List _encodeZip(List<(String, Uint8List)> entries, int level) {
  final out = BytesBuilder(copy: true);
  final central = BytesBuilder(copy: true);
  var offset = 0;
  for (final (name, data) in entries) {
    final nameBytes = utf8.encode(name);
    final crc = Hash.crc32(data).intVal;
    final deflated = Uint8List.fromList(io.ZLibEncoder(raw: true, level: level).convert(data));
    final useDeflate = deflated.length < data.length;
    final payload = useDeflate ? deflated : data;
    final method = useDeflate ? 8 : 0;

    final local = BytesBuilder(copy: true)
      ..add(_le32(0x04034B50))
      ..add(_le16(20))
      ..add(_le16(0))
      ..add(_le16(method))
      ..add(_le16(0))
      ..add(_le16(0x0021))
      ..add(_le32(crc))
      ..add(_le32(payload.length))
      ..add(_le32(data.length))
      ..add(_le16(nameBytes.length))
      ..add(_le16(0))
      ..add(nameBytes);
    out.add(local.takeBytes());
    out.add(payload);

    central
      ..add(_le32(0x02014B50))
      ..add(_le16(20))
      ..add(_le16(20))
      ..add(_le16(0))
      ..add(_le16(method))
      ..add(_le16(0))
      ..add(_le16(0x0021))
      ..add(_le32(crc))
      ..add(_le32(payload.length))
      ..add(_le32(data.length))
      ..add(_le16(nameBytes.length))
      ..add(_le16(0))
      ..add(_le16(0))
      ..add(_le16(0))
      ..add(_le16(0))
      ..add(_le32(0))
      ..add(_le32(offset))
      ..add(nameBytes);

    offset += 30 + nameBytes.length + payload.length;
  }
  final cdBytes = central.takeBytes();
  final end = BytesBuilder(copy: true)
    ..add(_le32(0x06054B50))
    ..add(_le16(0))
    ..add(_le16(0))
    ..add(_le16(entries.length))
    ..add(_le16(entries.length))
    ..add(_le32(cdBytes.length))
    ..add(_le32(offset))
    ..add(_le16(0));
  out.add(cdBytes);
  out.add(end.takeBytes());
  return out.takeBytes();
}

Map<String, Uint8List> _decodeZip(Uint8List bytes) {
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (_readLE32(bytes, i) == 0x06054B50) {
      eocd = i;
      break;
    }
  }
  if (eocd == -1) throw const FormatException('ZIP end-of-central-directory not found');
  final count = _readLE16(bytes, eocd + 10);
  var p = _readLE32(bytes, eocd + 16);
  final out = <String, Uint8List>{};
  for (var n = 0; n < count; n++) {
    final method = _readLE16(bytes, p + 10);
    final compressedSize = _readLE32(bytes, p + 20);
    final nameLen = _readLE16(bytes, p + 28);
    final extraLen = _readLE16(bytes, p + 30);
    final commentLen = _readLE16(bytes, p + 32);
    final localOffset = _readLE32(bytes, p + 42);
    final name = utf8.decode(bytes.sublist(p + 46, p + 46 + nameLen));
    p += 46 + nameLen + extraLen + commentLen;

    final lNameLen = _readLE16(bytes, localOffset + 26);
    final lExtraLen = _readLE16(bytes, localOffset + 28);
    final dataStart = localOffset + 30 + lNameLen + lExtraLen;
    final raw = bytes.sublist(dataStart, dataStart + compressedSize);
    out[name] = method == 8 ? Uint8List.fromList(io.ZLibDecoder(raw: true).convert(raw)) : Uint8List.fromList(raw);
  }
  return out;
}

// ---------------------------------------------------------------------------
// TAR
// ---------------------------------------------------------------------------

Uint8List _encodeTar(List<(String, Uint8List)> entries) {
  final out = BytesBuilder(copy: true);
  for (final (name, data) in entries) {
    final header = Uint8List(512);
    _writeStr(header, 0, name, 100);
    _writeStr(header, 100, '0000644\x00', 8);
    _writeStr(header, 108, '0000000\x00', 8);
    _writeStr(header, 116, '0000000\x00', 8);
    _writeStr(header, 124, '${data.length.toRadixString(8).padLeft(11, '0')}\x00', 12);
    _writeStr(
      header,
      136,
      '${(DateTime.now().millisecondsSinceEpoch ~/ 1000).toRadixString(8).padLeft(11, '0')}\x00',
      12,
    );
    for (var i = 148; i < 156; i++) {
      header[i] = 0x20;
    }
    header[156] = 0x30;
    _writeStr(header, 257, 'ustar\x00', 6);
    _writeStr(header, 263, '00', 2);
    var checksum = 0;
    for (final b in header) {
      checksum += b;
    }
    _writeStr(header, 148, '${checksum.toRadixString(8).padLeft(6, '0')}\x00 ', 8);
    out.add(header);
    out.add(data);
    final pad = (512 - data.length % 512) % 512;
    if (pad > 0) out.add(Uint8List(pad));
  }
  out.add(Uint8List(1024));
  return out.takeBytes();
}

Map<String, Uint8List> _decodeTar(Uint8List bytes) {
  final out = <String, Uint8List>{};
  var p = 0;
  while (p + 512 <= bytes.length) {
    final name = _readStr(bytes, p, 100);
    if (name.isEmpty) break;
    final size = int.parse(_readStr(bytes, p + 124, 12).trim().replaceAll('\u0000', ''), radix: 8);
    var name2 = name;
    if (String.fromCharCodes(bytes.sublist(p + 257, p + 262)) == 'ustar') {
      final prefix = _readStr(bytes, p + 345, 155);
      if (prefix.isNotEmpty) name2 = '$prefix/$name';
    }
    p += 512;
    out[name2] = Uint8List.fromList(bytes.sublist(p, p + size));
    p += (size + 511) & ~511;
  }
  return out;
}

void _writeStr(Uint8List buf, int off, String s, int len) {
  final codes = utf8.encode(s);
  for (var i = 0; i < len; i++) {
    buf[off + i] = i < codes.length ? codes[i] : 0;
  }
}

String _readStr(Uint8List buf, int off, int len) {
  final end = buf.indexOf(0, off);
  final limit = end == -1 || end > off + len ? off + len : end;
  return utf8.decode(buf.sublist(off, limit), allowMalformed: true);
}

// ---------------------------------------------------------------------------
// little-endian helpers
// ---------------------------------------------------------------------------

Uint8List _le16(int v) => Uint8List.fromList([v & 0xFF, (v >>> 8) & 0xFF]);
Uint8List _le32(int v) => Uint8List.fromList([v & 0xFF, (v >>> 8) & 0xFF, (v >>> 16) & 0xFF, (v >>> 24) & 0xFF]);

int _readLE16(Uint8List b, int i) => (b[i] & 0xFF) | ((b[i + 1] & 0xFF) << 8);
int _readLE32(Uint8List b, int i) =>
    (b[i] & 0xFF) | ((b[i + 1] & 0xFF) << 8) | ((b[i + 2] & 0xFF) << 16) | ((b[i + 3] & 0xFF) << 24);

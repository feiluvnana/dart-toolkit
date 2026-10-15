/// An in-memory zip reader and writer for `archive`, on the SDK's raw
/// deflate (`dart:io` ZLib). Replaces `package:archive`, which cost an
/// unpack script ~0.3 s of startup for this one format.
///
/// Reads stored and deflated members, zip64 sizes and offsets, UTF-8 or
/// legacy names, unix modes, and WinZip AES or legacy ZipCrypto members.
/// Writes fast deflate (or stored when smaller), UTF-8 names, unix modes and
/// AES-256 with a password; an archive over 4 GiB or 65,535 members asks
/// for tgz instead of writing zip64.
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'aes.dart';
import 'crc32.dart';

import '../core.dart';

/// One member as read.
final class ZipEntry {
  ZipEntry._(
    this.name,
    this.mode,
    this._bytes,
    this._offset,
    this._method,
    this._size,
    this._packed, {
    required this.encrypted,
    required this._crc,
    required this._time,
    required this._flags,
    this._aes,
  });

  /// The stored name, `/`-separated; folders end in `/`.
  final String name;

  /// The unix `st_mode` (type bits included), or 0 when the zip was not
  /// made on unix.
  final int mode;

  final Uint8List _bytes;
  final int _offset;
  final int _method;
  final int _size;
  final int _packed;
  final int _crc;
  final int _time;
  final int _flags;

  /// WinZip AES: version (AE-1 keeps the CRC, AE-2 zeroes it), key
  /// strength (1-3) and the method under the encryption.
  final ({int version, int strength, int method})? _aes;

  /// Needs a password: WinZip AES or legacy ZipCrypto.
  final bool encrypted;

  bool get isDir => name.endsWith('/') || mode & 0xF000 == 0x4000;
  bool get isLink => mode & 0xF000 == 0xA000;

  /// The member's bytes, decrypted with [password], inflated and checked
  /// against the CRC-32 (an AE-2 member is checked by its MAC instead).
  Uint8List data({String? password}) {
    final b = _bytes;
    if (_offset + 30 > b.length || _u32(b, _offset) != 0x04034b50) _corrupt('bad local header for $name');
    final start = _offset + 30 + _u16(b, _offset + 26) + _u16(b, _offset + 28);
    if (start + _packed > b.length) _corrupt('member runs past the end: $name');
    var raw = Uint8List.sublistView(b, start, start + _packed);
    var method = _method;
    final aes = _aes;
    if (encrypted) {
      if (password == null) throw ContentException('archive member is encrypted: $name (pass password:)');
      if (aes != null) {
        raw = _aesDecrypt(raw, utf8.encode(password), aes.strength);
        method = aes.method;
      } else {
        raw = _zipCryptoDecrypt(raw, utf8.encode(password));
      }
    }
    final Uint8List out;
    switch (method) {
      case 0:
        out = raw;
      case 8:
        out = inflateRaw(raw, _size, name);
      default:
        throw ContentException('corrupt archive: unsupported zip method $method for $name');
    }
    if (out.length != _size) _corrupt('$name inflates to ${out.length} bytes, not $_size');
    if (!(encrypted && aes != null && aes.version == 2) && crc32(out) != _crc) {
      // ZipCrypto's one-byte check passes a wrong password 1 time in 256.
      throw ContentException(encrypted ? 'wrong password or corrupt data: $name' : 'corrupt archive: CRC of $name');
    }
    return out;
  }

  /// WinZip AES: salt, a 2-byte password check, CTR data, a 10-byte HMAC.
  Uint8List _aesDecrypt(Uint8List raw, List<int> password, int strength) {
    final keyLen = 8 + 8 * strength; // 16, 24, 32
    final saltLen = keyLen ~/ 2;
    if (raw.length < saltLen + 12) _corrupt('encrypted member too short: $name');
    final keys = pbkdf2(crypto.sha1, password, Uint8List.sublistView(raw, 0, saltLen), 1000, 2 * keyLen + 2);
    if (keys[2 * keyLen] != raw[saltLen] || keys[2 * keyLen + 1] != raw[saltLen + 1]) {
      throw ContentException('wrong password for $name');
    }
    final body = Uint8List.sublistView(raw, saltLen + 2, raw.length - 10);
    final mac = crypto.Hmac(crypto.sha1, Uint8List.sublistView(keys, keyLen, 2 * keyLen)).convert(body).bytes;
    for (var i = 0; i < 10; i++) {
      if (mac[i] != raw[raw.length - 10 + i]) _corrupt('$name fails its authentication code');
    }
    return Aes(Uint8List.sublistView(keys, 0, keyLen)).ctrLittleEndian(body);
  }

  /// Legacy ZipCrypto: weak, read only, for old archives.
  Uint8List _zipCryptoDecrypt(Uint8List raw, List<int> password) {
    if (raw.length < 12) _corrupt('encrypted member too short: $name');
    final keys = _ZipCrypto(password);
    final head = Uint8List(12);
    for (var i = 0; i < 12; i++) {
      head[i] = keys.decrypt(raw[i]);
    }
    // The last header byte repeats the CRC's high byte (or the time's,
    // when sizes trail the data).
    final check = _flags & 8 != 0 ? _time >> 8 & 0xFF : _crc >> 24 & 0xFF;
    if (head[11] != check) throw ContentException('wrong password for $name');
    final out = Uint8List(raw.length - 12);
    for (var i = 0; i < out.length; i++) {
      out[i] = keys.decrypt(raw[12 + i]);
    }
    return out;
  }
}

/// The members of the zip in [b], in central-directory order.
List<ZipEntry> readZip(Uint8List b) {
  // The end-of-central-directory record: 22 bytes plus a comment of up to
  // 64 KiB, so scan back at most that far.
  var eocd = -1;
  for (var i = b.length - 22; i >= 0 && i >= b.length - 22 - 0xFFFF; i--) {
    if (_u32(b, i) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) _corrupt('no zip directory');
  var count = _u16(b, eocd + 10);
  var dir = _u32(b, eocd + 16);
  if (count == 0xFFFF || dir == 0xFFFFFFFF) {
    // Zip64: a locator 20 bytes before points at the zip64 record.
    final loc = eocd - 20;
    if (loc < 0 || _u32(b, loc) != 0x07064b50) _corrupt('missing zip64 locator');
    final rec = _u64(b, loc + 8);
    if (rec < 0 || rec + 56 > b.length || _u32(b, rec) != 0x06064b50) _corrupt('bad zip64 record');
    count = _u64(b, rec + 32);
    dir = _u64(b, rec + 48);
  }
  final out = <ZipEntry>[];
  var at = dir;
  for (var n = 0; n < count; n++) {
    if (at + 46 > b.length || _u32(b, at) != 0x02014b50) _corrupt('bad central directory');
    final madeBy = _u16(b, at + 4) >> 8;
    final flags = _u16(b, at + 8);
    final method = _u16(b, at + 10);
    var packed = _u32(b, at + 20);
    var size = _u32(b, at + 24);
    final nameLen = _u16(b, at + 28), extraLen = _u16(b, at + 30), commentLen = _u16(b, at + 32);
    final external = _u32(b, at + 38);
    var offset = _u32(b, at + 42);
    final nameEnd = at + 46 + nameLen;
    if (nameEnd + extraLen > b.length) _corrupt('bad central directory');
    final rawName = Uint8List.sublistView(b, at + 46, nameEnd);
    final name = flags & 0x800 != 0 ? utf8.decode(rawName, allowMalformed: true) : _legacyName(rawName);
    ({int version, int strength, int method})? aes;
    // Zip64 extra field (0x0001): the 64-bit values, in order, for each
    // field that holds 0xFFFFFFFF. WinZip AES (0x9901): version, "AE",
    // strength, method.
    for (var e = nameEnd; e + 4 <= nameEnd + extraLen;) {
      final id = _u16(b, e), len = _u16(b, e + 2);
      if (id == 0x9901) {
        final version = _u16(b, e + 4), strength = _u16(b, e + 8) & 0xFF;
        if (len != 7 || version < 1 || version > 2 || _u16(b, e + 6) != 0x4541 || strength < 1 || strength > 3) {
          _corrupt('bad AES extra field: $name');
        }
        aes = (version: version, strength: strength, method: _u16(b, e + 9));
      }
      if (id == 1) {
        var f = e + 4;
        final end = e + 4 + len;
        if (size == 0xFFFFFFFF && f + 8 <= end) {
          size = _u64(b, f);
          f += 8;
        }
        if (packed == 0xFFFFFFFF && f + 8 <= end) {
          packed = _u64(b, f);
          f += 8;
        }
        if (offset == 0xFFFFFFFF && f + 8 <= end) offset = _u64(b, f);
      }
      e += 4 + len;
    }
    final mode = madeBy == 3 ? external >> 16 & 0xFFFF : 0;
    if (method == 99 && aes == null) _corrupt('AES member without its extra field: $name');
    // Real sizes and offsets stay under 2^48; a bigger one (or a zip64
    // value that wrapped negative) is damage.
    if (size < 0 || packed < 0 || offset < 0 || size > 1 << 48 || offset >= b.length) {
      _corrupt('bad sizes for $name');
    }
    out.add(
      ZipEntry._(
        name,
        mode,
        b,
        offset,
        method,
        size,
        packed,
        encrypted: flags & 1 != 0,
        crc: _u32(b, at + 16),
        time: _u16(b, at + 12),
        flags: flags,
        aes: aes,
      ),
    );
    at = nameEnd + extraLen + commentLen;
  }
  // Members may not share bytes: twenty entries pointing at one 5 MiB run of
  // zeros made 100 MiB from 6 KiB, each one CRC-valid (a zip bomb).
  final spans = [for (final e in out) (e._offset, e._offset + 30 + e._packed)]..sort((a, b) => a.$1.compareTo(b.$1));
  for (var k = 1; k < spans.length; k++) {
    if (spans[k].$1 < spans[k - 1].$2) _corrupt('overlapping members');
  }
  return out;
}

/// A zip of [entries] (name, unix permission bits, bytes, modified time); a
/// name ending in `/` is a folder. With [password], files are WinZip
/// AES-256 (AE-2).
Uint8List writeZip(List<(String, int, List<int>, DateTime)> entries, {String? password}) {
  final pw = password == null ? null : utf8.encode(password);
  final random = Random.secure();
  final out = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  for (final (name, mode, data, mtime) in entries) {
    final (time, date) = _dosTime(mtime);
    final isDir = name.endsWith('/');
    final nameBytes = utf8.encode(name);
    var method = 0;
    List<int> body = data;
    var crc = 0;
    // The SDK's one-shot deflate keeps only the low 32 bits of its input
    // length: past 4 GiB it would write a short member without an error.
    if (data.length > 0xFFFFFFFF) {
      throw const ContentException('zip over 4 GiB or 65,535 members: use ArchiveFormat.tgz');
    }
    if (!isDir && data.isNotEmpty) {
      // One native pass gives the deflate stream and its CRC: a gzip member
      // is a 10-byte header, raw deflate, then CRC-32 and size. Level 1 is
      // ~10x faster than the default 6 for ~15% more bytes, the same trade
      // package:archive made.
      final gz = io.GZipCodec(level: 1).encode(data);
      final g = gz is Uint8List ? gz : Uint8List.fromList(gz);
      crc = _u32(g, g.length - 8);
      if (g.length - 18 < data.length) {
        method = 8;
        body = Uint8List.sublistView(g, 10, g.length - 8);
      }
    }
    // AES-256 (AE-2): the CRC is left 0 (the HMAC authenticates instead) and
    // method 99 names the real method in the extra field.
    var extra = const <int>[];
    var flags = 0x800; // UTF-8 names
    if (pw != null && !isDir) {
      final salt = Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
      final keys = pbkdf2(crypto.sha1, pw, salt, 1000, 66);
      final plain = body is Uint8List ? body : Uint8List.fromList(body);
      final encrypted = Aes(Uint8List.sublistView(keys, 0, 32)).ctrLittleEndian(plain);
      final mac = crypto.Hmac(crypto.sha1, Uint8List.sublistView(keys, 32, 64)).convert(encrypted).bytes;
      body = Uint8List(18 + encrypted.length + 10)
        ..setRange(0, 16, salt)
        ..setRange(16, 18, keys, 64)
        ..setRange(18, 18 + encrypted.length, encrypted)
        ..setRange(18 + encrypted.length, 28 + encrypted.length, mac);
      extra = [0x01, 0x99, 7, 0, 2, 0, 0x41, 0x45, 3, method & 0xFF, method >> 8];
      method = 99;
      crc = 0;
      flags |= 1;
    }
    final offset = out.length;
    if (offset > 0xFFFFFFFF || body.length > 0xFFFFFFFF || entries.length > 0xFFFF) {
      throw const ContentException('zip over 4 GiB or 65,535 members: use ArchiveFormat.tgz');
    }
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, flags, Endian.little)
      ..setUint16(8, method, Endian.little)
      ..setUint16(10, time, Endian.little)
      ..setUint16(12, date, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, body.length, Endian.little)
      ..setUint32(22, data.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little)
      ..setUint16(28, extra.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(nameBytes)
      ..add(extra)
      ..add(body);
    final type = isDir ? 0x4000 : 0x8000;
    final dirEntry = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 0x0314, Endian.little) // made by unix, version 2.0
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, flags, Endian.little)
      ..setUint16(10, method, Endian.little)
      ..setUint16(12, time, Endian.little)
      ..setUint16(14, date, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, body.length, Endian.little)
      ..setUint32(24, data.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint16(30, extra.length, Endian.little)
      ..setUint32(38, (type | (mode & 0xFFF)) << 16 | (isDir ? 0x10 : 0), Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(dirEntry.buffer.asUint8List())
      ..add(nameBytes)
      ..add(extra);
  }
  final dirOffset = out.length;
  final dirBytes = central.takeBytes();
  if (dirOffset + dirBytes.length > 0xFFFFFFFF) {
    throw const ContentException('zip over 4 GiB or 65,535 members: use ArchiveFormat.tgz');
  }
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, dirBytes.length, Endian.little)
    ..setUint32(16, dirOffset, Endian.little);
  out
    ..add(dirBytes)
    ..add(end.buffer.asUint8List());
  return out.takeBytes();
}

/// The ZipCrypto key state (PKWARE APPNOTE 6.1).
final class _ZipCrypto {
  _ZipCrypto(List<int> password) {
    for (final b in password) {
      _update(b);
    }
  }

  var _k0 = 0x12345678, _k1 = 0x23456789, _k2 = 0x34567890;

  void _update(int b) {
    _k0 = _crcByte(_k0, b);
    _k1 = (_k1 + (_k0 & 0xFF)) & 0xFFFFFFFF;
    _k1 = (_k1 * 134775813 + 1) & 0xFFFFFFFF;
    _k2 = _crcByte(_k2, _k1 >> 24);
  }

  int decrypt(int c) {
    final t = (_k2 & 0xFFFF) | 2;
    final p = c ^ ((t * (t ^ 1)) >> 8 & 0xFF);
    _update(p);
    return p;
  }
}

int _crcByte(int c, int b) => crcTable[(c ^ b) & 0xFF] ^ (c >> 8);

/// A name without the UTF-8 flag: UTF-8 when it decodes (what most tools
/// write anyway), else Latin-1 (close to CP437 for the printable range).
String _legacyName(Uint8List raw) {
  try {
    return utf8.decode(raw);
  } on FormatException {
    return latin1.decode(raw);
  }
}

/// [t] as DOS time and date (local, 2-second steps, 1980 to 2107).
(int, int) _dosTime(DateTime t) {
  t = t.toLocal();
  if (t.year < 1980) return (0, 1 << 5 | 1);
  if (t.year > 2107) return (23 << 11 | 59 << 5 | 29, 127 << 9 | 12 << 5 | 31);
  return (t.hour << 11 | t.minute << 5 | t.second ~/ 2, (t.year - 1980) << 9 | t.month << 5 | t.day);
}

/// Inflates the raw deflate [input], stopping as soon as the output passes
/// [size] (a bomb never gets past its declared size) and naming [what] in
/// the error. Returns what inflated, which may be short of [size].
Uint8List inflateRaw(Uint8List input, int size, String what) {
  // Deflate's best ratio is 1032:1, so no real stream outgrows that.
  final most = input.length * 1032 + 1024;
  final out = Uint8List(size < most ? size : most);
  final filter = io.RawZLibFilter.inflateFilter(raw: true);
  var n = 0;
  void take(List<int>? piece) {
    if (piece == null) return;
    if (n + piece.length > out.length) _corrupt('$what inflates past its declared $size bytes');
    out.setRange(n, n + piece.length, piece);
    n += piece.length;
  }

  try {
    const step = 1 << 16;
    for (var i = 0; i < input.length; i += step) {
      filter.process(input, i, i + step < input.length ? i + step : input.length);
      for (List<int>? piece; (piece = filter.processed(flush: false)) != null;) {
        take(piece);
      }
    }
    for (List<int>? piece; (piece = filter.processed(end: true)) != null;) {
      take(piece);
    }
  } on ContentException {
    rethrow;
  } on FormatException catch (e) {
    _corrupt('bad deflate data in $what (${e.message})');
  }
  return n == out.length ? out : Uint8List.sublistView(out, 0, n);
}

Never _corrupt(String why) => throw ContentException('corrupt archive: $why');

int _u16(Uint8List b, int i) => i < 0 || i + 2 > b.length ? 0 : b[i] | b[i + 1] << 8;
int _u32(Uint8List b, int i) => i < 0 || i + 4 > b.length ? 0 : b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;
int _u64(Uint8List b, int i) => _u32(b, i) + _u32(b, i + 4) * 0x100000000;

/// An in-memory zip reader and writer for `archive`, on the SDK's raw
/// deflate (`dart:io` ZLib). Replaces `package:archive`, which cost an
/// unpack script ~0.3 s of startup for this one format.
///
/// Reads stored and deflated members, zip64 sizes and offsets, UTF-8 or
/// legacy names, unix modes, mtimes, symlinks, and WinZip AES or legacy
/// ZipCrypto members. Writes a stream: fast deflate, UTF-8 names, unix
/// modes, mtimes, symlinks, zip64 where needed and AES-256 with a password.
library;

import 'dart:async';
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
    required this.mtime,
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

  /// When it was last modified: the extended timestamp (UTC seconds) when
  /// there is one, else the DOS time (local, 2-second steps); null for none.
  final DateTime? mtime;

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
      if (password == null) throw PasswordException('archive member is encrypted: $name (pass password:)');
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
      throw encrypted ? PasswordException('wrong password or corrupt data: $name') : ContentException('corrupt archive: CRC of $name');
    }
    return out;
  }

  /// WinZip AES: salt, a 2-byte password check, CTR data, a 10-byte HMAC.
  Uint8List _aesDecrypt(Uint8List raw, List<int> password, int strength) {
    final keyLen = 8 + 8 * strength; // 16, 24, 32
    final saltLen = keyLen ~/ 2;
    if (raw.length < saltLen + 12) _corrupt('encrypted member too short: $name');
    final keys = pbkdf2(password, Uint8List.sublistView(raw, 0, saltLen), 1000, 2 * keyLen + 2);
    if (keys[2 * keyLen] != raw[saltLen] || keys[2 * keyLen + 1] != raw[saltLen + 1]) {
      throw PasswordException('wrong password for $name');
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
    if (head[11] != check) throw PasswordException('wrong password for $name');
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
    DateTime? mtime;
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
      if (id == 0x5455 && len >= 5 && b[e + 4] & 1 != 0) {
        mtime = DateTime.fromMillisecondsSinceEpoch(_u32(b, e + 5) * 1000);
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
        mtime: mtime ?? _fromDos(_u16(b, at + 12), _u16(b, at + 14)),
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

/// One member for [zipStream]: its name (a `/` at the end makes a folder),
/// unix permission bits and modified time, then either a symlink [link]
/// target or [size] bytes read from [open].
typedef ZipSource = ({
  String name,
  int mode,
  DateTime mtime,
  int size,
  Stream<List<int>> Function()? open,
  String? link,
});

/// A zip of [members], streamed: each file is deflated (level 1, ~10x
/// faster than 6 for ~15% more bytes) on its way through, its CRC and sizes
/// in a data descriptor after it, so only the central directory is held.
/// Zip64 records appear where a size, an offset or the member count needs
/// them. With [password], files are WinZip AES-256 (AE-2). A file whose
/// size changed since [ZipSource.size] was taken is an error.
Stream<Uint8List> zipStream(Stream<ZipSource> members, {String? password}) async* {
  final pw = password == null ? null : utf8.encode(password);
  final central = BytesBuilder(copy: false);
  var offset = 0, count = 0;
  await for (final m in members) {
    final open = m.open, link = m.link;
    final streamed = open != null && link == null && m.size > 0 && !m.name.endsWith('/');
    final zip64 = streamed && m.size >= 0xF0000000; // deflate never grows 256 MiB past that
    final aes = pw != null && streamed;
    final nameBytes = utf8.encode(m.name);
    final (time, date) = _dosTime(m.mtime);
    final secs = m.mtime.millisecondsSinceEpoch ~/ 1000;
    // Extended timestamp (0x5455): the UTC mtime in whole seconds.
    final stamp = [0x55, 0x54, 5, 0, 1, ..._le(secs.clamp(0, 0xFFFFFFFF), 4)];
    final aesExtra = aes ? const [0x01, 0x99, 7, 0, 2, 0, 0x41, 0x45, 3, 8, 0] : const <int>[];
    final flags = 0x800 | (streamed ? 8 : 0) | (aes ? 1 : 0); // UTF-8 names, data descriptor, encrypted
    final method = aes ? 99 : (streamed ? 8 : 0);
    final stored = link == null ? Uint8List(0) : utf8.encode(link);
    var crc = crc32(stored);
    var size = stored.length, packed = stored.length;
    final local = BytesBuilder(copy: false)
      ..add(_le(0x04034b50, 4))
      ..add(_le(zip64 ? 45 : 20, 2))
      ..add(_le(flags, 2))
      ..add(_le(method, 2))
      ..add(_le(time, 2))
      ..add(_le(date, 2))
      ..add(_le(streamed ? 0 : crc, 4))
      ..add(_le(zip64 ? 0xFFFFFFFF : packed, 4))
      ..add(_le(zip64 ? 0xFFFFFFFF : size, 4))
      ..add(_le(nameBytes.length, 2))
      ..add(_le((zip64 ? 20 : 0) + stamp.length + aesExtra.length, 2))
      ..add(nameBytes);
    if (zip64) local.add([1, 0, 16, 0, ...Uint8List(16)]);
    local
      ..add(aesExtra)
      ..add(stamp)
      ..add(stored);
    final head = local.takeBytes();
    final at = offset;
    offset += head.length;
    yield head;
    if (streamed) {
      final body = _Deflated(pw);
      yield* Stream.fromIterable(body.start());
      var sent = 0;
      await for (final chunk in open()) {
        sent += chunk.length;
        if (sent > m.size) break;
        if (chunk.isNotEmpty) yield* Stream.fromIterable(body.add(chunk));
      }
      if (sent != m.size) throw io.FileSystemException('file changed while packing', m.name);
      yield* Stream.fromIterable(body.close());
      size = sent;
      packed = body.length;
      crc = aes ? 0 : body.crc; // AE-2: the HMAC authenticates instead
      if (body.isize != size & 0xFFFFFFFF) throw io.FileSystemException('file changed while packing', m.name);
      final descriptor = [
        ..._le(0x08074b50, 4),
        ..._le(crc, 4),
        ..._le(packed, zip64 ? 8 : 4),
        ..._le(size, zip64 ? 8 : 4),
      ];
      offset += packed + descriptor.length;
      yield Uint8List.fromList(descriptor);
    }
    // Zip64 extra: the 64-bit values, in order, of each field that holds
    // 0xFFFFFFFF.
    final big = [
      if (size >= 0xFFFFFFFF) ..._le(size, 8),
      if (packed >= 0xFFFFFFFF) ..._le(packed, 8),
      if (at >= 0xFFFFFFFF) ..._le(at, 8),
    ];
    final extra = [if (big.isNotEmpty) ...[1, 0, big.length, 0, ...big], ...aesExtra, ...stamp];
    final type = link != null ? 0xA000 : (m.name.endsWith('/') ? 0x4000 : 0x8000);
    central
      ..add(_le(0x02014b50, 4))
      ..add(_le(0x0300 | (big.isEmpty ? 20 : 45), 2)) // made by unix
      ..add(_le(big.isEmpty && !zip64 ? 20 : 45, 2))
      ..add(_le(flags, 2))
      ..add(_le(method, 2))
      ..add(_le(time, 2))
      ..add(_le(date, 2))
      ..add(_le(crc, 4))
      ..add(_le(packed >= 0xFFFFFFFF ? 0xFFFFFFFF : packed, 4))
      ..add(_le(size >= 0xFFFFFFFF ? 0xFFFFFFFF : size, 4))
      ..add(_le(nameBytes.length, 2))
      ..add(_le(extra.length, 2))
      ..add(_le(0, 6)) // comment length, disk, internal attributes
      ..add(_le((type | (m.mode & 0xFFF)) << 16 | (type == 0x4000 ? 0x10 : 0), 4))
      ..add(_le(at >= 0xFFFFFFFF ? 0xFFFFFFFF : at, 4))
      ..add(nameBytes)
      ..add(extra);
    count++;
  }
  final dirSize = central.length;
  yield central.takeBytes();
  final end = BytesBuilder(copy: false);
  if (count >= 0xFFFF || offset >= 0xFFFFFFFF || dirSize >= 0xFFFFFFFF) {
    end
      ..add(_le(0x06064b50, 4))
      ..add(_le(44, 8))
      ..add(_le(0x032D, 2))
      ..add(_le(45, 2))
      ..add(_le(0, 8)) // this disk, the directory's disk
      ..add(_le(count, 8))
      ..add(_le(count, 8))
      ..add(_le(dirSize, 8))
      ..add(_le(offset, 8))
      ..add(_le(0x07064b50, 4))
      ..add(_le(0, 4))
      ..add(_le(offset + dirSize, 8))
      ..add(_le(1, 4));
  }
  end
    ..add(_le(0x06054b50, 4))
    ..add(_le(0, 4))
    ..add(_le(count >= 0xFFFF ? 0xFFFF : count, 2))
    ..add(_le(count >= 0xFFFF ? 0xFFFF : count, 2))
    ..add(_le(dirSize >= 0xFFFFFFFF ? 0xFFFFFFFF : dirSize, 4))
    ..add(_le(offset >= 0xFFFFFFFF ? 0xFFFFFFFF : offset, 4))
    ..add(_le(0, 2));
  yield end.takeBytes();
}

/// [v] as [n] little-endian bytes.
Uint8List _le(int v, int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = v >> (8 * i) & 0xFF;
  }
  return out;
}

/// One member's body on its way out: native deflate through a gzip filter
/// (its trailer gives the CRC-32 for free), then WinZip AES with a
/// password.
final class _Deflated {
  _Deflated(List<int>? password) {
    if (password == null) return;
    final salt = Uint8List.fromList(List.generate(16, (_) => _random.nextInt(256)));
    final keys = pbkdf2(password, salt, 1000, 66);
    _aes = Aes(Uint8List.sublistView(keys, 0, 32));
    _mac = crypto.Hmac(crypto.sha1, Uint8List.sublistView(keys, 32, 64)).startChunkedConversion(_digest);
    _prefix = Uint8List(18)
      ..setRange(0, 16, salt)
      ..setRange(16, 18, keys, 64);
  }

  final _z = io.RawZLibFilter.deflateFilter(gzip: true, level: 1);
  Aes? _aes;
  ByteConversionSink? _mac;
  final _digest = _DigestSink();
  Uint8List? _prefix;
  var _skip = 10; // the gzip header
  var _held = Uint8List(0); // the last 8 bytes so far: the trailer at the end
  var _odd = Uint8List(0); // AES: bytes short of a whole block
  var _blocks = 0;

  /// Bytes written so far.
  int length = 0;
  int crc = 0, isize = 0;

  Iterable<Uint8List> start() sync* {
    final p = _prefix;
    if (p != null) yield* _out(p);
  }

  Iterable<Uint8List> add(List<int> chunk) sync* {
    _z.process(chunk, 0, chunk.length);
    for (List<int>? piece; (piece = _z.processed(flush: false)) != null;) {
      yield* _deflated(piece!);
    }
  }

  Iterable<Uint8List> close() sync* {
    for (List<int>? piece; (piece = _z.processed(end: true)) != null;) {
      yield* _deflated(piece!);
    }
    crc = _u32(_held, 0);
    isize = _u32(_held, 4);
    final aes = _aes;
    if (aes == null) return;
    if (_odd.isNotEmpty) yield* _cipher(aes.ctrLittleEndian(_odd, from: _blocks));
    _mac!.close();
    yield* _out(Uint8List.fromList(_digest.value!.bytes.sublist(0, 10)));
  }

  /// Deflate output, less the gzip header and the 8 trailing bytes held.
  Iterable<Uint8List> _deflated(List<int> piece) sync* {
    var b = piece is Uint8List ? piece : Uint8List.fromList(piece);
    if (_skip > 0) {
      final n = _skip < b.length ? _skip : b.length;
      b = Uint8List.sublistView(b, n);
      _skip -= n;
    }
    if (b.isEmpty) return;
    final all = Uint8List(_held.length + b.length)
      ..setRange(0, _held.length, _held)
      ..setRange(_held.length, _held.length + b.length, b);
    if (all.length <= 8) {
      _held = all;
      return;
    }
    _held = Uint8List.fromList(Uint8List.sublistView(all, all.length - 8));
    yield* _encrypted(Uint8List.sublistView(all, 0, all.length - 8));
  }

  Iterable<Uint8List> _encrypted(Uint8List b) sync* {
    final aes = _aes;
    if (aes == null) {
      yield* _out(b);
      return;
    }
    final all = _odd.isEmpty
        ? b
        : (Uint8List(_odd.length + b.length)
            ..setRange(0, _odd.length, _odd)
            ..setRange(_odd.length, _odd.length + b.length, b));
    final whole = all.length & ~15;
    _odd = Uint8List.fromList(Uint8List.sublistView(all, whole));
    if (whole == 0) return;
    yield* _cipher(aes.ctrLittleEndian(Uint8List.sublistView(all, 0, whole), from: _blocks));
    _blocks += whole >> 4;
  }

  Iterable<Uint8List> _cipher(Uint8List c) sync* {
    _mac!.add(c);
    yield* _out(c);
  }

  Iterable<Uint8List> _out(Uint8List b) sync* {
    length += b.length;
    yield b;
  }
}

final class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

final _random = Random.secure();

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

/// A DOS [time] and [date] as a local time; null for none (a zero date).
DateTime? _fromDos(int time, int date) =>
    date == 0 ? null : DateTime(1980 + (date >> 9), date >> 5 & 15, date & 31, time >> 11, time >> 5 & 63, (time & 31) * 2);

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

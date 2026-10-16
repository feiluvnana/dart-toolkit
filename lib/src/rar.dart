/// A RAR reader in pure Dart for `archive` (read only: the compressor is
/// proprietary). RAR5: block headers, header encryption, the LZ + Huffman
/// decoder with its Delta/E8/E8E9/ARM filters, solid runs, AES-256 with
/// PBKDF2-HMAC-SHA256 and the password check value; every file's CRC or
/// BLAKE2sp hash is checked (MAC-tweaked under encryption). RAR4 lives in
/// `rar4.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'aes.dart';
import 'budget.dart';
import 'crc32.dart';
import 'lzma.dart' show declaredCeiling;
import 'ppmd.dart';

import '../core.dart';

part 'rar4.dart';

/// RAR5 `Rar!\x1A\x07\x01\x00` or RAR4 `Rar!\x1A\x07\x00`.
bool isRar(List<int> b) =>
    b.length >= 7 &&
    b[0] == 0x52 &&
    b[1] == 0x61 &&
    b[2] == 0x72 &&
    b[3] == 0x21 &&
    b[4] == 0x1A &&
    b[5] == 0x07 &&
    b[6] <= 1;

/// One member as read.
final class RarEntry {
  RarEntry(this.name, this.isDir, this.mode, this.mtime, this._data, {this.isLink = false, this.isHardLink = false});

  /// `/`-separated.
  final String name;
  final bool isDir;

  /// A symlink, or with [isHardLink] a hardlink (or RAR5 file copy): [data]
  /// is its target.
  final bool isLink;
  final bool isHardLink;

  /// When it was last modified, when the archive says.
  final DateTime? mtime;

  /// Unix `st_mode` when made on unix, else 0.
  final int mode;

  final Uint8List Function() _data;

  /// The member's bytes (a solid run decodes once, in order).
  Uint8List data() => _data();
}

Never _bad(String why) => throw ContentException('corrupt archive: RAR $why');

/// The members of the RAR archive in [b].
List<RarEntry> readRar(Uint8List b, {String? password}) {
  if (!isRar(b)) _bad('signature');
  final budget = Budget();
  if (b[6] == 0) return _readRar4(b, password, budget);
  if (b.length < 8 || b[7] != 0) _bad('signature');
  final r = _Reader(b, 8);
  final out = <RarEntry>[];
  // A solid run shares one window: members decode in order, each from the
  // state the one before it left.
  final solid = _Solid();
  _HeaderKey? headerKey;
  while (r.pos < b.length) {
    var h = _Header.read(r, headerKey, password);
    if (h == null) break;
    switch (h.type) {
      case 1: // main
        final flags = h.vint();
        if (flags & 0x1 != 0) throw const ContentException('multi-volume RAR archives are not supported');
      case 4: // archive encryption: every later header is encrypted
        if (password == null) throw const ContentException('archive is encrypted (pass password:)');
        final version = h.vint();
        if (version != 0) _bad('encryption version $version');
        final flags = h.vint();
        final kdf = h.byte();
        final salt = h.bytes(16);
        final key = _Key.derive(password, salt, kdf, budget);
        if (flags & 1 != 0) key.check(h.bytes(12));
        headerKey = _HeaderKey(key.key);
      case 2: // file
        final entry = _fileEntry(h, b, password, solid, budget);
        if (entry != null) out.add(entry);
        budget.count(out.length, 'RAR');
      case 5: // end
        return out;
      default:
        break; // service headers (comments, quick open): skipped
    }
    r.pos = h.dataEnd;
  }
  // Every RAR ends with an end block: without it the archive was cut short.
  _bad('archive ends without its end block (truncated)');
}

RarEntry? _fileEntry(_Header h, Uint8List b, String? password, _Solid solid, Budget budget) {
  final flags = h.vint();
  final size = h.vint();
  final attrs = h.vint();
  var mtime = flags & 0x2 != 0 ? DateTime.fromMillisecondsSinceEpoch(h.u32() * 1000) : null;
  final crc = flags & 0x4 != 0 ? h.u32() : null;
  final info = h.vint();
  final host = h.vint();
  final name = utf8.decode(h.bytes(h.vint()), allowMalformed: true).replaceAll('\\', '/');
  final isDir = flags & 0x1 != 0;
  if (h.flags & 0x18 != 0) throw const ContentException('multi-volume RAR archives are not supported');
  // Extra records: encryption, hash, redirection (a link and its target).
  _Key? key;
  String? target;
  var hard = false;
  var iv = Uint8List(0);
  var tweaked = false;
  Uint8List? blake2;
  var e = h.extraStart;
  while (e < h.extraEnd) {
    final x = _Reader(h.raw, e);
    final recSize = x.vint();
    final recEnd = x.pos + recSize;
    // A record holds at least its type, inside the extra area: every
    // step moves forward.
    if (recSize < 1 || recEnd > h.extraEnd) _bad('extra record size $recSize');
    final type = x.vint();
    if (type == 1) {
      if (password == null) throw ContentException('archive member is encrypted: $name (pass password:)');
      // One per member: each costs up to 2^24 key rounds.
      if (key != null) _bad('two encryption records for $name');
      if (x.vint() != 0) _bad('encryption version');
      final f = x.vint();
      final kdf = x.byte();
      final salt = x.bytes(16);
      iv = x.bytes(16);
      key = _Key.derive(password, salt, kdf, budget);
      if (f & 1 != 0) key.check(x.bytes(12), member: name);
      tweaked = f & 2 != 0;
    } else if (type == 3) {
      // File times: unix seconds (flag 1) or a FILETIME; mtime first (flag 2).
      final f = x.vint();
      if (f & 2 != 0) {
        if (f & 1 != 0) {
          mtime = DateTime.fromMillisecondsSinceEpoch(_u32le(x.bytes(4), 0) * 1000);
        } else {
          final t = x.bytes(8);
          final us = (_u32le(t, 0) + _u32le(t, 4) * 0x100000000 - 116444736000000000) ~/ 10;
          if (us.abs() < 8640000000000000000) mtime = DateTime.fromMicrosecondsSinceEpoch(us);
        }
      }
    } else if (type == 2) {
      if (x.vint() == 0) blake2 = x.bytes(32); // BLAKE2sp; other hashes are unknown
    } else if (type == 5) {
      // 1 unix symlink, 2 Windows symlink, 3 junction, 4 hardlink, 5 a copy
      // of an earlier member.
      final kind = x.vint();
      x.vint(); // flags
      target = utf8.decode(x.bytes(x.vint()), allowMalformed: true);
      if (kind != 1) target = target.replaceAll('\\', '/');
      hard = kind >= 4;
    }
    e = recEnd;
  }
  final mode = host == 1 ? attrs & 0xFFFF : 0;
  if (isDir) return RarEntry(name, true, mode, mtime, () => Uint8List(0));
  budget.take(size, 'RAR $name');
  final version = info & 0x3F;
  final isSolid = info & 0x40 != 0;
  final method = info >> 7 & 7;
  if (version > 1) throw ContentException('unsupported RAR compression version $version: $name');
  // 128 KiB << N, plus N/32 of that again in RAR7's extended format.
  final base = 0x20000 << (info >> 10 & 0x1F);
  final dict = version == 1 ? base + base ~/ 32 * (info >> 15 & 0x1F) : base;
  final packed = Uint8List.sublistView(b, h.dataStart, h.dataEnd);
  final k = key;
  // Members decode in archive order, so a solid run's window is ready by
  // the time a member asks; a later member asked first decodes the run.
  final run = isSolid ? solid.current : solid.start();
  final index = run.add(() {
    final plain = k == null ? packed : Aes(k.key).cbcDecrypt(packed, iv);
    return (plain, method, size, version, dict);
  });
  final link = target;
  if (link != null) return RarEntry(name, false, mode, mtime, () => utf8.encode(link), isLink: true, isHardLink: hard);
  final hash = blake2;
  return RarEntry(name, false, mode, mtime, () {
    final data = run.data(index);
    var ok = true;
    if (crc != null) {
      var got = crc32(data);
      if (tweaked && k != null) got = k.tweakCrc(got);
      ok = got == crc;
    }
    if (ok && hash != null) {
      var got = blake2sp(data);
      if (tweaked && k != null) got = k.tweakHash(got);
      for (var i = 0; i < 32; i++) {
        if (got[i] != hash[i]) ok = false;
      }
    }
    if (!ok) {
      throw ContentException(
        k == null ? 'corrupt archive: RAR checksum of $name' : 'wrong password or corrupt archive: $name',
      );
    }
    return data;
  });
}

/// The members of one solid run, decoded together through one window.
/// A member's bytes are kept only until it takes them; asking again
/// decodes the run afresh.
final class _Run {
  final _inputs = <(Uint8List, int, int, int, int) Function()>[];
  final _ready = <int, Uint8List>{}; // decoded, not yet taken
  final _taken = <int>{};
  var _next = 0;
  _Unpack5? _unpack;

  int add((Uint8List, int, int, int, int) Function() input) {
    _inputs.add(input);
    return _inputs.length - 1;
  }

  Uint8List data(int index) {
    final ready = _ready.remove(index);
    if (ready != null) return _hand(index, ready);
    if (index < _next) {
      _unpack = null;
      _next = 0;
    }
    while (true) {
      final i = _next++;
      final (packed, method, size, version, dict) = _inputs[i]();
      final u = (_unpack ??= _Unpack5(extended: version == 1))..keep(dict);
      final Uint8List bytes;
      if (method == 0) {
        // Stored members still join the window for the ones after them.
        if (size < 0 || packed.length < size) _bad('stored member is short');
        bytes = Uint8List.sublistView(packed, 0, size);
        u.append(bytes);
      } else {
        bytes = u.decode(packed, size);
      }
      if (i == index) return _hand(i, bytes);
      if (!_taken.contains(i)) _ready[i] = bytes;
    }
  }

  Uint8List _hand(int index, Uint8List bytes) {
    _taken.add(index);
    return bytes;
  }
}

final class _Solid {
  _Run current = _Run();
  _Run start() => current = _Run();
}

/// A block header, decrypted when the archive encrypts headers.
final class _Header {
  _Header(this.raw, this.type, this.flags, this._r, this.extraStart, this.extraEnd, this.dataStart, this.dataEnd);

  final Uint8List raw;
  final int type, flags;
  final _Reader _r;
  final int extraStart, extraEnd;
  final int dataStart, dataEnd;

  int vint() => _r.vint();
  int byte() => _r.byte();
  int u32() => _r.u32();
  Uint8List bytes(int n) => _r.bytes(n);

  /// The header at [r]'s position; [r] moves past it (not past its data).
  static _Header? read(_Reader r, _HeaderKey? key, String? password) {
    if (r.pos >= r.b.length) return null;
    _Reader src;
    if (key != null) {
      // A 16-byte IV, then the header encrypted in whole AES blocks; the
      // first block tells the size.
      final iv = r.bytes(16);
      final probe = _Reader(key.aes.cbcDecrypt(r.peekBytes(16), iv), 4);
      final size = probe.vint();
      final total = (probe.pos + size + 15) & ~15;
      src = _Reader(key.aes.cbcDecrypt(r.bytes(total), iv), 0);
    } else {
      src = r;
    }
    final base = src.pos;
    final crc = src.u32();
    final size = src.vint();
    final start = src.pos;
    final end = start + size;
    if (size < 1 || end > src.b.length) _bad('header past the end');
    if (crc32(src.b, start: base + 4, end: end) != crc) {
      if (key != null) throw const ContentException('wrong password or corrupt archive');
      _bad('header CRC');
    }
    final h = _Reader(src.b, start);
    final type = h.vint();
    final flags = h.vint();
    final extraSize = flags & 1 != 0 ? h.vint() : 0;
    final dataSize = flags & 2 != 0 ? h.vint() : 0;
    if (extraSize > end - h.pos) _bad('extra area past its header');
    if (key == null) r.pos = end;
    final dataStart = r.pos;
    if (dataSize > r.b.length - dataStart) _bad('data past the end');
    return _Header(src.b, type, flags, h, end - extraSize, end, dataStart, dataStart + dataSize);
  }
}

final class _HeaderKey {
  _HeaderKey(List<int> key) : aes = Aes(key);
  final Aes aes;
}

/// RAR5 keys: PBKDF2-HMAC-SHA256 gives the AES key after 2^kdf rounds, the
/// MAC key 16 rounds later and the password check 16 after that.
final class _Key {
  _Key(this.key, this._hashKey, this._check);

  final Uint8List key;
  final Uint8List _hashKey;
  final Uint8List _check;

  // Keyed by salt and password: solid and header-encrypted archives reuse
  // one salt. Bounded, oldest out.
  static final _cache = <String, _Key>{};

  static _Key derive(String password, Uint8List salt, int kdf, Budget budget) {
    if (kdf > 24) _bad('KDF count $kdf');
    final id = '$kdf:${salt.join(',')}:$password';
    final hit = _cache[id];
    if (hit != null) return hit;
    budget.kdf(1 << kdf, 'RAR');
    if (_cache.length >= 16) _cache.remove(_cache.keys.first);
    return _cache[id] = () {
      final hmac = crypto.Hmac(crypto.sha256, utf8.encode(password));
      var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
      final fn = Uint8List.fromList(u);
      final outs = <Uint8List>[];
      final counts = [1 << kdf, 16, 16];
      var done = 1;
      for (final count in counts) {
        for (; done < count; done++) {
          u = hmac.convert(u).bytes;
          for (var j = 0; j < 32; j++) {
            fn[j] ^= u[j];
          }
        }
        outs.add(Uint8List.fromList(fn));
        done = 0;
      }
      return _Key(outs[0], outs[1], outs[2]);
    }();
  }

  /// Compare the stored check (8 bytes plus a 4-byte SHA-256 sum).
  void check(Uint8List stored, {String? member}) {
    final value = Uint8List(8);
    for (var i = 0; i < 32; i++) {
      value[i % 8] ^= _check[i];
    }
    final sum = crypto.sha256.convert(stored.sublist(0, 8)).bytes;
    if (sum[0] != stored[8] || sum[1] != stored[9] || sum[2] != stored[10] || sum[3] != stored[11]) return;
    for (var i = 0; i < 8; i++) {
      if (value[i] != stored[i]) throw ContentException('wrong password${member == null ? '' : ' for $member'}');
    }
  }

  /// The CRC as stored under a MAC: HMAC-SHA256 of the CRC, folded.
  int tweakCrc(int crc) {
    final d = crypto.Hmac(
      crypto.sha256,
      _hashKey,
    ).convert([crc & 0xFF, crc >> 8 & 0xFF, crc >> 16 & 0xFF, crc >> 24 & 0xFF]).bytes;
    var out = 0;
    for (var i = 0; i < 32; i++) {
      out ^= d[i] << ((i & 3) * 8);
    }
    return out & 0xFFFFFFFF;
  }

  /// The BLAKE2sp hash as stored under a MAC: HMAC-SHA256 of it.
  Uint8List tweakHash(Uint8List hash) => Uint8List.fromList(crypto.Hmac(crypto.sha256, _hashKey).convert(hash).bytes);
}

final class _Reader {
  _Reader(this.b, this.pos);
  final Uint8List b;
  int pos;

  int byte() {
    if (pos >= b.length) _bad('header ends early');
    return b[pos++];
  }

  int u32() {
    final v = bytes(4);
    return v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24;
  }

  Uint8List bytes(int n) {
    if (pos + n > b.length) _bad('header ends early');
    final v = Uint8List.sublistView(b, pos, pos + n);
    pos += n;
    return v;
  }

  Uint8List peekBytes(int n) {
    if (pos + n > b.length) _bad('header ends early');
    return Uint8List.sublistView(b, pos, pos + n);
  }

  /// 7 bits per byte, little-endian, high bit = more. Sizes never reach
  /// 2^63: one that wraps negative is damage.
  int vint() {
    var v = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      final c = byte();
      v |= (c & 0x7F) << shift;
      if (c & 0x80 == 0) return v < 0 ? _bad('number out of range') : v;
    }
    _bad('varint too long');
  }
}

// --- The RAR5 decoder -------------------------------------------------------

const _nc = 306, _ldc = 16, _rc = 44, _bc = 20;

/// Canonical Huffman decoding, MSB-first, with a 10-bit quick table.
final class _Huff {
  _Huff(Uint8List lengths) {
    final count = Int32List(16);
    for (final l in lengths) {
      count[l]++;
    }
    count[0] = 0;
    final pos = Int32List(17);
    var upper = 0;
    for (var i = 1; i < 16; i++) {
      upper += count[i] << (16 - i);
      _limit[i] = upper;
      pos[i + 1] = pos[i] + count[i];
      _start[i] = pos[i];
      _first[i] = _limit[i - 1];
    }
    _limit[15] = 0x10000;
    final fill = Int32List.fromList(pos.sublist(0, 16));
    _symbols = Int32List(lengths.length);
    for (var s = 0; s < lengths.length; s++) {
      final l = lengths[s];
      if (l != 0) _symbols[fill[l]++] = s;
    }
    _quick = Int32List(1 << _quickBits);
    _quickLen = Uint8List(1 << _quickBits);
    var bits = 1;
    for (var code = 0; code < 1 << _quickBits; code++) {
      final field = code << (16 - _quickBits);
      while (bits < 15 && field >= _limit[bits]) {
        bits++;
      }
      _quickLen[code] = bits;
      final dist = (field - _first[bits]) >> (16 - bits);
      final p = _start[bits] + dist;
      _quick[code] = p < _symbols.length ? _symbols[p] : 0;
    }
  }

  static const _quickBits = 10;
  final _limit = Int32List(16);
  final _start = Int32List(16);
  final _first = Int32List(16);
  late final Int32List _symbols;
  late final Int32List _quick;
  late final Uint8List _quickLen;

  int decode(_Bits r) {
    final field = r.peek16() & 0xFFFE;
    if (field < _limit[_quickBits]) {
      final code = field >> (16 - _quickBits);
      r.skip(_quickLen[code]);
      return _quick[code];
    }
    var bits = _quickBits + 1;
    while (bits < 15 && field >= _limit[bits]) {
      bits++;
    }
    r.skip(bits);
    final p = _start[bits] + ((field - _first[bits]) >> (16 - bits));
    if (p >= _symbols.length) _bad('bad Huffman code');
    return _symbols[p];
  }
}

final class _Bits {
  _Bits(this.b, this.pos, this.end);
  final Uint8List b;
  int pos; // in bits
  final int end; // in bits

  int _at(int i) => i < b.length ? b[i] : 0;

  int peek16() {
    final i = pos >> 3;
    final v = _at(i) << 16 | _at(i + 1) << 8 | _at(i + 2);
    return v >> (8 - (pos & 7)) & 0xFFFF;
  }

  int peek32() {
    final i = pos >> 3;
    final v = _at(i) << 32 | _at(i + 1) << 24 | _at(i + 2) << 16 | _at(i + 3) << 8 | _at(i + 4);
    return v >> (8 - (pos & 7)) & 0xFFFFFFFF;
  }

  void skip(int n) => pos += n;

  int take(int n) {
    final v = peek16() >> (16 - n);
    pos += n;
    return v;
  }
}

typedef _Filter = ({int start, int length, int type, int channels});

/// The RAR5 LZ decoder. The window is every byte decoded in this solid run,
/// so a member that refers back into an earlier one needs no copies.
final class _Unpack5 {
  _Unpack5({required this.extended}) : _dc = extended ? 80 : 64;

  final bool extended;
  final int _dc;
  var _window = Uint8List(1 << 16);
  var _pos = 0;
  final _old = Int64List(4);
  var _lastLen = 0;
  _Huff? _main, _dist, _low, _rep;

  void _grow(int need) {
    if (need <= _window.length) return;
    var n = _window.length * 2;
    while (n < need) {
      n *= 2;
    }
    _window = Uint8List(n)..setRange(0, _pos, _window);
  }

  /// Drop all but the last [dict] bytes of the window between members: no
  /// back-reference reaches further, so a long solid run holds one
  /// dictionary (plus the member being decoded), not every byte so far.
  void keep(int dict) {
    if (_pos <= dict * 2 || _pos <= 1 << 20) return;
    final drop = _pos - dict;
    _window.setRange(0, dict, _window, drop);
    _pos = dict;
    if (_window.length > dict * 4) _window = Uint8List.fromList(Uint8List.sublistView(_window, 0, _pos));
  }

  /// Stored members of a solid run still join the window.
  void append(Uint8List bytes) {
    _grow(_pos + bytes.length);
    _window.setRange(_pos, _pos + bytes.length, bytes);
    _pos += bytes.length;
  }

  Uint8List decode(Uint8List input, int size) {
    if (size < 0) _bad('size $size');
    final begin = _pos;
    // A header can claim any size: past the ceiling the window grows only
    // as the data really decodes.
    _grow(_pos + (size < declaredCeiling ? size : declaredCeiling));
    final filters = <_Filter>[];
    var at = 0; // byte offset of the next block header
    var last = false;
    while (!last && _pos - begin < size) {
      if (at + 3 > input.length) _bad('block header past the end');
      final flags = input[at];
      final check = input[at + 1];
      final count = (flags >> 3 & 3) + 1;
      if (count == 4) _bad('block size field');
      var blockSize = 0;
      var sum = 0x5A ^ flags;
      for (var k = 0; k < count; k++) {
        final v = input[at + 2 + k];
        blockSize |= v << (8 * k);
        sum ^= v;
      }
      if (sum & 0xFF != check) _bad('block header checksum');
      final dataStart = at + 2 + count;
      final bitSize = (flags & 7) + 1;
      final endBits = (dataStart + blockSize - 1) * 8 + bitSize;
      last = flags & 0x40 != 0;
      final r = _Bits(input, dataStart * 8, endBits);
      if (flags & 0x80 != 0) _readTables(r);
      if (_main == null) _bad('block without tables');
      _block(r, begin + size, filters);
      at = dataStart + blockSize;
    }
    if (_pos - begin < size) _bad('data ends early');
    _pos = begin + size;
    final out = Uint8List.fromList(Uint8List.sublistView(_window, begin, _pos));
    for (final f in filters) {
      _applyFilter(out, f.start - begin, f, f.start - begin);
    }
    return out;
  }

  void _readTables(_Bits r) {
    final bitLens = Uint8List(_bc);
    for (var i = 0; i < _bc;) {
      final l = r.take(4);
      if (l == 15) {
        final zeros = r.take(4);
        if (zeros == 0) {
          bitLens[i++] = 15;
        } else {
          for (var k = 0; k < zeros + 2 && i < _bc; k++) {
            bitLens[i++] = 0;
          }
        }
      } else {
        bitLens[i++] = l;
      }
    }
    final bc = _Huff(bitLens);
    final total = _nc + _dc + _ldc + _rc;
    final lens = Uint8List(total);
    for (var i = 0; i < total;) {
      final n = bc.decode(r);
      if (n < 16) {
        lens[i++] = n;
      } else if (n < 18) {
        final repeat = n == 16 ? r.take(3) + 3 : r.take(7) + 11;
        if (i == 0) _bad('table repeats nothing');
        final prev = lens[i - 1];
        for (var k = 0; k < repeat && i < total; k++) {
          lens[i++] = prev;
        }
      } else {
        final repeat = n == 18 ? r.take(3) + 3 : r.take(7) + 11;
        for (var k = 0; k < repeat && i < total; k++) {
          lens[i++] = 0;
        }
      }
    }
    _main = _Huff(Uint8List.sublistView(lens, 0, _nc));
    _dist = _Huff(Uint8List.sublistView(lens, _nc, _nc + _dc));
    _low = _Huff(Uint8List.sublistView(lens, _nc + _dc, _nc + _dc + _ldc));
    _rep = _Huff(Uint8List.sublistView(lens, _nc + _dc + _ldc, total));
  }

  int _length(_Bits r, int slot) {
    if (slot < 8) return 2 + slot;
    final bits = slot ~/ 4 - 1;
    return 2 + ((4 | slot & 3) << bits) + r.take(bits);
  }

  void _copy(int length, int distance, int limit) {
    final from = _pos - distance;
    if (from < 0) _bad('distance before the start');
    if (_pos + length > limit) length = limit - _pos;
    _grow(_pos + length);
    final w = _window;
    if (distance >= length) {
      w.setRange(_pos, _pos + length, w, from);
    } else {
      for (var k = 0; k < length; k++) {
        w[_pos + k] = w[from + k];
      }
    }
    _pos += length;
  }

  void _block(_Bits r, int limit, List<_Filter> filters) {
    final main = _main!, dist = _dist!, low = _low!, rep = _rep!;
    while (_pos < limit) {
      if (r.pos >= r.end) return;
      if (_pos == _window.length) _grow(_pos + 1);
      final slot = main.decode(r);
      if (slot < 256) {
        _window[_pos++] = slot;
      } else if (slot >= 262) {
        var length = _length(r, slot - 262);
        final ds = dist.decode(r);
        var distance = 1;
        if (ds < 4) {
          distance += ds;
        } else {
          final bits = ds ~/ 2 - 1;
          distance += (2 | ds & 1) << bits;
          if (bits >= 4) {
            if (bits > 4) {
              distance += (r.peek32() >> (36 - bits)) << 4;
              r.skip(bits - 4);
            }
            distance += low.decode(r);
          } else {
            distance += r.peek32() >> (32 - bits);
            r.skip(bits);
          }
        }
        if (distance > 0x100) {
          length++;
          if (distance > 0x2000) {
            length++;
            if (distance > 0x40000) length++;
          }
        }
        _old[3] = _old[2];
        _old[2] = _old[1];
        _old[1] = _old[0];
        _old[0] = distance;
        _lastLen = length;
        _copy(length, distance, limit);
      } else if (slot == 256) {
        final start = _filterData(r);
        final length = _filterData(r);
        final type = r.take(3);
        var channels = 0;
        if (type == 0) channels = r.take(5) + 1;
        if (type > 3) _bad('filter type $type');
        // unrar's limits: a filter covers at most 4 MiB, 8192 wait at once.
        if (length > 0x400000) _bad('filter of $length bytes');
        if (filters.length >= 8192) _bad('more than 8192 filters');
        filters.add((start: _pos + start, length: length, type: type, channels: channels));
      } else if (slot == 257) {
        if (_lastLen != 0) _copy(_lastLen, _old[0], limit);
      } else {
        final k = slot - 258;
        final distance = _old[k];
        for (var j = k; j > 0; j--) {
          _old[j] = _old[j - 1];
        }
        _old[0] = distance;
        final length = _length(r, rep.decode(r));
        _lastLen = length;
        _copy(length, distance, limit);
      }
    }
  }

  int _filterData(_Bits r) {
    final count = r.take(2) + 1;
    var v = 0;
    for (var k = 0; k < count; k++) {
      v |= r.take(8) << (8 * k);
    }
    return v;
  }

  /// Apply [f] to [out] at [at]; [fileOffset] is that position in the file.
  void _applyFilter(Uint8List out, int at, _Filter f, int fileOffset) {
    if (at < 0 || at + f.length > out.length) return;
    final n = f.length;
    switch (f.type) {
      case 0: // delta: the bytes come channel by channel
        final src = Uint8List.fromList(Uint8List.sublistView(out, at, at + n));
        var s = 0;
        for (var c = 0; c < f.channels; c++) {
          var prev = 0;
          for (var d = c; d < n; d += f.channels) {
            prev = (prev - src[s++]) & 0xFF;
            out[at + d] = prev;
          }
        }
      case 1 || 2: // E8, E8E9: x86 CALL/JMP targets
        const fileSize = 0x1000000;
        final e9 = f.type == 2;
        for (var p = 0; p + 4 < n;) {
          final c = out[at + p];
          p++;
          if (c == 0xE8 || (e9 && c == 0xE9)) {
            final offset = (p + fileOffset) % fileSize;
            final a = at + p;
            final addr = out[a] | out[a + 1] << 8 | out[a + 2] << 16 | out[a + 3] << 24;
            int? v;
            if (addr & 0x80000000 != 0) {
              if ((addr + offset) & 0x80000000 == 0) v = addr + fileSize;
            } else if ((addr - fileSize) & 0x80000000 != 0) {
              v = addr - offset;
            }
            if (v != null) {
              out[a] = v & 0xFF;
              out[a + 1] = v >> 8 & 0xFF;
              out[a + 2] = v >> 16 & 0xFF;
              out[a + 3] = v >> 24 & 0xFF;
            }
            p += 4;
          }
        }
      case 3: // ARM BL
        for (var p = 0; p + 3 < n; p += 4) {
          final a = at + p;
          if (out[a + 3] == 0xEB) {
            var offset = out[a] | out[a + 1] << 8 | out[a + 2] << 16;
            offset -= (fileOffset + p) ~/ 4;
            out[a] = offset & 0xFF;
            out[a + 1] = offset >> 8 & 0xFF;
            out[a + 2] = offset >> 16 & 0xFF;
          }
        }
    }
  }
}

// --- BLAKE2sp (RAR5's optional file hash) -------------------------------------

const _b2Iv = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19];

const _b2Sigma = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
  [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
  [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
  [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
  [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
  [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
  [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
  [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
  [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
];

/// BLAKE2sp-256 of [data]: eight BLAKE2s leaves, leaf i taking 64-byte
/// blocks i, i+8, …, then a root over their digests.
Uint8List blake2sp(Uint8List data) {
  final root = Uint8List(8 * 32);
  for (var i = 0; i < 8; i++) {
    final leaf = _Blake2s(offset: i, depth: 0, last: i == 7);
    final blocks = <int>[for (var at = i * 64; at < data.length; at += 8 * 64) at];
    for (var k = 0; k < blocks.length; k++) {
      final at = blocks[k];
      final end = at + 64 < data.length ? at + 64 : data.length;
      leaf.block(data, at, end, k == blocks.length - 1);
    }
    if (blocks.isEmpty) leaf.block(data, 0, 0, true);
    root.setRange(i * 32, i * 32 + 32, leaf.digest());
  }
  final r = _Blake2s(offset: 0, depth: 1, last: true);
  for (var at = 0; at < root.length; at += 64) {
    r.block(root, at, at + 64, at + 64 == root.length);
  }
  return r.digest();
}

/// One BLAKE2s node of BLAKE2sp's tree (fanout 8, depth 2, 32-byte digests).
final class _Blake2s {
  _Blake2s({required int offset, required int depth, required bool last}) : _lastNode = last {
    _h.setAll(0, _b2Iv);
    _h[0] ^= 32 | 8 << 16 | 2 << 24;
    _h[2] ^= offset;
    _h[3] ^= depth << 16 | 32 << 24;
  }

  final bool _lastNode;
  final _h = Uint32List(8);
  final _m = Uint32List(16);
  final _v = Uint32List(16);
  var _t = 0;

  /// Compress [b]'s bytes [at]..[end] (at most 64; zero-padded), the final
  /// block when [last].
  void block(Uint8List b, int at, int end, bool last) {
    final m = _m..fillRange(0, 16, 0);
    for (var i = at; i < end; i++) {
      m[(i - at) >> 2] |= b[i] << (8 * ((i - at) & 3));
    }
    _t += end - at;
    final v = _v
      ..setAll(0, _h)
      ..setAll(8, _b2Iv);
    v[12] ^= _t & 0xFFFFFFFF;
    v[13] ^= _t >> 32;
    if (last) {
      v[14] ^= 0xFFFFFFFF;
      if (_lastNode) v[15] ^= 0xFFFFFFFF;
    }
    for (final s in _b2Sigma) {
      _g(v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
      _g(v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
      _g(v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
      _g(v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
      _g(v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
      _g(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
      _g(v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
      _g(v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
    }
    for (var i = 0; i < 8; i++) {
      _h[i] ^= v[i] ^ v[i + 8];
    }
  }

  static void _g(Uint32List v, int a, int b, int c, int d, int x, int y) {
    var va = v[a], vb = v[b], vc = v[c], vd = v[d];
    va = (va + vb + x) & 0xFFFFFFFF;
    vd ^= va;
    vd = (vd >> 16 | vd << 16) & 0xFFFFFFFF;
    vc = (vc + vd) & 0xFFFFFFFF;
    vb ^= vc;
    vb = (vb >> 12 | vb << 20) & 0xFFFFFFFF;
    va = (va + vb + y) & 0xFFFFFFFF;
    vd ^= va;
    vd = (vd >> 8 | vd << 24) & 0xFFFFFFFF;
    vc = (vc + vd) & 0xFFFFFFFF;
    vb ^= vc;
    vb = (vb >> 7 | vb << 25) & 0xFFFFFFFF;
    v[a] = va;
    v[b] = vb;
    v[c] = vc;
    v[d] = vd;
  }

  Uint8List digest() {
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = _h[i >> 2] >> (8 * (i & 3)) & 0xFF;
    }
    return out;
  }
}

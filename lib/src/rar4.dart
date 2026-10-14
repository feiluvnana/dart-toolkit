part of 'rar.dart';

// RAR4 (RAR 2.9/3.x/4.x archives): the block headers, Unicode names, the
// LZ + Huffman decoder with delta-coded tables, the six standard VM
// filters (run natively: RAR's VM bytecode is recognised by its CRC, never
// executed) and AES-128 under RAR's SHA-1 key rounds. PPMd blocks and RAR
// 1.5/2.x members are named in a FormatException.

/// The members of a RAR4 archive in [b].
List<RarEntry> _readRar4(Uint8List b, String? password) {
  var pos = 7;
  var encryptedHeaders = false;
  final out = <RarEntry>[];
  var run = _Run4();
  while (pos + 7 <= b.length) {
    // An encrypted header: an 8-byte salt, then the header in AES blocks.
    Uint8List h;
    var hp = 0;
    int headerEnd;
    if (encryptedHeaders) {
      if (password == null) throw const FormatException('archive is encrypted (pass password:)');
      if (pos + 8 + 16 > b.length) break;
      final salt = Uint8List.sublistView(b, pos, pos + 8);
      final k = _Key4.derive(password, salt);
      final first = k.aes.cbcDecrypt(Uint8List.sublistView(b, pos + 8, pos + 24), k.iv);
      final size = first[5] | first[6] << 8;
      if (size < 7) throw const FormatException('wrong password or corrupt archive');
      final total = (size + 15) & ~15;
      if (pos + 8 + total > b.length) throw const FormatException('wrong password or corrupt archive');
      h = k.aes.cbcDecrypt(Uint8List.sublistView(b, pos + 8, pos + 8 + total), k.iv);
      headerEnd = pos + 8 + total;
    } else {
      h = b;
      hp = pos;
      headerEnd = -1;
    }
    final crc = h[hp] | h[hp + 1] << 8;
    final type = h[hp + 2];
    final flags = h[hp + 3] | h[hp + 4] << 8;
    final size = h[hp + 5] | h[hp + 6] << 8;
    if (size < 7 || hp + size > h.length) {
      if (encryptedHeaders) throw const FormatException('wrong password or corrupt archive');
      _bad('header past the end');
    }
    if (type != 0x72 && (crc32(h, start: hp + 2, end: hp + size) & 0xFFFF) != crc) {
      if (encryptedHeaders) throw const FormatException('wrong password or corrupt archive');
      _bad('header CRC');
    }
    var addSize = 0;
    if (flags & 0x8000 != 0 || type == 0x74 || type == 0x7A) addSize = _u32le(h, hp + 7);
    final dataStart = encryptedHeaders ? headerEnd : pos + size;
    if (type == 0x74) {
      final hi = flags & 0x100 != 0 ? _u32le(h, hp + 32) : 0;
      addSize += hi * 0x100000000;
    }
    if (dataStart + addSize > b.length) _bad('data past the end');
    switch (type) {
      case 0x73: // main
        if (flags & 0x0001 != 0) throw const FormatException('multi-volume RAR archives are not supported');
        encryptedHeaders = flags & 0x0080 != 0;
      case 0x74: // file
        final entry = _file4(h, hp, flags, b, dataStart, addSize, password, flags & 0x10 != 0 ? run : run = _Run4());
        out.add(entry);
      case 0x7B: // end
        return out;
      default:
        break;
    }
    pos = dataStart + addSize;
  }
  return out;
}

int _u32le(Uint8List b, int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;

RarEntry _file4(Uint8List h, int hp, int flags, Uint8List b, int dataStart, int packSize, String? password, _Run4 run) {
  var size = _u32le(h, hp + 11);
  final host = h[hp + 15];
  final crc = _u32le(h, hp + 16);
  final version = h[hp + 24];
  final method = h[hp + 25];
  final nameSize = h[hp + 26] | h[hp + 27] << 8;
  final attrs = _u32le(h, hp + 28);
  var p = hp + 32;
  if (flags & 0x100 != 0) {
    size += _u32le(h, hp + 36) * 0x100000000;
    p += 8;
  }
  final rawName = Uint8List.sublistView(h, p, p + nameSize);
  p += nameSize;
  final name = _name4(rawName, flags & 0x200 != 0).replaceAll('\\', '/');
  Uint8List? salt;
  if (flags & 0x400 != 0) salt = Uint8List.sublistView(h, p, p + 8);
  if (flags & 0x03 != 0) throw const FormatException('multi-volume RAR archives are not supported');
  final isDir = flags & 0xE0 == 0xE0 || (host != 3 && attrs & 0x10 != 0);
  final mode = host == 3 ? attrs & 0xFFFF : 0;
  final isLink = mode & 0xF000 == 0xA000;
  if (isDir) return RarEntry(name, true, mode, () => Uint8List(0));
  final encrypted = flags & 0x04 != 0;
  if (encrypted && password == null) throw FormatException('archive member is encrypted: $name (pass password:)');
  final packed = Uint8List.sublistView(b, dataStart, dataStart + packSize);
  final index = run.add(() {
    var input = packed;
    if (encrypted) {
      final k = _Key4.derive(password!, salt ?? Uint8List(0));
      input = k.aes.cbcDecrypt(Uint8List.sublistView(packed, 0, packed.length & ~15), k.iv);
    }
    return (input, method, size, version);
  });
  return RarEntry(name, false, mode, () {
    Uint8List data;
    try {
      data = run.data(index);
    } on FormatException {
      // A wrong key turns the data into noise the decoder chokes on.
      if (encrypted) throw FormatException('wrong password or corrupt archive: $name');
      rethrow;
    }
    if (crc32(data) != crc) {
      throw FormatException(
        encrypted ? 'wrong password or corrupt archive: $name' : 'corrupt archive: RAR CRC of $name',
      );
    }
    return data;
  }, isLink: isLink);
}

/// RAR4 names: the bytes as given, or with the Unicode flag an ASCII part,
/// a zero, then RAR's compact UTF-16 (UTF-8 when there is no zero).
String _name4(Uint8List raw, bool unicode) {
  final zero = raw.indexOf(0);
  if (!unicode || zero < 0) return utf8.decode(raw, allowMalformed: true);
  final ascii = Uint8List.sublistView(raw, 0, zero);
  final enc = Uint8List.sublistView(raw, zero + 1);
  final out = <int>[];
  var e = 0;
  final high = e < enc.length ? enc[e++] : 0;
  var flags = 0, bits = 0;
  int at(int i) => i < enc.length ? enc[i] : 0;
  while (e < enc.length) {
    if (bits == 0) {
      flags = enc[e++];
      bits = 8;
    }
    switch (flags >> 6) {
      case 0:
        out.add(at(e++));
      case 1:
        out.add(at(e++) + (high << 8));
      case 2:
        out.add(at(e) + (at(e + 1) << 8));
        e += 2;
      default:
        var length = at(e++);
        if (length & 0x80 != 0) {
          final correction = at(e++);
          for (length = (length & 0x7F) + 2; length > 0; length--) {
            final i = out.length;
            out.add(((i < ascii.length ? ascii[i] : 0) + correction & 0xFF) + (high << 8));
          }
        } else {
          for (length += 2; length > 0; length--) {
            final i = out.length;
            out.add(i < ascii.length ? ascii[i] : 0);
          }
        }
    }
    flags = flags << 2 & 0xFF;
    bits -= 2;
  }
  return String.fromCharCodes(out);
}

/// RAR4 keys: AES-128 from 2^18 SHA-1 rounds over the UTF-16LE password,
/// the salt and a 3-byte counter; the IV collects a byte of 16 snapshots.
final class _Key4 {
  _Key4(List<int> key, this.iv) : aes = Aes(key);
  final Aes aes;
  final Uint8List iv;

  static final _cache = <String, _Key4>{};

  static _Key4 derive(String password, Uint8List salt) {
    final id = '${salt.join(',')}:$password';
    return _cache[id] ??= () {
      final raw = <int>[];
      for (final c in password.codeUnits) {
        raw
          ..add(c & 0xFF)
          ..add(c >> 8);
      }
      raw.addAll(salt);
      const rounds = 0x40000;
      final sha = _Sha1();
      final iv = Uint8List(16);
      final unit = Uint8List(raw.length + 3)..setRange(0, raw.length, raw);
      for (var i = 0; i < rounds; i++) {
        unit[raw.length] = i & 0xFF;
        unit[raw.length + 1] = i >> 8 & 0xFF;
        unit[raw.length + 2] = i >> 16 & 0xFF;
        sha.add(unit);
        if (i % (rounds ~/ 16) == 0) iv[i ~/ (rounds ~/ 16)] = sha.copy().digest()[19];
      }
      final d = sha.digest();
      final key = Uint8List(16);
      for (var w = 0; w < 4; w++) {
        for (var j = 0; j < 4; j++) {
          key[w * 4 + j] = d[w * 4 + 3 - j];
        }
      }
      return _Key4(key, iv);
    }();
  }
}

/// SHA-1 whose running state can be copied (RAR4's IV needs snapshots).
final class _Sha1 {
  _Sha1();
  _Sha1._copy(_Sha1 o)
    : _h = Uint32List.fromList(o._h),
      _buf = Uint8List.fromList(o._buf),
      _used = o._used,
      _length = o._length;

  var _h = Uint32List.fromList([0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]);
  var _buf = Uint8List(64);
  var _used = 0;
  var _length = 0;
  final _w = Uint32List(80);

  _Sha1 copy() => _Sha1._copy(this);

  void add(List<int> data) {
    _length += data.length;
    for (final v in data) {
      _buf[_used++] = v;
      if (_used == 64) {
        _block();
        _used = 0;
      }
    }
  }

  Uint8List digest() {
    final bits = _length * 8;
    add([0x80]);
    while (_used != 56) {
      add([0]);
    }
    for (var k = 7; k >= 0; k--) {
      _buf[_used++] = bits >> (8 * k) & 0xFF;
    }
    _block();
    final out = Uint8List(20);
    for (var i = 0; i < 5; i++) {
      out[4 * i] = _h[i] >> 24;
      out[4 * i + 1] = _h[i] >> 16 & 0xFF;
      out[4 * i + 2] = _h[i] >> 8 & 0xFF;
      out[4 * i + 3] = _h[i] & 0xFF;
    }
    return out;
  }

  void _block() {
    final w = _w;
    for (var i = 0; i < 16; i++) {
      w[i] = _buf[4 * i] << 24 | _buf[4 * i + 1] << 16 | _buf[4 * i + 2] << 8 | _buf[4 * i + 3];
    }
    for (var i = 16; i < 80; i++) {
      final x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
      w[i] = x << 1 | x >> 31;
    }
    var a = _h[0], b = _h[1], c = _h[2], d = _h[3], e = _h[4];
    for (var i = 0; i < 80; i++) {
      int f, k;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final t = ((a << 5 | a >> 27) + (f & 0xFFFFFFFF) + e + k + w[i]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = (b << 30 | b >> 2) & 0xFFFFFFFF;
      b = a;
      a = t;
    }
    _h[0] += a;
    _h[1] += b;
    _h[2] += c;
    _h[3] += d;
    _h[4] += e;
  }
}

/// One RAR4 solid run: members decode in order through one window.
final class _Run4 {
  final _inputs = <(Uint8List, int, int, int) Function()>[];
  final _done = <Uint8List>[];
  _Unpack3? _unpack;

  int add((Uint8List, int, int, int) Function() input) {
    _inputs.add(input);
    return _inputs.length - 1;
  }

  Uint8List data(int index) {
    while (_done.length <= index) {
      final (packed, method, size, version) = _inputs[_done.length]();
      final u = _unpack ??= _Unpack3();
      if (method == 0x30) {
        if (packed.length < size) _bad('stored member is short');
        final bytes = Uint8List.sublistView(packed, 0, size);
        u.append(bytes);
        _done.add(bytes);
      } else {
        if (version != 29 && version != 36) {
          throw FormatException('unsupported RAR4 compression version $version (RAR 1.5/2.x)');
        }
        _done.add(u.decode(packed, size, solid: _done.isNotEmpty));
      }
    }
    return _done[index];
  }
}

const _nc3 = 299, _dc3 = 60, _ldc3 = 17, _rc3 = 28;
const _lDecode = [
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  10,
  12,
  14,
  16,
  20,
  24,
  28,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
];
const _lBits = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5];
const _sdDecode = [0, 4, 8, 16, 32, 64, 128, 192];
const _sdBits = [2, 2, 3, 4, 5, 6, 6, 6];

final (Int32List, Uint8List) _dTables = () {
  // Slots per bit count: 4 with 0 bits, 2 each for 1..15, 14 with 16, 12 with 18.
  const counts = [4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 14, 0, 12];
  final decode = Int32List(_dc3), bits = Uint8List(_dc3);
  var dist = 0, slot = 0;
  for (var len = 0; len < counts.length; len++) {
    for (var j = 0; j < counts[len]; j++, slot++, dist += 1 << len) {
      decode[slot] = dist;
      bits[slot] = len;
    }
  }
  return (decode, bits);
}();

typedef _Filter3 = ({int start, int length, int type, Int32List regs});

/// The RAR 2.9 decoder: the window is every byte of the solid run.
final class _Unpack3 {
  var _window = Uint8List(1 << 16);
  var _pos = 0;
  final _old = Int64List(4);
  var _lastLen = 0;
  var _prevLowDist = 0, _lowDistRep = 0;
  final _oldTable = Uint8List(_nc3 + _dc3 + _ldc3 + _rc3);
  _Huff? _main, _dist, _low, _rep;
  var _tablesRead = false;
  // Filters: definitions by number, each remembering its last length.
  final _programs = <int>[]; // standard filter type per definition
  final _oldLengths = <int>[];
  var _lastFilter = 0;

  // Each member's packed data starts afresh at its first bit (encrypted
  // members carry AES padding at their end); the window, tables and PPM
  // model carry across a solid run.
  late _Bits _r;

  // PPM mode: the model, its coder (reading bytes through [_r]) and the
  // escape byte, all kept across blocks and members until a reset.
  var _ppmBlock = false;
  Ppmd? _ppm;
  RarPpmdCoder? _coder;
  var _escChar = 2;

  int _byte() {
    final i = _r.pos >> 3;
    _r.pos += 8;
    return i < _r.b.length ? _r.b[i] : 0;
  }

  void _grow(int need) {
    if (need <= _window.length) return;
    var n = _window.length * 2;
    while (n < need) {
      n *= 2;
    }
    _window = Uint8List(n)..setRange(0, _pos, _window);
  }

  void append(Uint8List bytes) {
    _grow(_pos + bytes.length);
    _window.setRange(_pos, _pos + bytes.length, bytes);
    _pos += bytes.length;
  }

  Uint8List decode(Uint8List input, int size, {required bool solid}) {
    final begin = _pos;
    _grow(_pos + size);
    if (!solid) {
      _old.fillRange(0, 4, 0);
      _lastLen = 0;
      _oldTable.fillRange(0, _oldTable.length, 0);
      _prevLowDist = _lowDistRep = 0;
      _tablesRead = false;
      _programs.clear();
      _oldLengths.clear();
      _lastFilter = 0;
      _ppmBlock = false;
      _ppm = null;
      _coder = null;
      _escChar = 2;
    }
    final r = _r = _Bits(input, 0, input.length * 8);
    final filters = <_Filter3>[];
    if (!_tablesRead || !solid) _readTables(r);
    final limit = begin + size;
    final w = _window; // grown to fit above
    while (_pos < limit) {
      if (r.pos > r.end + 64) _bad('data ends early');
      if (_ppmBlock) {
        if (!_ppmStep(filters, limit)) break;
        continue;
      }
      final n = _main!.decode(r);
      if (n < 256) {
        w[_pos++] = n;
      } else if (n >= 271) {
        final k = n - 271;
        var length = _lDecode[k] + 3;
        if (_lBits[k] > 0) length += r.take(_lBits[k]);
        final dn = _dist!.decode(r);
        if (dn >= _dc3) _bad('distance code');
        var distance = _dTables.$1[dn] + 1;
        final bits = _dTables.$2[dn];
        if (bits > 0) {
          if (dn > 9) {
            if (bits > 4) {
              distance += (r.peek16() >> (20 - bits)) << 4;
              r.skip(bits - 4);
            }
            if (_lowDistRep > 0) {
              _lowDistRep--;
              distance += _prevLowDist;
            } else {
              final low = _low!.decode(r);
              if (low == 16) {
                _lowDistRep = 15;
                distance += _prevLowDist;
              } else {
                distance += low;
                _prevLowDist = low;
              }
            }
          } else {
            distance += r.take(bits);
          }
        }
        if (distance >= 0x2000) {
          length++;
          if (distance >= 0x40000) length++;
        }
        _insertOld(distance);
        _lastLen = length;
        _copy(length, distance, limit);
      } else if (n == 256) {
        // End of block: a new file, or new tables.
        final field = r.peek16();
        if (field & 0x8000 != 0) {
          r.skip(1);
          _readTables(r);
        } else {
          // A new file: its tables (if flagged) come at its own start.
          r.skip(2);
          _tablesRead = field & 0x4000 == 0;
          break;
        }
      } else if (n == 257) {
        _readVmCode(r, filters);
      } else if (n == 258) {
        if (_lastLen != 0) _copy(_lastLen, _old[0], limit);
      } else if (n < 263) {
        final k = n - 259;
        final distance = _old[k];
        for (var j = k; j > 0; j--) {
          _old[j] = _old[j - 1];
        }
        _old[0] = distance;
        final ln = _rep!.decode(r);
        if (ln >= _rc3) _bad('length code');
        var length = _lDecode[ln] + 2;
        if (_lBits[ln] > 0) length += r.take(_lBits[ln]);
        _lastLen = length;
        _copy(length, distance, limit);
      } else {
        final k = n - 263;
        var distance = _sdDecode[k] + 1;
        if (_sdBits[k] > 0) distance += r.take(_sdBits[k]);
        _insertOld(distance);
        _lastLen = 2;
        _copy(2, distance, limit);
      }
    }
    if (_pos < limit) _bad('data ends early');
    _pos = limit;
    final out = Uint8List.fromList(Uint8List.sublistView(_window, begin, limit));
    for (final f in filters) {
      _runFilter(out, f, f.start - begin);
    }
    return out;
  }

  void _insertOld(int d) {
    _old[3] = _old[2];
    _old[2] = _old[1];
    _old[1] = _old[0];
    _old[0] = d;
  }

  void _copy(int length, int distance, int limit) {
    final from = _pos - distance;
    if (from < 0) _bad('distance before the start');
    if (_pos + length > limit) length = limit - _pos;
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

  void _readTables(_Bits r) {
    r.pos = (r.pos + 7) & ~7; // byte-aligned
    final field = r.peek16();
    if (field & 0x8000 != 0) {
      _ppmInit();
      return;
    }
    _ppmBlock = false;
    _prevLowDist = _lowDistRep = 0;
    if (field & 0x4000 == 0) _oldTable.fillRange(0, _oldTable.length, 0);
    r.skip(2);
    final bitLens = Uint8List(20);
    for (var i = 0; i < 20; i++) {
      final l = r.take(4);
      if (l == 15) {
        final zeros = r.take(4);
        if (zeros == 0) {
          bitLens[i] = 15;
        } else {
          for (var k = 0; k < zeros + 2 && i < 20; k++) {
            bitLens[i++] = 0;
          }
          i--;
        }
      } else {
        bitLens[i] = l;
      }
    }
    final bc = _Huff(bitLens);
    final total = _oldTable.length;
    final table = Uint8List(total);
    for (var i = 0; i < total;) {
      final n = bc.decode(r);
      if (n < 16) {
        table[i] = (n + _oldTable[i]) & 0xF;
        i++;
      } else if (n < 18) {
        final repeat = n == 16 ? r.take(3) + 3 : r.take(7) + 11;
        if (i == 0) _bad('table repeats nothing');
        for (var k = 0; k < repeat && i < total; k++, i++) {
          table[i] = table[i - 1];
        }
      } else {
        final repeat = n == 18 ? r.take(3) + 3 : r.take(7) + 11;
        for (var k = 0; k < repeat && i < total; k++) {
          table[i++] = 0;
        }
      }
    }
    _tablesRead = true;
    _main = _Huff(Uint8List.sublistView(table, 0, _nc3));
    _dist = _Huff(Uint8List.sublistView(table, _nc3, _nc3 + _dc3));
    _low = _Huff(Uint8List.sublistView(table, _nc3 + _dc3, _nc3 + _dc3 + _ldc3));
    _rep = _Huff(Uint8List.sublistView(table, _nc3 + _dc3 + _ldc3, total));
    _oldTable.setRange(0, total, table);
  }

  /// A PPM block header: order and reset flags, memory, the escape byte,
  /// then the coder's first bytes.
  void _ppmInit() {
    final maxOrder = _byte();
    final reset = maxOrder & 0x20 != 0;
    var mb = 0;
    if (reset) {
      mb = _byte();
    } else if (_ppm == null) {
      _bad('PPM block continues a model that was never started');
    }
    if (maxOrder & 0x40 != 0) _escChar = _byte();
    _coder = RarPpmdCoder(_byte);
    if (reset) {
      var order = (maxOrder & 0x1F) + 1;
      if (order > 16) order = 16 + (order - 16) * 3;
      if (order == 1) _bad('PPM order');
      _ppm = Ppmd((mb + 1) << 20, order);
    }
    _ppmBlock = true;
  }

  int _ppmChar() {
    final c = _ppm!.decodeChar(_coder!);
    if (c < 0) _bad('PPM data');
    return c;
  }

  /// One PPM step; false at the end of the member.
  bool _ppmStep(List<_Filter3> filters, int limit) {
    final ch = _ppmChar();
    if (ch == _escChar) {
      final next = _ppmChar();
      switch (next) {
        case 0: // back to LZ: new tables
          _readTables(_r);
          return true;
        case 2: // end of the member
          return false;
        case 3:
          _readVmBytes(_ppmByteLength(), filters, _ppmChar);
          return true;
        case 4:
          var distance = 0;
          for (var i = 0; i < 3; i++) {
            distance = distance << 8 | _ppmChar();
          }
          final length = _ppmChar();
          _copy(length + 32, distance + 2, limit);
          return true;
        case 5:
          _copy(_ppmChar() + 4, 1, limit);
          return true;
        default:
          break; // 1: the escape byte itself
      }
    }
    _window[_pos++] = ch;
    return true;
  }

  (int, int) _ppmByteLength() {
    final first = _ppmChar();
    var length = (first & 7) + 1;
    if (length == 7) {
      length = _ppmChar() + 7;
    } else if (length == 8) {
      length = _ppmChar() << 8 | _ppmChar();
    }
    return (first, length);
  }

  void _readVmCode(_Bits r, List<_Filter3> filters) {
    final first = r.take(8);
    var length = (first & 7) + 1;
    if (length == 7) {
      length = r.take(8) + 7;
    } else if (length == 8) {
      length = r.take(16);
    }
    _readVmBytes((first, length), filters, () => r.take(8));
  }

  void _readVmBytes((int, int) head, List<_Filter3> filters, int Function() next) {
    final (first, length) = head;
    if (length == 0) _bad('empty filter');
    final code = Uint8List(length);
    for (var i = 0; i < length; i++) {
      code[i] = next();
    }
    final v = _Bits(code, 0, code.length * 8);
    int pos;
    if (first & 0x80 != 0) {
      pos = _vmData(v);
      if (pos == 0) {
        _programs.clear();
        _oldLengths.clear();
      } else {
        pos--;
      }
    } else {
      pos = _lastFilter;
    }
    if (pos > _programs.length) _bad('filter number');
    _lastFilter = pos;
    final isNew = pos == _programs.length;
    if (isNew) {
      _programs.add(-1);
      _oldLengths.add(0);
    }
    var start = _vmData(v);
    if (first & 0x40 != 0) start += 258;
    int blockLength;
    if (first & 0x20 != 0) {
      blockLength = _vmData(v);
      _oldLengths[pos] = blockLength;
    } else {
      blockLength = _oldLengths[pos];
    }
    final regs = Int32List(7);
    regs[4] = blockLength;
    if (first & 0x10 != 0) {
      final mask = v.take(7);
      for (var i = 0; i < 7; i++) {
        if (mask & (1 << i) != 0) regs[i] = _vmData(v);
      }
    }
    if (isNew) {
      final size = _vmData(v);
      if (size == 0 || size >= 0x10000) _bad('filter code size');
      final program = Uint8List(size);
      for (var i = 0; i < size; i++) {
        program[i] = v.take(8);
      }
      _programs[pos] = _standardFilter(program);
    }
    filters.add((start: _pos + start, length: blockLength, type: _programs[pos], regs: regs));
  }

  /// RarVM's variable-length number.
  static int _vmData(_Bits v) {
    final data = v.peek16();
    switch (data & 0xC000) {
      case 0:
        v.skip(6);
        return data >> 10 & 0xF;
      case 0x4000:
        if (data & 0x3C00 == 0) {
          v.skip(14);
          return 0xFFFFFF00 | (data >> 2 & 0xFF);
        }
        v.skip(10);
        return data >> 6 & 0xFF;
      case 0x8000:
        v.skip(2);
        return v.take(16);
      default:
        v.skip(2);
        final hi = v.take(16);
        return hi << 16 | v.take(16);
    }
  }

  /// RAR's standard filters, known by length and CRC of their bytecode.
  static int _standardFilter(Uint8List code) {
    final crc = crc32(code);
    return switch ((code.length, crc)) {
      (53, 0xAD576887) => 1, // E8
      (57, 0x3CD7E57E) => 2, // E8E9
      (120, 0x3769893F) => 3, // Itanium
      (29, 0x0E06077D) => 4, // delta
      (149, 0x1C2C5DC8) => 5, // RGB
      (216, 0xBC85E701) => 6, // audio
      _ => throw const FormatException('unsupported RAR4 filter (custom VM code)'),
    };
  }

  void _runFilter(Uint8List out, _Filter3 f, int at) {
    final n = f.length;
    if (at < 0 || at + n > out.length || n <= 0) return;
    final src = Uint8List.fromList(Uint8List.sublistView(out, at, at + n));
    final dst = Uint8List.sublistView(out, at, at + n);
    final r = f.regs;
    switch (f.type) {
      case 1 || 2:
        if (n < 4) return;
        const fileSize = 0x1000000;
        for (var p = 0; p < n - 4;) {
          final c = dst[p];
          p++;
          if (c == 0xE8 || (f.type == 2 && c == 0xE9)) {
            final offset = p + at;
            final addr = dst[p] | dst[p + 1] << 8 | dst[p + 2] << 16 | dst[p + 3] << 24;
            int? v;
            if (addr & 0x80000000 != 0) {
              if ((addr + offset) & 0x80000000 == 0) v = addr + fileSize;
            } else if ((addr - fileSize) & 0x80000000 != 0) {
              v = addr - offset;
            }
            if (v != null) {
              dst[p] = v & 0xFF;
              dst[p + 1] = v >> 8 & 0xFF;
              dst[p + 2] = v >> 16 & 0xFF;
              dst[p + 3] = v >> 24 & 0xFF;
            }
            p += 4;
          }
        }
      case 3:
        throw const FormatException('unsupported RAR4 Itanium filter');
      case 4: // delta
        final channels = r[0];
        if (channels <= 0) _bad('delta channels');
        var s = 0;
        for (var c = 0; c < channels; c++) {
          var prev = 0;
          for (var d = c; d < n; d += channels) {
            prev = (prev - src[s++]) & 0xFF;
            dst[d] = prev;
          }
        }
      case 5: // RGB
        final width = r[0] - 3, posR = r[1];
        if (n < 3 || width > n || width < 0 || posR > 2) _bad('RGB filter');
        var s = 0;
        for (var c = 0; c < 3; c++) {
          var prev = 0;
          for (var i = c; i < n; i += 3) {
            var predicted = prev;
            if (i >= width + 3) {
              final upper = dst[i - width], upperLeft = dst[i - width - 3];
              predicted = prev + upper - upperLeft;
              final pa = (predicted - prev).abs(), pb = (predicted - upper).abs(), pc = (predicted - upperLeft).abs();
              predicted = pa <= pb && pa <= pc ? prev : (pb <= pc ? upper : upperLeft);
            }
            prev = (predicted - src[s++]) & 0xFF;
            dst[i] = prev;
          }
        }
        for (var i = posR; i < n - 2; i += 3) {
          final g = dst[i + 1];
          dst[i] = (dst[i] + g) & 0xFF;
          dst[i + 2] = (dst[i + 2] + g) & 0xFF;
        }
      case 6: // audio
        final channels = r[0];
        if (channels <= 0) _bad('audio channels');
        var s = 0;
        int signed(int b) => b >= 128 ? b - 256 : b;
        for (var c = 0; c < channels; c++) {
          var prevByte = 0, prevDelta = 0, d1 = 0, d2 = 0, d3 = 0, k1 = 0, k2 = 0, k3 = 0;
          final dif = List.filled(7, 0);
          var count = 0;
          for (var i = c; i < n; i += channels, count++) {
            d3 = d2;
            d2 = prevDelta - d1;
            d1 = prevDelta;
            var predicted = (8 * prevByte + k1 * d1 + k2 * d2 + k3 * d3) >> 3 & 0xFF;
            final cur = src[s++];
            predicted = (predicted - cur) & 0xFF;
            dst[i] = predicted;
            prevDelta = signed((predicted - prevByte) & 0xFF);
            prevByte = predicted;
            final d = signed(cur) << 3;
            dif[0] += d.abs();
            dif[1] += (d - d1).abs();
            dif[2] += (d + d1).abs();
            dif[3] += (d - d2).abs();
            dif[4] += (d + d2).abs();
            dif[5] += (d - d3).abs();
            dif[6] += (d + d3).abs();
            if (count & 0x1F == 0) {
              var min = dif[0], which = 0;
              dif[0] = 0;
              for (var j = 1; j < 7; j++) {
                if (dif[j] < min) {
                  min = dif[j];
                  which = j;
                }
                dif[j] = 0;
              }
              switch (which) {
                case 1:
                  if (k1 >= -16) k1--;
                case 2:
                  if (k1 < 16) k1++;
                case 3:
                  if (k2 >= -16) k2--;
                case 4:
                  if (k2 < 16) k2++;
                case 5:
                  if (k3 >= -16) k3--;
                case 6:
                  if (k3 < 16) k3++;
              }
            }
          }
        }
    }
  }
}

// ignore_for_file: avoid_annotating_with_dynamic
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// A streaming message digest: [update] bytes, then [digest] once.
abstract interface class Hasher {
  void update(Object data);
  Uint8List digest();
}

List<int> _bytes(Object data) {
  if (data is Uint8List) return data;
  if (data is List<int>) return data;
  if (data is String) return utf8.encode(data);
  throw ArgumentError.value(data, 'data', 'Must be String, List<int> or Uint8List');
}

int _add32(int a, int b) => (a + b) & 0xFFFFFFFF;
int _rotl32(int x, int c) => ((x << c) | (x >>> (32 - c))) & 0xFFFFFFFF;
int _rotr32(int x, int c) => ((x >>> c) | (x << (32 - c))) & 0xFFFFFFFF;

// ---------------------------------------------------------------------------
// CRC-32 (IEEE)
// ---------------------------------------------------------------------------

final List<int> _crcTable = List<int>.generate(256, (i) {
  var c = i;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
  }
  return c;
});

int _crc32Int(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Uint8List _crc32Compute(List<int> data, List<int>? key) {
  final v = _crc32Int(data);
  return Uint8List.fromList([(v >>> 24) & 0xFF, (v >>> 16) & 0xFF, (v >>> 8) & 0xFF, v & 0xFF]);
}

// ---------------------------------------------------------------------------
// MD5
// ---------------------------------------------------------------------------

final List<int> _md5K = List<int>.generate(64, (i) => (math.pow(2, 32) * math.sin(i + 1)).abs().floor() & 0xFFFFFFFF);
const List<int> _md5S = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

Uint8List _md5Compute(List<int> data, List<int>? key) {
  if (key != null) return _hmac(64, (d) => _md5Compute(d, null), key, data);
  final msg = BytesBuilder(copy: true)..add(data);
  final bitLen = data.length * 8;
  msg.addByte(0x80);
  while (msg.length % 64 != 56) {
    msg.addByte(0);
  }
  for (var i = 0; i < 8; i++) {
    msg.addByte((bitLen >>> (8 * i)) & 0xFF);
  }
  final bytes = msg.takeBytes();
  var a0 = 0x67452301, b0 = 0xEFCDAB89, c0 = 0x98BADCFE, d0 = 0x10325476;
  for (var off = 0; off < bytes.length; off += 64) {
    final m = List<int>.generate(16, (i) => _readLE32(bytes, off + i * 4));
    var a = a0, b = b0, c = c0, d = d0;
    for (var i = 0; i < 64; i++) {
      int f;
      int g;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      final tmp = d;
      d = c;
      c = b;
      b = _add32(b, _rotl32(_add32(_add32(a, f & 0xFFFFFFFF), _add32(_md5K[i], m[g])), _md5S[i]));
      a = tmp;
    }
    a0 = _add32(a0, a);
    b0 = _add32(b0, b);
    c0 = _add32(c0, c);
    d0 = _add32(d0, d);
  }
  final out = Uint8List(16);
  for (final (i, v) in [a0, b0, c0, d0].indexed) {
    for (var j = 0; j < 4; j++) {
      out[i * 4 + j] = (v >>> (8 * j)) & 0xFF;
    }
  }
  return out;
}

int _readLE32(List<int> b, int i) =>
    (b[i] & 0xFF) | ((b[i + 1] & 0xFF) << 8) | ((b[i + 2] & 0xFF) << 16) | ((b[i + 3] & 0xFF) << 24);

// ---------------------------------------------------------------------------
// SHA-256
// ---------------------------------------------------------------------------

const List<int> _sha256K = [
  0x428A2F98,
  0x71374491,
  0xB5C0FBCF,
  0xE9B5DBA5,
  0x3956C25B,
  0x59F111F1,
  0x923F82A4,
  0xAB1C5ED5,
  0xD807AA98,
  0x12835B01,
  0x243185BE,
  0x550C7DC3,
  0x72BE5D74,
  0x80DEB1FE,
  0x9BDC06A7,
  0xC19BF174,
  0xE49B69C1,
  0xEFBE4786,
  0x0FC19DC6,
  0x240CA1CC,
  0x2DE92C6F,
  0x4A7484AA,
  0x5CB0A9DC,
  0x76F988DA,
  0x983E5152,
  0xA831C66D,
  0xB00327C8,
  0xBF597FC7,
  0xC6E00BF3,
  0xD5A79147,
  0x06CA6351,
  0x14292967,
  0x27B70A85,
  0x2E1B2138,
  0x4D2C6DFC,
  0x53380D13,
  0x650A7354,
  0x766A0ABB,
  0x81C2C92E,
  0x92722C85,
  0xA2BFE8A1,
  0xA81A664B,
  0xC24B8B70,
  0xC76C51A3,
  0xD192E819,
  0xD6990624,
  0xF40E3585,
  0x106AA070,
  0x19A4C116,
  0x1E376C08,
  0x2748774C,
  0x34B0BCB5,
  0x391C0CB3,
  0x4ED8AA4A,
  0x5B9CCA4F,
  0x682E6FF3,
  0x748F82EE,
  0x78A5636F,
  0x84C87814,
  0x8CC70208,
  0x90BEFFFA,
  0xA4506CEB,
  0xBEF9A3F7,
  0xC67178F2,
];

Uint8List _sha256Compute(List<int> data, List<int>? key) {
  if (key != null) return _hmac(64, (d) => _sha256Compute(d, null), key, data);
  final msg = BytesBuilder(copy: true)..add(data);
  final bitLen = data.length * 8;
  msg.addByte(0x80);
  while (msg.length % 64 != 56) {
    msg.addByte(0);
  }
  for (var i = 7; i >= 0; i--) {
    msg.addByte((bitLen >>> (8 * i)) & 0xFF);
  }
  final bytes = msg.takeBytes();
  final h = [
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, //
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
  ];
  final w = List<int>.filled(64, 0);
  for (var off = 0; off < bytes.length; off += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] =
          (bytes[off + i * 4] << 24) |
          (bytes[off + i * 4 + 1] << 16) |
          (bytes[off + i * 4 + 2] << 8) |
          bytes[off + i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = _add32(_add32(w[i - 16], s0), _add32(w[i - 7], s1));
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final ch = (e & f) ^ (~e & g);
      final t1 = _add32(_add32(_add32(hh, s1), _add32(ch, _sha256K[i])), w[i]);
      final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = _add32(s0, maj);
      hh = g;
      g = f;
      f = e;
      e = _add32(d, t1);
      d = c;
      c = b;
      b = a;
      a = _add32(t1, t2);
    }
    h[0] = _add32(h[0], a);
    h[1] = _add32(h[1], b);
    h[2] = _add32(h[2], c);
    h[3] = _add32(h[3], d);
    h[4] = _add32(h[4], e);
    h[5] = _add32(h[5], f);
    h[6] = _add32(h[6], g);
    h[7] = _add32(h[7], hh);
  }
  final out = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (h[i] >>> 24) & 0xFF;
    out[i * 4 + 1] = (h[i] >>> 16) & 0xFF;
    out[i * 4 + 2] = (h[i] >>> 8) & 0xFF;
    out[i * 4 + 3] = h[i] & 0xFF;
  }
  return out;
}

// ---------------------------------------------------------------------------
// SHA-512
// ---------------------------------------------------------------------------

const List<int> _sha512K = [
  0x428A2F98D728AE22,
  0x7137449123EF65CD,
  0xB5C0FBCFEC4D3B2F,
  0xE9B5DBA58189DBBC,
  0x3956C25BF348B538,
  0x59F111F1B605D019,
  0x923F82A4AF194F9B,
  0xAB1C5ED5DA6D8118,
  0xD807AA98A3030242,
  0x12835B0145706FBE,
  0x243185BE4EE4B28C,
  0x550C7DC3D5FFB4E2,
  0x72BE5D74F27B896F,
  0x80DEB1FE3B1696B1,
  0x9BDC06A725C71235,
  0xC19BF174CF692694,
  0xE49B69C19EF14AD2,
  0xEFBE4786384F25E3,
  0x0FC19DC68B8CD5B5,
  0x240CA1CC77AC9C65,
  0x2DE92C6F592B0275,
  0x4A7484AA6EA6E483,
  0x5CB0A9DCBD41FBD4,
  0x76F988DA831153B5,
  0x983E5152EE66DFAB,
  0xA831C66D2DB43210,
  0xB00327C898FB213F,
  0xBF597FC7BEEF0EE4,
  0xC6E00BF33DA88FC2,
  0xD5A79147930AA725,
  0x06CA6351E003826F,
  0x142929670A0E6E70,
  0x27B70A8546D22FFC,
  0x2E1B21385C26C926,
  0x4D2C6DFC5AC42AED,
  0x53380D139D95B3DF,
  0x650A73548BAF63DE,
  0x766A0ABB3C77B2A8,
  0x81C2C92E47EDAEE6,
  0x92722C851482353B,
  0xA2BFE8A14CF10364,
  0xA81A664BBC423001,
  0xC24B8B70D0F89791,
  0xC76C51A30654BE30,
  0xD192E819D6EF5218,
  0xD69906245565A910,
  0xF40E35855771202A,
  0x106AA07032BBD1B8,
  0x19A4C116B8D2D0C8,
  0x1E376C085141AB53,
  0x2748774CDF8EEB99,
  0x34B0BCB5E19B48A8,
  0x391C0CB3C5C95A63,
  0x4ED8AA4AE3418ACB,
  0x5B9CCA4F7763E373,
  0x682E6FF3D6B2B8A3,
  0x748F82EE5DEFB2FC,
  0x78A5636F43172F60,
  0x84C87814A1F0AB72,
  0x8CC702081A6439EC,
  0x90BEFFFA23631E28,
  0xA4506CEBDE82BDE9,
  0xBEF9A3F7B2C67915,
  0xC67178F2E372532B,
  0xCA273ECEEA26619C,
  0xD186B8C721C0C207,
  0xEADA7DD6CDE0EB1E,
  0xF57D4F7FEE6ED178,
  0x06F067AA72176FBA,
  0x0A637DC5A2C898A6,
  0x113F9804BEF90DAE,
  0x1B710B35131C471B,
  0x28DB77F523047D84,
  0x32CAAB7B40C72493,
  0x3C9EBE0A15C9BEBC,
  0x431D67C49C100D4C,
  0x4CC5D4BECB3E42B6,
  0x597F299CFC657E2A,
  0x5FCB6FAB3AD6FAEC,
  0x6C44198C4A475817,
];

int _rotr64(int x, int c) => (x >>> c) | (x << (64 - c));

Uint8List _sha512Compute(List<int> data, List<int>? key) {
  if (key != null) return _hmac(128, (d) => _sha512Compute(d, null), key, data);
  final msg = BytesBuilder(copy: true)..add(data);
  final bitLen = BigInt.from(data.length) * BigInt.from(8);
  msg.addByte(0x80);
  while (msg.length % 128 != 112) {
    msg.addByte(0);
  }
  for (var i = 15; i >= 0; i--) {
    msg.addByte(((bitLen >> (8 * i)) & BigInt.from(0xFF)).toInt());
  }
  final bytes = msg.takeBytes();
  final h = [
    0x6A09E667F3BCC908,
    0xBB67AE8584CAA73B,
    0x3C6EF372FE94F82B,
    0xA54FF53A5F1D36F1,
    0x510E527FADE682D1,
    0x9B05688C2B3E6C1F,
    0x1F83D9ABFB41BD6B,
    0x5BE0CD19137E2179,
  ];
  final w = List<int>.filled(80, 0);
  for (var off = 0; off < bytes.length; off += 128) {
    for (var i = 0; i < 16; i++) {
      var v = 0;
      for (var j = 0; j < 8; j++) {
        v = (v << 8) | bytes[off + i * 8 + j];
      }
      w[i] = v;
    }
    for (var i = 16; i < 80; i++) {
      final s0 = _rotr64(w[i - 15], 1) ^ _rotr64(w[i - 15], 8) ^ (w[i - 15] >>> 7);
      final s1 = _rotr64(w[i - 2], 19) ^ _rotr64(w[i - 2], 61) ^ (w[i - 2] >>> 6);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 80; i++) {
      final s1 = _rotr64(e, 14) ^ _rotr64(e, 18) ^ _rotr64(e, 41);
      final ch = (e & f) ^ (~e & g);
      final t1 = hh + s1 + ch + _sha512K[i] + w[i];
      final s0 = _rotr64(a, 28) ^ _rotr64(a, 34) ^ _rotr64(a, 39);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = s0 + maj;
      hh = g;
      g = f;
      f = e;
      e = d + t1;
      d = c;
      c = b;
      b = a;
      a = t1 + t2;
    }
    h[0] += a;
    h[1] += b;
    h[2] += c;
    h[3] += d;
    h[4] += e;
    h[5] += f;
    h[6] += g;
    h[7] += hh;
  }
  final out = Uint8List(64);
  for (var i = 0; i < 8; i++) {
    for (var j = 0; j < 8; j++) {
      out[i * 8 + j] = (h[i] >>> (8 * (7 - j))) & 0xFF;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// HMAC
// ---------------------------------------------------------------------------

Uint8List _hmac(int block, Uint8List Function(List<int>) hash, List<int> key, List<int> data) {
  var k = key.length > block ? hash(key) : List<int>.from(key);
  if (k.length < block) {
    k = [...k, ...List<int>.filled(block - k.length, 0)];
  }
  final inner = [for (final b in k) b ^ 0x36, ...data];
  final outer = [for (final b in k) b ^ 0x5C, ...hash(inner)];
  return hash(outer);
}

// ---------------------------------------------------------------------------
// XXH64 (exposed as xxh3)
// ---------------------------------------------------------------------------

const int _p1 = 0x9E3779B185EBCA87;
const int _p2 = 0xC2B2AE3D27D4EB4F;
const int _p3 = 0x165667B19E3779F9;
const int _p4 = 0x85EBCA77C2B2AE63;
const int _p5 = 0x27D4EB2F165667C5;

int _xxRound(int acc, int input) {
  acc += input * _p2;
  acc = (acc << 31) | (acc >>> 33);
  return acc * _p1;
}

int _xxMerge(int acc, int val) {
  val = _xxRound(0, val);
  acc ^= val;
  return acc * _p1 + _p4;
}

int _readLE64(List<int> b, int i) {
  var v = 0;
  for (var j = 7; j >= 0; j--) {
    v = (v << 8) | (b[i + j] & 0xFF);
  }
  return v;
}

int _xxh64Int(List<int> data, int seed) {
  final len = data.length;
  var off = 0;
  int h;
  if (len >= 32) {
    var v1 = seed + _p1 + _p2;
    var v2 = seed + _p2;
    var v3 = seed;
    var v4 = seed - _p1;
    final limit = len - 32;
    while (off <= limit) {
      v1 = _xxRound(v1, _readLE64(data, off));
      v2 = _xxRound(v2, _readLE64(data, off + 8));
      v3 = _xxRound(v3, _readLE64(data, off + 16));
      v4 = _xxRound(v4, _readLE64(data, off + 24));
      off += 32;
    }
    h = ((v1 << 1) | (v1 >>> 63)) + ((v2 << 7) | (v2 >>> 57)) + ((v3 << 12) | (v3 >>> 52)) + ((v4 << 18) | (v4 >>> 46));
    h = _xxMerge(h, v1);
    h = _xxMerge(h, v2);
    h = _xxMerge(h, v3);
    h = _xxMerge(h, v4);
  } else {
    h = seed + _p5;
  }
  h += len;
  while (off + 8 <= len) {
    h ^= _xxRound(0, _readLE64(data, off));
    h = ((h << 27) | (h >>> 37)) * _p1 + _p4;
    off += 8;
  }
  if (off + 4 <= len) {
    h ^= _readLE32(data, off) * _p1;
    h = ((h << 23) | (h >>> 41)) * _p2 + _p3;
    off += 4;
  }
  while (off < len) {
    h ^= (data[off] & 0xFF) * _p5;
    h = ((h << 11) | (h >>> 53)) * _p1;
    off++;
  }
  h ^= h >>> 33;
  h *= _p2;
  h ^= h >>> 29;
  h *= _p3;
  h ^= h >>> 32;
  return h;
}

Uint8List _xxh3Compute(List<int> data, List<int>? key) {
  final v = _xxh64Int(data, 0);
  final out = Uint8List(8);
  for (var i = 0; i < 8; i++) {
    out[i] = (v >>> (8 * (7 - i))) & 0xFF;
  }
  return out;
}

// ---------------------------------------------------------------------------
// BLAKE3
// ---------------------------------------------------------------------------

const List<int> _b3iv = [
  0x6A09E667,
  0xBB67AE85,
  0x3C6EF372,
  0xA54FF53A,
  0x510E527F,
  0x9B05688C,
  0x1F83D9AB,
  0x5BE0CD19,
];
const List<int> _b3perm = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8];
const int _b3ChunkStart = 1;
const int _b3ChunkEnd = 2;
const int _b3Parent = 4;
const int _b3Root = 8;
const int _b3Keyed = 16;

void _b3G(List<int> s, int a, int b, int c, int d, int x, int y) {
  s[a] = _add32(_add32(s[a], x), s[b]);
  s[d] = _rotr32(s[d] ^ s[a], 16);
  s[c] = _add32(s[c], s[d]);
  s[b] = _rotr32(s[b] ^ s[c], 12);
  s[a] = _add32(_add32(s[a], y), s[b]);
  s[d] = _rotr32(s[d] ^ s[a], 8);
  s[c] = _add32(s[c], s[d]);
  s[b] = _rotr32(s[b] ^ s[c], 7);
}

void _b3Round(List<int> s, List<int> m) {
  _b3G(s, 0, 4, 8, 12, m[0], m[1]);
  _b3G(s, 1, 5, 9, 13, m[2], m[3]);
  _b3G(s, 2, 6, 10, 14, m[4], m[5]);
  _b3G(s, 3, 7, 11, 15, m[6], m[7]);
  _b3G(s, 0, 5, 10, 15, m[8], m[9]);
  _b3G(s, 1, 6, 11, 12, m[10], m[11]);
  _b3G(s, 2, 7, 8, 13, m[12], m[13]);
  _b3G(s, 3, 4, 9, 14, m[14], m[15]);
}

List<int> _b3Compress(List<int> cv, List<int> block, int counter, int blockLen, int flags) {
  final s = List<int>.of(cv)
    ..addAll(_b3iv.sublist(0, 4))
    ..add(counter & 0xFFFFFFFF)
    ..add((counter >>> 32) & 0xFFFFFFFF)
    ..add(blockLen)
    ..add(flags);
  var m = List<int>.of(block);
  for (var r = 0; r < 7; r++) {
    _b3Round(s, m);
    if (r < 6) m = [for (final i in _b3perm) m[i]];
  }
  final out = List<int>.filled(16, 0);
  for (var i = 0; i < 8; i++) {
    out[i] = s[i] ^ s[i + 8];
  }
  return out;
}

List<int> _b3Words(List<int> bytes) {
  final w = List<int>.filled(16, 0);
  for (var i = 0; i < 16; i++) {
    w[i] = _readLE32(bytes, i * 4);
  }
  return w;
}

final class _B3Output {
  final List<int> cv;
  final List<int> block;
  final int counter;
  final int blockLen;
  final int flags;

  _B3Output(this.cv, this.block, this.counter, this.blockLen, this.flags);

  List<int> chainingValue() => _b3Compress(cv, block, counter, blockLen, flags).sublist(0, 8);

  Uint8List root(int len) {
    final out = Uint8List(len);
    var produced = 0;
    var outCounter = 0;
    while (produced < len) {
      final words = _b3Compress(cv, block, outCounter, blockLen, flags | _b3Root);
      for (final word in words) {
        for (var j = 0; j < 4 && produced < len; j++) {
          out[produced++] = (word >>> (8 * j)) & 0xFF;
        }
      }
      outCounter++;
    }
    return out;
  }
}

final class _B3Chunk {
  final List<int> key;
  final int flags;
  final int counter;
  final List<int> buf = [];
  List<int> cv;
  int blocks = 0;
  int len = 0;

  _B3Chunk(this.key, this.counter, this.flags) : cv = List<int>.of(key);

  int get _startFlag => blocks == 0 ? _b3ChunkStart : 0;

  void update(List<int> input) {
    var i = 0;
    while (i < input.length) {
      if (buf.length == 64) {
        cv = _b3Compress(cv, _b3Words(buf), counter, 64, flags | _startFlag).sublist(0, 8);
        blocks++;
        buf.clear();
      }
      final take = math.min(64 - buf.length, input.length - i);
      buf.addAll(input.sublist(i, i + take));
      len += take;
      i += take;
    }
  }

  _B3Output output() {
    final block = List<int>.filled(64, 0);
    for (var i = 0; i < buf.length; i++) {
      block[i] = buf[i];
    }
    return _B3Output(cv, _b3Words(block), counter, buf.length, flags | _startFlag | _b3ChunkEnd);
  }
}

final class _B3Hasher {
  final List<int> key;
  final int flags;
  final List<List<int>> stack = [];
  _B3Chunk chunk;

  _B3Hasher(this.key, int baseFlags) : flags = baseFlags, chunk = _B3Chunk(key, 0, baseFlags);

  void update(List<int> input) {
    var i = 0;
    while (i < input.length) {
      if (chunk.len == 1024) {
        _push(chunk.output().chainingValue(), chunk.counter + 1);
        chunk = _B3Chunk(key, chunk.counter + 1, flags);
      }
      final take = math.min(1024 - chunk.len, input.length - i);
      chunk.update(input.sublist(i, i + take));
      i += take;
    }
  }

  void _push(List<int> cv, int total) {
    var newCv = cv;
    var n = total;
    while ((n & 1) == 0) {
      newCv = _parentCv(stack.removeLast(), newCv);
      n >>= 1;
    }
    stack.add(newCv);
  }

  List<int> _parentCv(List<int> left, List<int> right) =>
      _b3Compress(key, [...left, ...right], 0, 64, flags | _b3Parent).sublist(0, 8);

  _B3Output finalize() {
    var output = chunk.output();
    final copy = List<List<int>>.of(stack);
    while (copy.isNotEmpty) {
      output = _B3Output(key, [...copy.removeLast(), ...output.chainingValue()], 0, 64, flags | _b3Parent);
    }
    return output;
  }
}

Uint8List _blake3Compute(List<int> data, List<int>? key) {
  List<int> keyWords = _b3iv;
  var flags = 0;
  if (key != null) {
    if (key.length != 32) throw ArgumentError('BLAKE3 keyed mode needs a 32-byte key');
    keyWords = _b3Words(key);
    flags = _b3Keyed;
  }
  final hasher = _B3Hasher(keyWords, flags);
  hasher.update(data);
  return hasher.finalize().root(32);
}

// ---------------------------------------------------------------------------
// Algo / Mac / Writer
// ---------------------------------------------------------------------------

/// A named hash function: call it, or use [mac] and [writer].
final class Algo {
  final String name;
  final int size;
  final int blockSize;
  final Uint8List Function(List<int> data, List<int>? key) _compute;

  const Algo._(this.name, this.size, this.blockSize, this._compute);

  /// Digest length in bytes.
  int get length => size;

  /// Hashes [data]; [key] selects the keyed/HMAC variant where supported.
  Uint8List call(Object data, {Object? key}) => _compute(_bytes(data), key == null ? null : _bytes(key));

  /// A reusable keyed MAC: `Hash.sha256.mac(secret)(message)`.
  Mac mac(Object key) => Mac(this, _bytes(key));

  /// A streaming writer: `final w = Hash.sha256.writer(); w.write(buf); w.finish().hex`.
  AlgoWriter writer() => AlgoWriter(_compute);

  @override
  String toString() => name;
}

/// A keyed message authentication code.
final class Mac {
  final Algo algo;
  final List<int> key;

  const Mac(this.algo, this.key);

  /// Authenticates [data].
  Uint8List call(Object data) => algo._compute(_bytes(data), key);

  /// Authenticates [data] (alias for [call]).
  Uint8List of(Object data) => call(data);
}

/// A streaming hash writer; call [finish] once.
final class AlgoWriter implements Hasher {
  final Uint8List Function(List<int> data, List<int>? key) _compute;
  final BytesBuilder _buf = BytesBuilder(copy: true);
  bool _done = false;

  AlgoWriter(this._compute);

  /// Adds [data]; answers the bytes accepted so it can be used as a `Writer` sink.
  int write(Object data) {
    _buf.add(_bytes(data));
    return _bytes(data).length;
  }

  @override
  void update(Object data) {
    _buf.add(_bytes(data));
  }

  /// Finishes the digest; only valid once.
  @override
  Uint8List digest() {
    if (_done) throw StateError('Digest already finished');
    _done = true;
    return _compute(_buf.takeBytes(), null);
  }

  /// Alias for [digest].
  Uint8List finish() => digest();
}

/// The catalog of hash algorithms: `Hash.sha256('hello').hex`.
abstract final class Hash {
  /// 128-bit MD5 (legacy only — not collision resistant).
  static const Algo md5 = Algo._('md5', 16, 64, _md5Compute);

  /// 256-bit SHA-2, the default for integrity checks.
  static const Algo sha256 = Algo._('sha256', 32, 64, _sha256Compute);

  /// 512-bit SHA-2.
  static const Algo sha512 = Algo._('sha512', 64, 128, _sha512Compute);

  /// 256-bit BLAKE3, fast and keyed-mode capable.
  static const Algo blake3 = Algo._('blake3', 32, 64, _blake3Compute);

  /// 32-bit CRC, for checksums and archive formats.
  static const Algo crc32 = Algo._('crc32', 4, 4, _crc32Compute);

  /// 64-bit xxHash, for fast dedup keys and fingerprints.
  static const Algo xxh3 = Algo._('xxh3', 8, 8, _xxh3Compute);
}

/// Digest bytes rendered as hex or an integer.
extension DigestValue on List<int> {
  /// Lowercase hex string.
  String get hex {
    final sb = StringBuffer();
    for (final b in this) {
      sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Big-endian integer value of the digest.
  int get intVal {
    var v = 0;
    for (final b in this) {
      v = (v << 8) | (b & 0xFF);
    }
    return v;
  }

  /// A [Uint8List] copy of the digest.
  Uint8List get rawBytes => this is Uint8List ? this as Uint8List : Uint8List.fromList(this);
}

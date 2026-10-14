/// AES (FIPS-197) and the key derivations the archive formats use, in pure
/// Dart: zip (WinZip AES: PBKDF2-HMAC-SHA1, CTR), 7z (SHA-256 rounds, CBC)
/// and RAR (PBKDF2-HMAC-SHA256 or SHA-1 rounds, CBC). Table-driven, one
/// 16-byte block at a time.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// An expanded AES key (128, 192 or 256 bits).
final class Aes {
  Aes(List<int> key) : assert(key.length == 16 || key.length == 24 || key.length == 32), _rounds = key.length ~/ 4 + 6 {
    _expand(Uint8List.fromList(key));
  }

  final int _rounds;
  late final Uint32List _ek;
  late final Uint32List _dk;

  void _expand(Uint8List key) {
    _tables;
    final nk = key.length ~/ 4;
    final total = 4 * (_rounds + 1);
    final w = Uint32List(total);
    for (var i = 0; i < nk; i++) {
      w[i] = key[4 * i] << 24 | key[4 * i + 1] << 16 | key[4 * i + 2] << 8 | key[4 * i + 3];
    }
    var rcon = 1;
    for (var i = nk; i < total; i++) {
      var t = w[i - 1];
      if (i % nk == 0) {
        t = _subWord(t << 8 | t >> 24) ^ rcon << 24;
        rcon = _xtime(rcon);
      } else if (nk > 6 && i % nk == 4) {
        t = _subWord(t);
      }
      w[i] = (w[i - nk] ^ t) & 0xFFFFFFFF;
    }
    _ek = w;
    // The equivalent inverse cipher: round keys reversed, the inner ones
    // passed through InvMixColumns.
    final d = Uint32List(total);
    for (var r = 0; r <= _rounds; r++) {
      for (var c = 0; c < 4; c++) {
        final k = w[(_rounds - r) * 4 + c];
        d[r * 4 + c] = r == 0 || r == _rounds
            ? k
            : _td0[_sbox[k >> 24]] ^ _td1[_sbox[k >> 16 & 0xFF]] ^ _td2[_sbox[k >> 8 & 0xFF]] ^ _td3[_sbox[k & 0xFF]];
      }
    }
    _dk = d;
  }

  /// Encrypt the 16 bytes at [inOff] of [input] into [out] at [outOff].
  void encryptBlock(Uint8List input, int inOff, Uint8List out, int outOff) {
    final k = _ek;
    var s0 = _word(input, inOff) ^ k[0];
    var s1 = _word(input, inOff + 4) ^ k[1];
    var s2 = _word(input, inOff + 8) ^ k[2];
    var s3 = _word(input, inOff + 12) ^ k[3];
    var i = 4;
    for (var r = 1; r < _rounds; r++) {
      final t0 = _te0[s0 >> 24] ^ _te1[s1 >> 16 & 0xFF] ^ _te2[s2 >> 8 & 0xFF] ^ _te3[s3 & 0xFF] ^ k[i];
      final t1 = _te0[s1 >> 24] ^ _te1[s2 >> 16 & 0xFF] ^ _te2[s3 >> 8 & 0xFF] ^ _te3[s0 & 0xFF] ^ k[i + 1];
      final t2 = _te0[s2 >> 24] ^ _te1[s3 >> 16 & 0xFF] ^ _te2[s0 >> 8 & 0xFF] ^ _te3[s1 & 0xFF] ^ k[i + 2];
      final t3 = _te0[s3 >> 24] ^ _te1[s0 >> 16 & 0xFF] ^ _te2[s1 >> 8 & 0xFF] ^ _te3[s2 & 0xFF] ^ k[i + 3];
      s0 = t0;
      s1 = t1;
      s2 = t2;
      s3 = t3;
      i += 4;
    }
    final sb = _sbox;
    _put(
      out,
      outOff,
      (sb[s0 >> 24] << 24 | sb[s1 >> 16 & 0xFF] << 16 | sb[s2 >> 8 & 0xFF] << 8 | sb[s3 & 0xFF]) ^ k[i],
    );
    _put(
      out,
      outOff + 4,
      (sb[s1 >> 24] << 24 | sb[s2 >> 16 & 0xFF] << 16 | sb[s3 >> 8 & 0xFF] << 8 | sb[s0 & 0xFF]) ^ k[i + 1],
    );
    _put(
      out,
      outOff + 8,
      (sb[s2 >> 24] << 24 | sb[s3 >> 16 & 0xFF] << 16 | sb[s0 >> 8 & 0xFF] << 8 | sb[s1 & 0xFF]) ^ k[i + 2],
    );
    _put(
      out,
      outOff + 12,
      (sb[s3 >> 24] << 24 | sb[s0 >> 16 & 0xFF] << 16 | sb[s1 >> 8 & 0xFF] << 8 | sb[s2 & 0xFF]) ^ k[i + 3],
    );
  }

  /// Decrypt the 16 bytes at [inOff] of [input] into [out] at [outOff].
  void decryptBlock(Uint8List input, int inOff, Uint8List out, int outOff) {
    final k = _dk;
    var s0 = _word(input, inOff) ^ k[0];
    var s1 = _word(input, inOff + 4) ^ k[1];
    var s2 = _word(input, inOff + 8) ^ k[2];
    var s3 = _word(input, inOff + 12) ^ k[3];
    var i = 4;
    for (var r = 1; r < _rounds; r++) {
      final t0 = _td0[s0 >> 24] ^ _td1[s3 >> 16 & 0xFF] ^ _td2[s2 >> 8 & 0xFF] ^ _td3[s1 & 0xFF] ^ k[i];
      final t1 = _td0[s1 >> 24] ^ _td1[s0 >> 16 & 0xFF] ^ _td2[s3 >> 8 & 0xFF] ^ _td3[s2 & 0xFF] ^ k[i + 1];
      final t2 = _td0[s2 >> 24] ^ _td1[s1 >> 16 & 0xFF] ^ _td2[s0 >> 8 & 0xFF] ^ _td3[s3 & 0xFF] ^ k[i + 2];
      final t3 = _td0[s3 >> 24] ^ _td1[s2 >> 16 & 0xFF] ^ _td2[s1 >> 8 & 0xFF] ^ _td3[s0 & 0xFF] ^ k[i + 3];
      s0 = t0;
      s1 = t1;
      s2 = t2;
      s3 = t3;
      i += 4;
    }
    final ib = _inv;
    _put(
      out,
      outOff,
      (ib[s0 >> 24] << 24 | ib[s3 >> 16 & 0xFF] << 16 | ib[s2 >> 8 & 0xFF] << 8 | ib[s1 & 0xFF]) ^ k[i],
    );
    _put(
      out,
      outOff + 4,
      (ib[s1 >> 24] << 24 | ib[s0 >> 16 & 0xFF] << 16 | ib[s3 >> 8 & 0xFF] << 8 | ib[s2 & 0xFF]) ^ k[i + 1],
    );
    _put(
      out,
      outOff + 8,
      (ib[s2 >> 24] << 24 | ib[s1 >> 16 & 0xFF] << 16 | ib[s0 >> 8 & 0xFF] << 8 | ib[s3 & 0xFF]) ^ k[i + 2],
    );
    _put(
      out,
      outOff + 12,
      (ib[s3 >> 24] << 24 | ib[s2 >> 16 & 0xFF] << 16 | ib[s1 >> 8 & 0xFF] << 8 | ib[s0 & 0xFF]) ^ k[i + 3],
    );
  }

  /// CBC decryption of [data] (a multiple of 16 bytes) with [iv].
  Uint8List cbcDecrypt(Uint8List data, List<int> iv) {
    if (data.length % 16 != 0) throw const FormatException('corrupt archive: encrypted data is not whole AES blocks');
    final out = Uint8List(data.length);
    final prev = Uint8List.fromList(iv);
    for (var o = 0; o < data.length; o += 16) {
      decryptBlock(data, o, out, o);
      for (var j = 0; j < 16; j++) {
        out[o + j] ^= prev[j];
        prev[j] = data[o + j];
      }
    }
    return out;
  }

  /// CBC encryption of [data] (a multiple of 16 bytes) with [iv].
  Uint8List cbcEncrypt(Uint8List data, List<int> iv) {
    final out = Uint8List(data.length);
    final block = Uint8List.fromList(iv);
    for (var o = 0; o < data.length; o += 16) {
      for (var j = 0; j < 16; j++) {
        block[j] ^= data[o + j];
      }
      encryptBlock(block, 0, out, o);
      block.setRange(0, 16, out, o);
    }
    return out;
  }

  /// WinZip AES CTR: a little-endian counter from 1, XORed over [data].
  /// The same call encrypts and decrypts.
  Uint8List ctrLittleEndian(Uint8List data) {
    final out = Uint8List(data.length);
    final counter = Uint8List(16);
    final pad = Uint8List(16);
    var n = 0;
    for (var o = 0; o < data.length; o += 16) {
      n++;
      var v = n;
      for (var j = 0; j < 8; j++) {
        counter[j] = v & 0xFF;
        v >>= 8;
      }
      encryptBlock(counter, 0, pad, 0);
      final end = o + 16 < data.length ? o + 16 : data.length;
      for (var j = o; j < end; j++) {
        out[j] = data[j] ^ pad[j - o];
      }
    }
    return out;
  }
}

/// PBKDF2 (RFC 8018) with HMAC over [hash]: [length] bytes.
Uint8List pbkdf2(crypto.Hash hash, List<int> password, List<int> salt, int iterations, int length) {
  final hmac = crypto.Hmac(hash, password);
  final out = BytesBuilder(copy: false);
  for (var block = 1; out.length < length; block++) {
    var u = hmac.convert([...salt, block >> 24 & 0xFF, block >> 16 & 0xFF, block >> 8 & 0xFF, block & 0xFF]).bytes;
    final t = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.add(t);
  }
  return Uint8List.sublistView(out.takeBytes(), 0, length);
}

int _word(Uint8List b, int o) => b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];

void _put(Uint8List b, int o, int v) {
  b[o] = v >> 24 & 0xFF;
  b[o + 1] = v >> 16 & 0xFF;
  b[o + 2] = v >> 8 & 0xFF;
  b[o + 3] = v & 0xFF;
}

int _xtime(int b) => (b << 1 ^ (b & 0x80 != 0 ? 0x1B : 0)) & 0xFF;

int _mul(int a, int b) {
  var r = 0;
  while (b != 0) {
    if (b & 1 != 0) r ^= a;
    a = _xtime(a);
    b >>= 1;
  }
  return r;
}

int _subWord(int w) =>
    _sbox[w >> 24 & 0xFF] << 24 | _sbox[w >> 16 & 0xFF] << 16 | _sbox[w >> 8 & 0xFF] << 8 | _sbox[w & 0xFF];

final _sbox = Uint8List(256);
final _inv = Uint8List(256);
final _te0 = Uint32List(256), _te1 = Uint32List(256), _te2 = Uint32List(256), _te3 = Uint32List(256);
final _td0 = Uint32List(256), _td1 = Uint32List(256), _td2 = Uint32List(256), _td3 = Uint32List(256);

/// Builds the S-boxes and round tables once, from the field arithmetic
/// (no 8 KB of literals).
final bool _tables = () {
  // Multiplicative inverses through the generator 3.
  final exp = Uint8List(256), log = Uint8List(256);
  var x = 1;
  for (var i = 0; i < 255; i++) {
    exp[i] = x;
    log[x] = i;
    x ^= _xtime(x);
  }
  for (var i = 0; i < 256; i++) {
    final inverse = i == 0 ? 0 : exp[(255 - log[i]) % 255];
    var s = inverse, b = inverse;
    for (var k = 0; k < 4; k++) {
      b = (b << 1 | b >> 7) & 0xFF;
      s ^= b;
    }
    s ^= 0x63;
    _sbox[i] = s;
    _inv[s] = i;
  }
  for (var i = 0; i < 256; i++) {
    final s = _sbox[i];
    final e = _mul(s, 2) << 24 | s << 16 | s << 8 | _mul(s, 3);
    _te0[i] = e;
    _te1[i] = (e >> 8 | e << 24) & 0xFFFFFFFF;
    _te2[i] = (e >> 16 | e << 16) & 0xFFFFFFFF;
    _te3[i] = (e >> 24 | e << 8) & 0xFFFFFFFF;
    final v = _inv[i];
    final d = _mul(v, 14) << 24 | _mul(v, 9) << 16 | _mul(v, 13) << 8 | _mul(v, 11);
    _td0[i] = d;
    _td1[i] = (d >> 8 | d << 24) & 0xFFFFFFFF;
    _td2[i] = (d >> 16 | d << 16) & 0xFFFFFFFF;
    _td3[i] = (d >> 24 | d << 8) & 0xFFFFFFFF;
  }
  return true;
}();

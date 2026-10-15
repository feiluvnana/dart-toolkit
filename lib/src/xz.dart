/// xz (the `.tar.xz` container) decoding in pure Dart for `archive`:
/// streams, blocks with the LZMA2 filter, CRC32/CRC64/SHA-256 checks, the
/// index and footer, concatenated streams and stream padding.
library;

import 'dart:convert' show ByteConversionSink;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'crc32.dart';
import 'lzma.dart';

import '../core.dart';

/// The xz magic: `\xFD7zXZ\x00`.
bool isXz(List<int> b) =>
    b.length >= 6 && b[0] == 0xFD && b[1] == 0x37 && b[2] == 0x7A && b[3] == 0x58 && b[4] == 0x5A && b[5] == 0;

Never _bad(String why) => throw ContentException('corrupt archive: xz $why');

/// The decompressed bytes of the xz data in [b].
Uint8List xzDecode(Uint8List b) {
  final out = BytesBuilder(copy: false);
  xzChunks(b).forEach(out.add);
  return out.takeBytes();
}

/// The decompressed bytes of the xz data in [b], a piece at a time: memory
/// stays at one LZMA2 dictionary, however large the output. A block's check
/// is verified at its end, after its bytes went out (an unpack discards
/// its staging on the error).
Iterable<Uint8List> xzChunks(Uint8List b) sync* {
  var i = 0;
  while (i < b.length) {
    // Stream padding: zero bytes in fours between streams.
    if (b[i] == 0) {
      i++;
      continue;
    }
    if (!isXz(Uint8List.sublistView(b, i))) _bad('stream header');
    if (i + 12 > b.length) _bad('stream header');
    final check = b[i + 7] & 0x0F;
    if (crc32(b, start: i + 6, end: i + 8) != _u32(b, i + 8)) _bad('stream header CRC');
    i += 12;
    final checkSize = switch (check) {
      0 => 0,
      1 => 4,
      4 => 8,
      10 => 32,
      _ => _bad('unknown check $check'),
    };
    // Blocks until the index (its first byte is 0).
    while (true) {
      if (i >= b.length) _bad('stream ends early');
      if (b[i] == 0) break;
      final blockStart = i;
      final headerSize = (b[i] + 1) * 4;
      if (i + headerSize > b.length) _bad('block header past the end');
      if (crc32(b, start: i, end: i + headerSize - 4) != _u32(b, i + headerSize - 4)) _bad('block header CRC');
      final flags = b[i + 1];
      var p = i + 2;
      int vli() {
        var v = 0;
        for (var shift = 0; shift < 63; shift += 7) {
          if (p >= i + headerSize) _bad('block header');
          final c = b[p++];
          v |= (c & 0x7F) << shift;
          if (c & 0x80 == 0) return v;
        }
        _bad('number too long');
      }

      if (flags & 0x40 != 0) vli(); // compressed size
      if (flags & 0x80 != 0) vli(); // uncompressed size
      final filters = (flags & 3) + 1;
      var dict = 1 << 32;
      for (var f = 0; f < filters; f++) {
        final id = vli();
        final propsSize = vli();
        if (f < filters - 1 || id != 0x21) {
          throw ContentException('unsupported xz filter 0x${id.toRadixString(16)} (only LZMA2)');
        }
        if (propsSize == 1 && p < i + headerSize) {
          final d = b[p] & 0x3F; // LZMA2's dictionary size byte
          dict = d >= 40 ? 0xFFFFFFFF : (2 | (d & 1)) << (d ~/ 2 + 11);
        }
        p += propsSize;
      }
      i += headerSize;
      final (size, end) = lzma2Extent(b, i);
      final sum = _Check(check);
      for (final piece in lzma2Chunks(Uint8List.sublistView(b, i, end), size, window: dict)) {
        sum.add(piece);
        yield piece;
      }
      i = end;
      while ((i - blockStart) % 4 != 0) {
        if (i >= b.length || b[i] != 0) _bad('block padding');
        i++;
      }
      if (i + checkSize > b.length) _bad('block check past the end');
      sum.verify(Uint8List.sublistView(b, i, i + checkSize));
      i += checkSize;
    }
    // The index: records, padding, CRC32; then the 12-byte footer.
    final indexStart = i;
    i++;
    var p = i;
    int vli() {
      var v = 0;
      for (var shift = 0; shift < 63; shift += 7) {
        if (p >= b.length) _bad('index');
        final c = b[p++];
        v |= (c & 0x7F) << shift;
        if (c & 0x80 == 0) return v;
      }
      _bad('number too long');
    }

    final records = vli();
    for (var r = 0; r < records; r++) {
      vli();
      vli();
    }
    while ((p - indexStart) % 4 != 0) {
      p++;
    }
    if (p + 4 > b.length || crc32(b, start: indexStart, end: p) != _u32(b, p)) _bad('index CRC');
    i = p + 4 + 12; // the footer
    if (i > b.length || b[i - 2] != 0x59 || b[i - 1] != 0x5A) _bad('stream footer');
  }
}

/// A block's check, computed as its bytes go by.
final class _Check {
  _Check(this._kind) {
    if (_kind == 10) _sha = crypto.sha256.startChunkedConversion(_digest);
  }

  final int _kind;
  var _crc = 0;
  final _digest = _DigestSink();
  ByteConversionSink? _sha;

  void add(Uint8List data) {
    switch (_kind) {
      case 1:
        _crc = crc32(data, crc: _crc);
      case 4:
        _crc = _crc64(data, _crc);
      case 10:
        _sha!.add(data);
    }
  }

  void verify(Uint8List stored) {
    switch (_kind) {
      case 1:
        if (_crc != _u32(stored, 0)) _bad('CRC32 of a block');
      case 4:
        for (var k = 0; k < 8; k++) {
          if ((_crc >> (8 * k)) & 0xFF != stored[k]) _bad('CRC64 of a block');
        }
      case 10:
        _sha!.close();
        final d = _digest.value!.bytes;
        for (var k = 0; k < 32; k++) {
          if (d[k] != stored[k]) _bad('SHA-256 of a block');
        }
    }
  }
}

final class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

int _u32(Uint8List b, int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;

/// CRC-64/XZ (ECMA-182, reflected), the xz default check.
int _crc64(Uint8List data, [int crc = 0]) {
  var c = ~crc; // all ones to start
  for (final v in data) {
    c = _crc64Table[(c ^ v) & 0xFF] ^ (c >>> 8);
  }
  return ~c;
}

final _crc64Table = () {
  const poly = 0xC96C5795D7870F42;
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? poly ^ (c >>> 1) : c >>> 1;
    }
    t[n] = c;
  }
  return t;
}();

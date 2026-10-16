/// xz (the `.tar.xz` container) decoding in pure Dart for `archive`,
/// streamed: blocks with the LZMA2 filter, CRC32/CRC64/SHA-256 checks, the
/// index and footer, concatenated streams and stream padding.
library;

import 'dart:async';
import 'dart:convert' show ByteConversionSink;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'bcj.dart';
import 'crc32.dart';
import 'lzma.dart';

import '../core.dart';

/// The xz magic: `\xFD7zXZ\x00`.
bool isXz(List<int> b) =>
    b.length >= 6 && b[0] == 0xFD && b[1] == 0x37 && b[2] == 0x7A && b[3] == 0x58 && b[4] == 0x5A && b[5] == 0;

Never _bad(String why) => throw ContentException('corrupt archive: xz $why');

/// The decompressed bytes of the xz data in [input], streamed as it
/// arrives: memory stays at about 1.25 LZMA2 dictionaries, however large the
/// output. A block's check is verified at its end, after its bytes went out
/// (an unpack discards its staging on the error); the index and footer are
/// checked against the blocks.
Stream<Uint8List> xzStream(Stream<List<int>> input) async* {
  final r = _Input(input);
  try {
    var streams = 0;
    while (true) {
      // Stream padding: zero bytes in fours between and after streams.
      if (!await r.fill(1)) {
        if (streams == 0) _bad('stream header');
        return;
      }
      if (r.peek() == 0) {
        if (!await r.fill(4) || r.take(4).any((b) => b != 0)) _bad('stream padding');
        continue;
      }
      if (!await r.fill(12)) _bad('stream header');
      final head = r.take(12);
      if (!isXz(head) || head[6] != 0 || head[7] & 0xF0 != 0) _bad('stream header');
      if (crc32(head, start: 6, end: 8) != _u32(head, 8)) _bad('stream header CRC');
      final check = head[7] & 0x0F;
      final checkSize = switch (check) {
        0 => 0,
        1 => 4,
        4 => 8,
        10 => 32,
        _ => _bad('unknown check $check'),
      };
      // Blocks until the index (its first byte is 0).
      final blocks = <(int, int)>[]; // unpadded size, uncompressed size
      while (true) {
        if (!await r.fill(1)) _bad('stream ends early');
        if (r.peek() == 0) break;
        final headerSize = (r.peek() + 1) * 4;
        if (!await r.fill(headerSize)) _bad('block header past the end');
        final h = r.take(headerSize);
        if (crc32(h, end: headerSize - 4) != _u32(h, headerSize - 4)) _bad('block header CRC');
        final (packedSize, unpackedSize, dict, pre) = _blockHeader(h);
        // A branch filter needs its whole block: held, then undone at once.
        final held = pre.isEmpty ? null : BytesBuilder(copy: false);
        final d = Lzma2(unpackedSize ?? 1 << 62, window: dict);
        final sum = _Check(check);
        var packed = 0;
        while (true) {
          if (!await r.fill(1)) _bad('stream ends early');
          final control = r.take(1)[0];
          packed++;
          if (control == 0) break;
          final hs = Lzma2.headerSize(control);
          if (!await r.fill(hs)) _bad('stream ends early');
          final header = r.take(hs);
          final n = Lzma2.payloadSize(control, header);
          if (!await r.fill(n)) _bad('stream ends early');
          d.chunk(control, header, r.take(n));
          packed += hs + n;
          final out = d.take();
          if (held != null) {
            held.add(out);
            continue;
          }
          sum.add(out);
          yield out;
        }
        if (held != null) {
          final out = _unfilter(held.takeBytes(), pre);
          sum.add(out);
          yield out;
        }
        if (packedSize != null && packedSize != packed || unpackedSize != null && unpackedSize != d.total) {
          _bad('block sizes');
        }
        final pad = (4 - (headerSize + packed) % 4) % 4;
        if (!await r.fill(pad + checkSize)) _bad('block check past the end');
        if (r.take(pad).any((b) => b != 0)) _bad('block padding');
        sum.verify(r.take(checkSize));
        blocks.add((headerSize + packed + checkSize, d.total));
      }
      // The index: records, padding, CRC32; then the 12-byte footer.
      final index = BytesBuilder(copy: false);
      Future<int> byte() async {
        if (!await r.fill(1)) _bad('index');
        final b = r.take(1);
        index.add(b);
        return b[0];
      }

      Future<int> vli() async {
        var v = 0;
        for (var shift = 0; shift < 63; shift += 7) {
          final c = await byte();
          v |= (c & 0x7F) << shift;
          if (c & 0x80 == 0) return v;
        }
        _bad('number too long');
      }

      await byte(); // the index indicator
      if (await vli() != blocks.length) _bad('index');
      for (final (unpadded, size) in blocks) {
        if (await vli() != unpadded || await vli() != size) _bad('index');
      }
      while (index.length % 4 != 0) {
        if (await byte() != 0) _bad('index');
      }
      final indexSize = index.length;
      if (!await r.fill(16)) _bad('index CRC');
      if (crc32(index.takeBytes()) != _u32(r.take(4), 0)) _bad('index CRC');
      final foot = r.take(12);
      if (crc32(foot, start: 4, end: 10) != _u32(foot, 0) ||
          (_u32(foot, 4) + 1) * 4 != indexSize + 4 ||
          foot[8] != head[6] ||
          foot[9] != head[7] ||
          foot[10] != 0x59 ||
          foot[11] != 0x5A) {
        _bad('stream footer');
      }
      streams++;
    }
  } finally {
    await r.cancel();
  }
}

/// A block header's compressed and uncompressed sizes (when stored) and its
/// LZMA2 dictionary size; any other filter is unsupported.
/// A block's sizes, its LZMA2 dictionary, and the filters before LZMA2 in
/// encoding order (id, props): x86 and ARM64 branch filters and delta, as
/// `xz --x86`/`--arm64`/`--delta` and 7-Zip's own release write them.
(int?, int?, int, List<(int, Uint8List)>) _blockHeader(Uint8List h) {
  final flags = h[1];
  var p = 2;
  int vli() {
    var v = 0;
    for (var shift = 0; shift < 63; shift += 7) {
      if (p >= h.length - 4) _bad('block header');
      final c = h[p++];
      v |= (c & 0x7F) << shift;
      if (c & 0x80 == 0) return v;
    }
    _bad('number too long');
  }

  final packed = flags & 0x40 != 0 ? vli() : null;
  final unpacked = flags & 0x80 != 0 ? vli() : null;
  final filters = (flags & 3) + 1;
  var dict = 1 << 32;
  final pre = <(int, Uint8List)>[];
  for (var f = 0; f < filters; f++) {
    final id = vli();
    final propsSize = vli();
    if (f < filters - 1) {
      // A start offset other than 0 (BCJ props) is never written by xz.
      final ok = switch (id) {
        0x04 || 0x0A => propsSize == 0 || propsSize == 4 && h[p] | h[p + 1] | h[p + 2] | h[p + 3] == 0,
        0x03 => propsSize == 1,
        _ => false,
      };
      if (!ok || p + propsSize > h.length - 4) {
        throw ContentException('unsupported xz filter 0x${id.toRadixString(16)} (LZMA2 with x86, ARM64 or delta)');
      }
      pre.add((id, Uint8List.sublistView(h, p, p + propsSize)));
      p += propsSize;
      continue;
    }
    if (id != 0x21) throw ContentException('unsupported xz filter 0x${id.toRadixString(16)} (LZMA2 last)');
    if (propsSize != 1 || p >= h.length - 4) _bad('LZMA2 properties');
    final d = h[p] & 0x3F; // LZMA2's dictionary size byte
    if (d > 40) _bad('LZMA2 dictionary size');
    dict = d == 40 ? 0xFFFFFFFF : (2 | (d & 1)) << (d ~/ 2 + 11);
    p += propsSize;
  }
  return (packed, unpacked, dict, pre);
}

/// Undo [pre] (encoding order) on a whole block.
Uint8List _unfilter(Uint8List b, List<(int, Uint8List)> pre) {
  for (final (id, props) in pre.reversed) {
    b = switch (id) {
      0x04 => bcjX86(b),
      0x0A => bcjArm64(b),
      _ => delta(b, props[0] + 1),
    };
  }
  return b;
}

/// Input read exactly: [fill] buffers at least n bytes (false at the end
/// with fewer), [take] hands them out as views.
final class _Input {
  _Input(Stream<List<int>> s) : _it = StreamIterator(s);

  final StreamIterator<List<int>> _it;
  var _buf = Uint8List(0);
  var _at = 0;

  Future<bool> fill(int n) async {
    while (_buf.length - _at < n) {
      if (!await _it.moveNext()) return false;
      final c = _it.current;
      final rest = _buf.length - _at;
      if (rest == 0) {
        _buf = c is Uint8List ? c : Uint8List.fromList(c);
      } else {
        _buf = Uint8List(rest + c.length)
          ..setRange(0, rest, _buf, _at)
          ..setRange(rest, rest + c.length, c);
      }
      _at = 0;
    }
    return true;
  }

  int peek() => _buf[_at];

  Uint8List take(int n) => Uint8List.sublistView(_buf, _at, _at += n);

  Future<void> cancel() => _it.cancel();
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

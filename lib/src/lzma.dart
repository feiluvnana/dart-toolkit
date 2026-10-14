/// LZMA and LZMA2 decoding (the 7z coders), in pure Dart. The output buffer
/// is the dictionary: 7z always knows the unpacked size, so a member
/// decodes straight into its final bytes with no window copies.
library;

import 'dart:typed_data';

Never _bad(String why) => throw FormatException('corrupt archive: LZMA $why');

/// Decode an LZMA stream with 7z's 5 property bytes into [size] bytes.
Uint8List lzmaDecode(Uint8List input, List<int> props, int size) {
  if (props.length < 5) _bad('properties too short');
  final out = Uint8List(size);
  final d = _Lzma(out)..setProps(props[0]);
  final rc = _Range(input, 0);
  d.decode(rc, size);
  return out;
}

/// Decode an LZMA2 stream (7z's 1 property byte) into [size] bytes.
Uint8List lzma2Decode(Uint8List input, int size) {
  final out = Uint8List(size);
  final d = _Lzma(out);
  var i = 0;
  var needProps = true;
  while (true) {
    if (i >= input.length) _bad('LZMA2 stream ends without its end marker');
    final control = input[i++];
    if (control == 0) break;
    if (control == 1 || control == 2) {
      // An uncompressed chunk (1 also resets the dictionary).
      if (i + 2 > input.length) _bad('truncated LZMA2 chunk');
      final n = (input[i] << 8 | input[i + 1]) + 1;
      i += 2;
      if (i + n > input.length || d.pos + n > size) _bad('LZMA2 chunk runs past the end');
      out.setRange(d.pos, d.pos + n, input, i);
      d.pos += n;
      i += n;
      continue;
    }
    if (control < 0x80) _bad('bad LZMA2 control byte $control');
    if (i + 4 > input.length) _bad('truncated LZMA2 chunk');
    final unpacked = ((control & 0x1F) << 16 | input[i] << 8 | input[i + 1]) + 1;
    final packed = (input[i + 2] << 8 | input[i + 3]) + 1;
    i += 4;
    final mode = control >> 5 & 3;
    if (mode >= 2) {
      d.setProps(input[i++]);
      needProps = false;
    } else if (needProps) {
      _bad('LZMA2 chunk before its properties');
    }
    if (mode >= 1) d.resetState();
    if (i + packed > input.length || d.pos + unpacked > size) _bad('LZMA2 chunk runs past the end');
    final rc = _Range(input, i);
    d.decode(rc, d.pos + unpacked);
    i += packed;
  }
  if (d.pos != size) _bad('LZMA2 data ends at ${d.pos} of $size bytes');
  return out;
}

/// The range decoder: 32-bit range and code over [_buf] from [_i].
final class _Range {
  _Range(this._buf, int at) : _i = at + 5 {
    if (at + 5 > _buf.length || _buf[at] != 0) _bad('bad range coder start');
    for (var k = 1; k < 5; k++) {
      _code = (_code << 8 | _buf[at + k]) & 0xFFFFFFFF;
    }
  }

  final Uint8List _buf;
  int _i;
  int _range = 0xFFFFFFFF;
  int _code = 0;

  int _next() => _i < _buf.length ? _buf[_i++] : 0;

  int bit(Uint16List probs, int index) {
    final p = probs[index];
    final bound = (_range >> 11) * p;
    int result;
    if (_code < bound) {
      _range = bound;
      probs[index] = p + ((2048 - p) >> 5);
      result = 0;
    } else {
      _range -= bound;
      _code -= bound;
      probs[index] = p - (p >> 5);
      result = 1;
    }
    if (_range < 0x1000000) {
      _range = (_range << 8) & 0xFFFFFFFF;
      _code = (_code << 8 | _next()) & 0xFFFFFFFF;
    }
    return result;
  }

  int direct(int count) {
    var result = 0;
    for (var k = 0; k < count; k++) {
      _range >>= 1;
      var t = 0;
      if (_code >= _range) {
        _code -= _range;
        t = 1;
      }
      result = result << 1 | t;
      if (_range < 0x1000000) {
        _range = (_range << 8) & 0xFFFFFFFF;
        _code = (_code << 8 | _next()) & 0xFFFFFFFF;
      }
    }
    return result;
  }

  int tree(Uint16List probs, int base, int bits) {
    var m = 1;
    for (var k = 0; k < bits; k++) {
      m = m << 1 | bit(probs, base + m);
    }
    return m - (1 << bits);
  }

  int reverse(Uint16List probs, int base, int bits) {
    var m = 1, result = 0;
    for (var k = 0; k < bits; k++) {
      final b = bit(probs, base + m);
      m = m << 1 | b;
      result |= b << k;
    }
    return result;
  }
}

/// Lengths: choice bits, then 8 low, 8 mid or 256 high symbols.
final class _Len {
  _Len() : _probs = Uint16List(2 + 16 * 8 + 16 * 8 + 256)..fillRange(0, 2 + 16 * 8 + 16 * 8 + 256, 1024);

  final Uint16List _probs;
  static const _low = 2, _mid = 2 + 16 * 8, _high = 2 + 16 * 16;

  int decode(_Range rc, int posState) {
    if (rc.bit(_probs, 0) == 0) return rc.tree(_probs, _low + posState * 8, 3);
    if (rc.bit(_probs, 1) == 0) return 8 + rc.tree(_probs, _mid + posState * 8, 3);
    return 16 + rc.tree(_probs, _high, 8);
  }

  void reset() => _probs.fillRange(0, _probs.length, 1024);
}

final class _Lzma {
  _Lzma(this._out);

  final Uint8List _out;
  int pos = 0;

  var _lc = 0, _lp = 0, _pb = 0;
  Uint16List _literal = Uint16List(0);
  final _isMatch = Uint16List(12 << 4);
  final _isRep = Uint16List(12);
  final _isRepG0 = Uint16List(12);
  final _isRepG1 = Uint16List(12);
  final _isRepG2 = Uint16List(12);
  final _isRep0Long = Uint16List(12 << 4);
  final _posSlot = Uint16List(4 << 6);
  final _posSpecial = Uint16List(115);
  final _align = Uint16List(16);
  final _len = _Len();
  final _repLen = _Len();
  var _state = 0, _rep0 = 0, _rep1 = 0, _rep2 = 0, _rep3 = 0;

  void setProps(int b) {
    if (b >= 9 * 5 * 5) _bad('bad properties byte $b');
    _lc = b % 9;
    _lp = b ~/ 9 % 5;
    _pb = b ~/ 45;
    _literal = Uint16List(0x300 << (_lc + _lp));
    resetState();
  }

  void resetState() {
    for (final probs in [_literal, _isMatch, _isRep, _isRepG0, _isRepG1, _isRepG2, _isRep0Long, _posSlot, _posSpecial, _align]) {
      probs.fillRange(0, probs.length, 1024);
    }
    _len.reset();
    _repLen.reset();
    _state = _rep0 = _rep1 = _rep2 = _rep3 = 0;
  }

  /// Decode until [end] bytes of output (or an end marker).
  void decode(_Range rc, int end) {
    final out = _out;
    final pbMask = (1 << _pb) - 1;
    final lpMask = (1 << _lp) - 1;
    while (pos < end) {
      final posState = pos & pbMask;
      if (rc.bit(_isMatch, (_state << 4) + posState) == 0) {
        // A literal, after a match coded against the byte at rep0.
        final prev = pos > 0 ? out[pos - 1] : 0;
        final base = 0x300 * (((pos & lpMask) << _lc) + (prev >> (8 - _lc)));
        var symbol = 1;
        if (_state >= 7) {
          if (pos - _rep0 - 1 < 0) _bad('match before the start');
          var matchByte = out[pos - _rep0 - 1];
          while (symbol < 0x100) {
            final matchBit = matchByte >> 7 & 1;
            matchByte <<= 1;
            final b = rc.bit(_literal, base + ((1 + matchBit) << 8) + symbol);
            symbol = symbol << 1 | b;
            if (matchBit != b) break;
          }
        }
        while (symbol < 0x100) {
          symbol = symbol << 1 | rc.bit(_literal, base + symbol);
        }
        out[pos++] = symbol & 0xFF;
        _state = _state < 4 ? 0 : (_state < 10 ? _state - 3 : _state - 6);
        continue;
      }
      int len;
      if (rc.bit(_isRep, _state) != 0) {
        if (pos == 0) _bad('repeat at the start');
        if (rc.bit(_isRepG0, _state) == 0) {
          if (rc.bit(_isRep0Long, (_state << 4) + posState) == 0) {
            // A short rep: one byte at rep0.
            _state = _state < 7 ? 9 : 11;
            out[pos] = out[pos - _rep0 - 1];
            pos++;
            continue;
          }
        } else {
          int dist;
          if (rc.bit(_isRepG1, _state) == 0) {
            dist = _rep1;
          } else {
            if (rc.bit(_isRepG2, _state) == 0) {
              dist = _rep2;
            } else {
              dist = _rep3;
              _rep3 = _rep2;
            }
            _rep2 = _rep1;
          }
          _rep1 = _rep0;
          _rep0 = dist;
        }
        len = _repLen.decode(rc, posState);
        _state = _state < 7 ? 8 : 11;
      } else {
        _rep3 = _rep2;
        _rep2 = _rep1;
        _rep1 = _rep0;
        len = _len.decode(rc, posState);
        _state = _state < 7 ? 7 : 10;
        _rep0 = _distance(rc, len);
        if (_rep0 == 0xFFFFFFFF) return; // end marker
      }
      len += 2;
      final from = pos - _rep0 - 1;
      if (from < 0) _bad('match before the start');
      if (pos + len > end) len = end - pos;
      if (_rep0 >= len) {
        out.setRange(pos, pos + len, out, from);
        pos += len;
      } else {
        for (var k = 0; k < len; k++) {
          out[pos] = out[pos - _rep0 - 1];
          pos++;
        }
      }
    }
  }

  int _distance(_Range rc, int len) {
    final lenState = len < 3 ? len : 3;
    final slot = rc.tree(_posSlot, lenState << 6, 6);
    if (slot < 4) return slot;
    final bits = (slot >> 1) - 1;
    var dist = (2 | slot & 1) << bits;
    if (slot < 14) {
      dist += rc.reverse(_posSpecial, dist - slot, bits);
    } else {
      dist += rc.direct(bits - 4) << 4;
      dist += rc.reverse(_align, 0, 4);
    }
    return dist & 0xFFFFFFFF;
  }
}

/// The unpacked size of the LZMA2 stream starting at [start] of [input],
/// read off its chunk headers, and where the stream ends (after its end
/// marker): xz blocks often store no sizes.
(int, int) lzma2Extent(Uint8List input, int start) {
  var i = start, size = 0;
  while (true) {
    if (i >= input.length) _bad('LZMA2 stream ends without its end marker');
    final control = input[i++];
    if (control == 0) return (size, i);
    if (i + 2 > input.length) _bad('truncated LZMA2 chunk');
    if (control == 1 || control == 2) {
      final n = (input[i] << 8 | input[i + 1]) + 1;
      size += n;
      i += 2 + n;
      continue;
    }
    if (control < 0x80) _bad('bad LZMA2 control byte $control');
    if (i + 4 > input.length) _bad('truncated LZMA2 chunk');
    size += ((control & 0x1F) << 16 | input[i] << 8 | input[i + 1]) + 1;
    final packed = (input[i + 2] << 8 | input[i + 3]) + 1;
    i += 4 + (control >> 5 & 3 >= 2 ? 1 : 0) + packed;
  }
}

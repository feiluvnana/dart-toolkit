/// LZMA and LZMA2 decoding (the 7z and xz coders), in pure Dart. For 7z the
/// output buffer is the dictionary: 7z always knows the unpacked size, so a
/// folder decodes straight into its final bytes. xz streams through [Lzma2]
/// with a sliding window instead.
library;

import 'dart:typed_data';

import '../core.dart';

Never _bad(String why) => throw ContentException('corrupt archive: LZMA $why');

/// The most a declared size gets up front; past it the buffer grows only
/// as the stream really decodes (a header can claim anything).
const declaredCeiling = 1 << 30;

/// Decode an LZMA stream with 7z's 5 property bytes into [size] bytes.
Uint8List lzmaDecode(Uint8List input, List<int> props, int size) {
  if (props.length < 5) _bad('properties too short');
  final d = _Lzma(size)..setProps(props[0]);
  final rc = _Range(input, 0);
  d.decode(rc, size);
  return d.bytes();
}

/// Decode an LZMA2 stream (7z's 1 property byte) into [size] bytes.
Uint8List lzma2Decode(Uint8List input, int size) {
  final d = Lzma2(size);
  var i = 0;
  while (true) {
    if (i >= input.length) _bad('LZMA2 stream ends without its end marker');
    final control = input[i++];
    if (control == 0) break;
    final hs = Lzma2.headerSize(control);
    if (i + hs > input.length) _bad('truncated LZMA2 chunk');
    final header = Uint8List.sublistView(input, i, i + hs);
    final n = Lzma2.payloadSize(control, header);
    i += hs;
    if (i + n > input.length) _bad('LZMA2 chunk runs past the end');
    d.chunk(control, header, Uint8List.sublistView(input, i, i + n));
    i += n;
  }
  if (d.total != size) _bad('LZMA2 data ends at ${d.total} of $size bytes');
  return d._d.bytes();
}

/// An LZMA2 decoder fed one chunk at a time (its control byte, header and
/// payload), so a stream decodes as it arrives. With a [window] (the
/// dictionary size) only the last [window] bytes stay for back-references:
/// memory is about 1.25 dictionaries however long the stream, and
/// [take] hands out each chunk's new bytes. Without one the output is kept
/// whole ([lzma2Decode]). [size] bounds the output.
final class Lzma2 {
  Lzma2(int size, {int? window})
    : _window = window,
      _d = _Lzma(size, cap: window == null ? null : window + (window >> 2 > _slack ? window >> 2 : _slack));

  final int? _window;
  final _Lzma _d;
  var _needProps = true;
  var _shifted = 0; // bytes slid off the front
  var _taken = 0; // where the bytes not yet taken start in the buffer

  /// Bytes decoded so far.
  int get total => _shifted + _d.pos;

  /// Header bytes after [control]: 2 for a stored chunk, 4 (5 with new
  /// properties) for an LZMA one.
  static int headerSize(int control) {
    if (control == 1 || control == 2) return 2;
    if (control < 0x80) _bad('bad LZMA2 control byte $control');
    return control >= 0xC0 ? 5 : 4;
  }

  /// Payload bytes after the [header] of a [control] chunk.
  static int payloadSize(int control, Uint8List header) =>
      control < 3 ? (header[0] << 8 | header[1]) + 1 : (header[2] << 8 | header[3]) + 1;

  /// Decode one chunk.
  void chunk(int control, Uint8List header, Uint8List payload) {
    final d = _d;
    final unpacked = control < 3 ? payload.length : ((control & 0x1F) << 16 | header[0] << 8 | header[1]) + 1;
    if (total + unpacked > d._size) _bad('LZMA2 chunk runs past the end');
    final window = _window;
    if (window != null && d.pos + unpacked > d._cap) {
      // Slide: keep the last [window] bytes, moved by a multiple of 16 so the
      // position bits (pb, lp <= 4) the coder reads off `pos` stay the same.
      // The room past the window is a quarter of it (8 MiB at least): each
      // window of output copies it about four times, at 1.25x the memory.
      final delta = (d.pos - window) & ~15;
      d._out.setRange(0, d.pos - delta, d._out, delta);
      d.pos -= delta;
      _shifted += delta;
      _taken -= delta;
    }
    if (control < 3) {
      // A stored chunk (1 also resets the dictionary).
      d.reserve(d.pos + unpacked).setRange(d.pos, d.pos + unpacked, payload);
      d.pos += unpacked;
      return;
    }
    final mode = control >> 5 & 3;
    if (mode >= 2) {
      d.setProps(header[4]);
      _needProps = false;
    } else if (_needProps) {
      _bad('LZMA2 chunk before its properties');
    }
    if (mode >= 1) d.resetState();
    final end = d.pos + unpacked;
    d.decode(_Range(payload, 0), end);
    if (d.pos != end) _bad('LZMA2 chunk ends early');
  }

  /// The bytes decoded since the last [take], copied out.
  Uint8List take() {
    final out = Uint8List.fromList(Uint8List.sublistView(_d._out, _taken, _d.pos));
    _taken = _d.pos;
    return out;
  }
}

/// Room past the window: four LZMA2 chunks (2 MiB unpacked at most each)
/// for a small dictionary; a big one gets a quarter of its size.
const _slack = 8 << 20;

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

  int _next() => _i < _buf.length ? _buf[_i++] : _pastEnd();

  /// Zeros for the coder's few bytes of lookahead; past those the stream
  /// is cut short (else a claimed size would decode garbage to its end).
  int _pastEnd() {
    if (++_i > _buf.length + 8) _bad('data ends early');
    return 0;
  }

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
  /// [_size] bounds the output; [cap] the buffer, which starts small and
  /// doubles up to it (default: the whole output, allocated up front to
  /// [declaredCeiling]).
  _Lzma(this._size, {int? cap})
    : _cap = cap == null || cap > _size ? _size : cap,
      _out = Uint8List(
        (cap == null ? _size : (cap < 1 << 22 ? cap : 1 << 22)).clamp(0, _size.clamp(0, declaredCeiling)),
      ) {
    if (_size < 0) _bad('size $_size');
  }

  final int _size;
  final int _cap;
  Uint8List _out;
  int pos = 0;

  /// The buffer, grown (doubling, never past the declared size) to hold
  /// [need] bytes.
  Uint8List reserve(int need) {
    if (need <= _out.length) return _out;
    if (need > _cap) _bad('data runs past its size');
    var n = _out.length < 4096 ? 4096 : _out.length * 2;
    while (n < need) {
      n *= 2;
    }
    return _out = Uint8List(n < _cap ? n : _cap)..setRange(0, pos, _out);
  }

  /// The decoded bytes.
  Uint8List bytes() => pos == _out.length ? _out : Uint8List.sublistView(_out, 0, pos);

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
    for (final probs in [
      _literal,
      _isMatch,
      _isRep,
      _isRepG0,
      _isRepG1,
      _isRepG2,
      _isRep0Long,
      _posSlot,
      _posSpecial,
      _align,
    ]) {
      probs.fillRange(0, probs.length, 1024);
    }
    _len.reset();
    _repLen.reset();
    _state = _rep0 = _rep1 = _rep2 = _rep3 = 0;
  }

  /// Decode until [end] bytes of output (or an end marker).
  void decode(_Range rc, int end) {
    var out = _out;
    final pbMask = (1 << _pb) - 1;
    final lpMask = (1 << _lp) - 1;
    while (pos < end) {
      final posState = pos & pbMask;
      // The longest step writes 273 bytes.
      if (pos + 273 > out.length && out.length < _cap) out = reserve(pos + 273 < end ? pos + 273 : end);
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
            if (pos - _rep0 - 1 < 0) _bad('match before the start');
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

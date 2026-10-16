/// PPMd variant H (Dmitry Shkarin's model, as RAR 2.9+ and 7z's PPMd coder
/// use it) in pure Dart: the model and its sub-allocator over one byte heap
/// (references are heap offsets, 0 is null), with two range-coder front
/// ends, RAR's carry-less coder and 7z's.
library;

import 'dart:typed_data';

import '../core.dart';

Never _bad(String why) => throw ContentException('corrupt archive: PPMd $why');

/// The range decoder a model reads through.
abstract class PpmdCoder {
  /// The count in [0, total) for the next symbol; scales the range.
  int threshold(int total);

  /// Consume [start, start+size) of the last threshold's total.
  void decode(int start, int size);

  /// A binary decision with probability [size0] of 2^14: 0 or 1.
  int bit(int size0);
}

/// RAR's coder (Subbotin's carry-less range coder).
final class RarPpmdCoder implements PpmdCoder {
  RarPpmdCoder(this._next) {
    for (var i = 0; i < 4; i++) {
      _code = (_code << 8 | _next()) & 0xFFFFFFFF;
    }
  }

  final int Function() _next;
  var _low = 0, _code = 0, _range = 0xFFFFFFFF;

  @override
  int threshold(int total) {
    _range = _range ~/ total;
    return ((_code - _low) & 0xFFFFFFFF) ~/ _range;
  }

  @override
  void decode(int start, int size) {
    _low = (_low + _range * start) & 0xFFFFFFFF;
    _range = (_range * size) & 0xFFFFFFFF;
    _normalize();
  }

  @override
  int bit(int size0) {
    _range >>= 14;
    final count = ((_code - _low) & 0xFFFFFFFF) ~/ _range;
    if (count < size0) {
      decode(0, size0);
      return 0;
    }
    decode(size0, 16384 - size0);
    return 1;
  }

  void _normalize() {
    const top = 1 << 24, bot = 1 << 15;
    while (true) {
      if ((_low ^ ((_low + _range) & 0xFFFFFFFF)) >= top) {
        if (_range >= bot) return;
        _range = (-_low) & (bot - 1);
      }
      _code = (_code << 8 | _next()) & 0xFFFFFFFF;
      _range = (_range << 8) & 0xFFFFFFFF;
      _low = (_low << 8) & 0xFFFFFFFF;
    }
  }
}

/// 7z's coder (Ppmd7z_RangeDec).
final class SevenzipPpmdCoder implements PpmdCoder {
  SevenzipPpmdCoder(this._next) {
    if (_next() != 0) _bad('range coder start');
    for (var i = 0; i < 4; i++) {
      _code = (_code << 8 | _next()) & 0xFFFFFFFF;
    }
    if (_code == 0xFFFFFFFF) _bad('range coder start');
  }

  final int Function() _next;
  var _code = 0, _range = 0xFFFFFFFF;

  @override
  int threshold(int total) => _code ~/ (_range = _range ~/ total);

  @override
  void decode(int start, int size) {
    _code = (_code - start * _range) & 0xFFFFFFFF;
    _range = (_range * size) & 0xFFFFFFFF;
    _normalize();
  }

  @override
  int bit(int size0) {
    final bound = (_range ~/ 16384) * size0;
    int symbol;
    if (_code < bound) {
      symbol = 0;
      _range = bound;
    } else {
      symbol = 1;
      _code -= bound;
      _range -= bound;
    }
    _normalize();
    return symbol;
  }

  void _normalize() {
    if (_range < 1 << 24) {
      _code = (_code << 8 | _next()) & 0xFFFFFFFF;
      _range = (_range << 8) & 0xFFFFFFFF;
      if (_range < 1 << 24) {
        _code = (_code << 8 | _next()) & 0xFFFFFFFF;
        _range = (_range << 8) & 0xFFFFFFFF;
      }
    }
  }
}

const _unit = 12;
const _maxFreq = 124;
const _intBits = 7, _periodBits = 7;
const _binScale = 1 << (_intBits + _periodBits);
const _numIndexes = 38;
const _initBinEsc = [0x3CDD, 0x1F3F, 0x59BF, 0x48F3, 0x64A1, 0x5ABC, 0x6632, 0x6051];
const _expEscape = [25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2];

final _indx2Units = () {
  final u = Uint8List(_numIndexes);
  var i = 0, k = 1;
  for (; i < 4; i++, k += 1) {
    u[i] = k;
  }
  for (k++; i < 8; i++, k += 2) {
    u[i] = k;
  }
  for (k++; i < 12; i++, k += 3) {
    u[i] = k;
  }
  for (k++; i < _numIndexes; i++, k += 4) {
    u[i] = k;
  }
  return u;
}();

final _units2Indx = () {
  final u = Uint8List(128);
  for (var k = 0, i = 0; k < 128; k++) {
    if (_indx2Units[i] < k + 1) i++;
    u[k] = i;
  }
  return u;
}();

final _ns2Indx = () {
  final n = Uint8List(256);
  var i = 0;
  for (; i < 3; i++) {
    n[i] = i;
  }
  for (var m = i, k = 1, step = 1; i < 256; i++) {
    n[i] = m;
    if (--k == 0) {
      k = ++step;
      m++;
    }
  }
  return n;
}();

final _ns2BsIndx = () {
  final n = Uint8List(256);
  n[0] = 0;
  n[1] = 2;
  n.fillRange(2, 11, 4);
  n.fillRange(11, 256, 6);
  return n;
}();

final _hb2Flag = Uint8List(256)..fillRange(0x40, 256, 8);

/// The PPMd variant H model. One instance per stream (RAR keeps it across
/// PPM blocks of a solid run unless a block resets it).
final class Ppmd {
  Ppmd(int memSize, this._maxOrder) : _size = memSize, _heap = Uint8List(_start + memSize + 3 * _unit) {
    _view = ByteData.sublistView(_heap);
    _restart();
  }

  late final ByteData _view;

  static const _start = 4; // so no reference is 0
  final int _size;
  final Uint8List _heap;
  final int _maxOrder;

  late int _text, _unitsStart, _loUnit, _hiUnit, _glueCount;
  final _freeList = Int32List(_numIndexes);

  late int _minContext, _maxContext, _foundState; // 0 = none
  var _orderFall = 0, _initEsc = 0, _prevSuccess = 0, _hiBitsFlag = 0, _runLength = 0, _initRL = 0;
  var _numMasked = 0, _escCount = 1;
  final _charMask = Uint8List(256);
  final _ps = Int32List(256); // decodeSymbol2's candidate states
  final _tmp = Uint8List(6);
  final _binSumm = Uint16List(128 * 64);
  final _seeSumm = Uint16List(25 * 16 + 1);
  final _seeShift = Uint8List(25 * 16 + 1);
  final _seeCount = Uint8List(25 * 16 + 1);
  static const _dummySee = 25 * 16;

  // --- heap access -----------------------------------------------------------

  int _u16(int at) => _view.getUint16(at, Endian.little);
  void _set16(int at, int v) => _view.setUint16(at, v & 0xFFFF, Endian.little);
  int _u32(int at) => _view.getUint32(at, Endian.little);
  void _set32(int at, int v) => _view.setUint32(at, v & 0xFFFFFFFF, Endian.little);

  // Context: NumStats u16 @0, SummFreq u16 @2, Stats @4, Suffix @8; a context
  // with one state keeps it at @2 (Symbol @2, Freq @3, Successor @4).
  int _numStats(int c) => _u16(c);
  int _summFreq(int c) => _u16(c + 2);
  int _stats(int c) => _u32(c + 4);
  int _suffix(int c) => _u32(c + 8);
  int _oneState(int c) => c + 2;

  // State (6 bytes): Symbol @0, Freq @1, Successor @2.
  int _sym(int s) => _heap[s];
  int _freq(int s) => _heap[s + 1];
  void _setFreq(int s, int v) => _heap[s + 1] = v;
  int _succ(int s) => _u32(s + 2);
  void _setSucc(int s, int v) => _set32(s + 2, v);

  void _copyState(int to, int from) => _heap.setRange(to, to + 6, _heap, from);

  void _swapStates(int a, int b) {
    for (var i = 0; i < 6; i++) {
      final t = _heap[a + i];
      _heap[a + i] = _heap[b + i];
      _heap[b + i] = t;
    }
  }

  // --- sub-allocator ---------------------------------------------------------

  void _insertNode(int p, int indx) {
    _set32(p, _freeList[indx]);
    _freeList[indx] = p;
  }

  int _removeNode(int indx) {
    final p = _freeList[indx];
    _freeList[indx] = _u32(p);
    return p;
  }

  void _splitBlock(int p, int oldIndx, int newIndx) {
    var diff = _indx2Units[oldIndx] - _indx2Units[newIndx];
    p += _indx2Units[newIndx] * _unit;
    var i = _units2Indx[diff - 1];
    if (_indx2Units[i] != diff) {
      _insertNode(p, --i);
      p += _indx2Units[i] * _unit;
      diff -= _indx2Units[i];
    }
    _insertNode(p, _units2Indx[diff - 1]);
  }

  /// Merge adjacent free blocks (Shkarin's: stamp 0xFFFF marks a free one).
  void _glueFreeBlocks() {
    final s0 = _start + _size + _unit; // a sentinel node past the heap
    _set32(s0 + 4, s0); // next
    _set32(s0 + 8, s0); // prev
    if (_loUnit != _hiUnit) _heap[_loUnit] = 0;
    void insertAt(int p, int at) {
      final next = _u32(at + 4);
      _set32(p + 8, at);
      _set32(p + 4, next);
      _set32(next + 8, p);
      _set32(at + 4, p);
    }

    void remove(int p) {
      final prev = _u32(p + 8), next = _u32(p + 4);
      _set32(prev + 4, next);
      _set32(next + 8, prev);
    }

    for (var i = 0; i < _numIndexes; i++) {
      while (_freeList[i] != 0) {
        final p = _removeNode(i);
        insertAt(p, s0);
        _set16(p, 0xFFFF);
        _set16(p + 2, _indx2Units[i]);
      }
    }
    for (var p = _u32(s0 + 4); p != s0; p = _u32(p + 4)) {
      while (true) {
        final p1 = p + _u16(p + 2) * _unit;
        if (p1 + 4 > _heap.length || _u16(p1) != 0xFFFF || _u16(p + 2) + _u16(p1 + 2) >= 0x10000) break;
        remove(p1);
        _set16(p + 2, _u16(p + 2) + _u16(p1 + 2));
      }
    }
    while (true) {
      var p = _u32(s0 + 4);
      if (p == s0) break;
      remove(p);
      var sz = _u16(p + 2);
      for (; sz > 128; sz -= 128, p += 128 * _unit) {
        _insertNode(p, _numIndexes - 1);
      }
      var i = _units2Indx[sz - 1];
      if (_indx2Units[i] != sz) {
        final k = sz - _indx2Units[--i];
        _insertNode(p + (sz - k) * _unit, k - 1);
      }
      _insertNode(p, i);
    }
  }

  int _allocUnitsRare(int indx) {
    if (_glueCount == 0) {
      _glueCount = 255;
      _glueFreeBlocks();
      if (_freeList[indx] != 0) return _removeNode(indx);
    }
    var i = indx;
    do {
      if (++i == _numIndexes) {
        _glueCount--;
        final bytes = _indx2Units[indx] * _unit;
        if (_unitsStart - _text > bytes) {
          _unitsStart -= bytes;
          return _unitsStart;
        }
        return 0;
      }
    } while (_freeList[i] == 0);
    final p = _removeNode(i);
    _splitBlock(p, i, indx);
    return p;
  }

  int _allocUnits(int nu) {
    final indx = _units2Indx[nu - 1];
    if (_freeList[indx] != 0) return _removeNode(indx);
    final p = _loUnit;
    _loUnit += _indx2Units[indx] * _unit;
    if (_loUnit <= _hiUnit) return p;
    _loUnit -= _indx2Units[indx] * _unit;
    return _allocUnitsRare(indx);
  }

  int _allocContext() {
    if (_hiUnit != _loUnit) return _hiUnit -= _unit;
    if (_freeList[0] != 0) return _removeNode(0);
    return _allocUnitsRare(0);
  }

  int _expandUnits(int old, int oldNU) {
    final i0 = _units2Indx[oldNU - 1], i1 = _units2Indx[oldNU];
    if (i0 == i1) return old;
    final p = _allocUnits(oldNU + 1);
    if (p != 0) {
      _heap.setRange(p, p + oldNU * _unit, _heap, old);
      _insertNode(old, i0);
    }
    return p;
  }

  int _shrinkUnits(int old, int oldNU, int newNU) {
    final i0 = _units2Indx[oldNU - 1], i1 = _units2Indx[newNU - 1];
    if (i0 == i1) return old;
    if (_freeList[i1] != 0) {
      final p = _removeNode(i1);
      _heap.setRange(p, p + newNU * _unit, _heap, old);
      _insertNode(old, i0);
      return p;
    }
    _splitBlock(old, i0, i1);
    return old;
  }

  // --- model -----------------------------------------------------------------

  void _restart() {
    _charMask.fillRange(0, 256, 0);
    _freeList.fillRange(0, _numIndexes, 0);
    _text = _start;
    final size2 = _unit * (_size ~/ 8 ~/ _unit * 7);
    final size1 = _size - size2;
    _loUnit = _unitsStart = _start + size1;
    _hiUnit = _loUnit + size2;
    _glueCount = 0;
    _initRL = -(_maxOrder < 12 ? _maxOrder : 12) - 1;
    _minContext = _maxContext = _allocContext();
    _set32(_minContext + 8, 0);
    _orderFall = _maxOrder;
    _set16(_minContext, 256);
    _set16(_minContext + 2, 257);
    _foundState = _allocUnits(128);
    _set32(_minContext + 4, _foundState);
    _runLength = _initRL;
    _prevSuccess = 0;
    for (var i = 0; i < 256; i++) {
      final s = _foundState + i * 6;
      _heap[s] = i;
      _heap[s + 1] = 1;
      _setSucc(s, 0);
    }
    for (var i = 0; i < 128; i++) {
      for (var k = 0; k < 8; k++) {
        final v = _binScale - _initBinEsc[k] ~/ (i + 2);
        for (var m = 0; m < 64; m += 8) {
          _binSumm[i * 64 + k + m] = v;
        }
      }
    }
    for (var i = 0; i < 25; i++) {
      for (var k = 0; k < 16; k++) {
        final see = i * 16 + k;
        _seeShift[see] = _periodBits - 4;
        _seeSumm[see] = (5 * i + 10) << _seeShift[see];
        _seeCount[see] = 4;
      }
    }
    _seeShift[_dummySee] = _periodBits;
    _seeSumm[_dummySee] = 0;
    _seeCount[_dummySee] = 64;
  }

  int _createSuccessors(bool skip, int p1) {
    var pc = _minContext;
    final upBranch = _succ(_foundState);
    final ps = <int>[];
    var p = 0;
    var loop = true;
    if (!skip) {
      ps.add(_foundState);
      if (_suffix(pc) == 0) loop = false;
    }
    if (loop) {
      var entry = p1 != 0;
      if (entry) {
        p = p1;
        pc = _suffix(pc);
      }
      while (true) {
        if (!entry) {
          pc = _suffix(pc);
          if (_numStats(pc) != 1) {
            p = _stats(pc);
            while (_sym(p) != _sym(_foundState)) {
              p += 6;
            }
          } else {
            p = _oneState(pc);
          }
        }
        entry = false;
        if (_succ(p) != upBranch) {
          pc = _succ(p);
          break;
        }
        ps.add(p);
        if (_suffix(pc) == 0) break;
      }
    }
    if (ps.isEmpty) return pc;
    final upSym = _heap[upBranch];
    final upSucc = upBranch + 1;
    int upFreq;
    if (_numStats(pc) != 1) {
      if (pc <= _text) return 0;
      p = _stats(pc);
      while (_sym(p) != upSym) {
        p += 6;
      }
      final cf = _freq(p) - 1;
      final s0 = _summFreq(pc) - _numStats(pc) - cf;
      upFreq = 1 + (2 * cf <= s0 ? (5 * cf > s0 ? 1 : 0) : (2 * cf + 3 * s0 - 1) ~/ (2 * s0));
    } else {
      upFreq = _freq(_oneState(pc));
    }
    do {
      final c = _allocContext();
      if (c == 0) return 0;
      _set16(c, 1);
      final s = _oneState(c);
      _heap[s] = upSym;
      _heap[s + 1] = upFreq;
      _setSucc(s, upSucc);
      _set32(c + 8, pc);
      _setSucc(ps.removeLast(), c);
      pc = c;
    } while (ps.isNotEmpty);
    return pc;
  }

  void _updateModel() {
    final fsSym = _sym(_foundState), fsFreq = _freq(_foundState);
    var fsSucc = _succ(_foundState);
    var p = 0;
    var pc = _suffix(_minContext);
    if (fsFreq < _maxFreq ~/ 4 && pc != 0) {
      if (_numStats(pc) != 1) {
        p = _stats(pc);
        if (_sym(p) != fsSym) {
          do {
            p += 6;
          } while (_sym(p) != fsSym);
          if (_freq(p) >= _freq(p - 6)) {
            _swapStates(p, p - 6);
            p -= 6;
          }
        }
        if (_freq(p) < _maxFreq - 9) {
          _setFreq(p, _freq(p) + 2);
          _set16(pc + 2, _summFreq(pc) + 2);
        }
      } else {
        p = _oneState(pc);
        if (_freq(p) < 32) _setFreq(p, _freq(p) + 1);
      }
    }
    if (_orderFall == 0) {
      _minContext = _maxContext = _createSuccessors(true, p);
      _setSucc(_foundState, _minContext);
      if (_minContext == 0) _restartAfterOverflow();
      return;
    }
    _heap[_text++] = fsSym;
    var successor = _text;
    if (_text >= _unitsStart) return _restartAfterOverflow();
    if (fsSucc != 0) {
      if (fsSucc <= _text) {
        fsSucc = _createSuccessors(false, p);
        if (fsSucc == 0) return _restartAfterOverflow();
      }
      if (--_orderFall == 0) {
        successor = fsSucc;
        if (_maxContext != _minContext) _text--;
      }
    } else {
      _setSucc(_foundState, successor);
      fsSucc = _minContext;
    }
    final ns = _numStats(_minContext);
    final s0 = _summFreq(_minContext) - ns - (fsFreq - 1);
    for (pc = _maxContext; pc != _minContext; pc = _suffix(pc)) {
      var ns1 = _numStats(pc);
      if (ns1 != 1) {
        if (ns1 & 1 == 0) {
          final stats = _expandUnits(_stats(pc), ns1 >> 1);
          if (stats == 0) return _restartAfterOverflow();
          _set32(pc + 4, stats);
        }
        var sf = _summFreq(pc);
        sf += (2 * ns1 < ns ? 1 : 0) + 2 * ((4 * ns1 <= ns ? 1 : 0) & (sf <= 8 * ns1 ? 1 : 0));
        _set16(pc + 2, sf);
      } else {
        final s = _allocUnits(1);
        if (s == 0) return _restartAfterOverflow();
        _copyState(s, _oneState(pc));
        _set32(pc + 4, s);
        var f = _freq(s);
        f = f < _maxFreq ~/ 4 - 1 ? f * 2 : _maxFreq - 4;
        _setFreq(s, f);
        _set16(pc + 2, f + _initEsc + (ns > 3 ? 1 : 0));
      }
      var cf = 2 * fsFreq * (_summFreq(pc) + 6);
      final sf = s0 + _summFreq(pc);
      if (cf < 6 * sf) {
        cf = 1 + (cf > sf ? 1 : 0) + (cf >= 4 * sf ? 1 : 0);
        _set16(pc + 2, _summFreq(pc) + 3);
      } else {
        cf = 4 + (cf >= 9 * sf ? 1 : 0) + (cf >= 12 * sf ? 1 : 0) + (cf >= 15 * sf ? 1 : 0);
        _set16(pc + 2, _summFreq(pc) + cf);
      }
      final ns1p = _stats(pc) + ns1 * 6;
      _setSucc(ns1p, successor);
      _heap[ns1p] = fsSym;
      _heap[ns1p + 1] = cf;
      _set16(pc, ++ns1);
    }
    _maxContext = _minContext = fsSucc;
  }

  void _restartAfterOverflow() {
    _restart();
    _escCount = 0;
  }

  void _rescale() {
    final c = _minContext;
    final oldNS = _numStats(c);
    var i = oldNS - 1;
    final stats = _stats(c);
    var p = _foundState;
    for (; p != stats; p -= 6) {
      _swapStates(p, p - 6);
    }
    _setFreq(stats, _freq(stats) + 4);
    var summ = _summFreq(c) + 4;
    var escFreq = summ - _freq(p);
    final adder = _orderFall != 0 ? 1 : 0;
    _setFreq(p, (_freq(p) + adder) >> 1);
    summ = _freq(p);
    do {
      p += 6;
      escFreq -= _freq(p);
      _setFreq(p, (_freq(p) + adder) >> 1);
      summ += _freq(p);
      if (_freq(p) > _freq(p - 6)) {
        var p1 = p;
        final tmp = _tmp..setRange(0, 6, _heap, p1);
        do {
          _copyState(p1, p1 - 6);
          p1 -= 6;
        } while (p1 != stats && tmp[1] > _freq(p1 - 6));
        _heap.setRange(p1, p1 + 6, tmp);
      }
    } while (--i != 0);
    var ns = oldNS;
    if (_freq(p) == 0) {
      do {
        i++;
        p -= 6;
      } while (_freq(p) == 0);
      escFreq += i;
      ns -= i;
      _set16(c, ns);
      if (ns == 1) {
        final tmp = Uint8List.fromList(_heap.sublist(stats, stats + 6));
        do {
          tmp[1] = tmp[1] - (tmp[1] >> 1);
          escFreq >>= 1;
        } while (escFreq > 1);
        _insertNode(stats, _units2Indx[((oldNS + 1) >> 1) - 1]);
        _foundState = _oneState(c);
        _heap.setRange(_foundState, _foundState + 6, tmp);
        return;
      }
    }
    escFreq -= escFreq >> 1;
    _set16(c + 2, summ + escFreq);
    final n0 = (oldNS + 1) >> 1, n1 = (ns + 1) >> 1;
    if (n0 != n1) _set32(c + 4, _shrinkUnits(stats, n0, n1));
    _foundState = _stats(c);
  }

  int _seeFor(int diff) {
    final c = _minContext;
    final ns = _numStats(c);
    if (ns == 256) return _dummySee;
    final suffixNs = _numStats(_suffix(c));
    return _ns2Indx[diff - 1] * 16 +
        (diff < suffixNs - ns ? 1 : 0) +
        2 * (_summFreq(c) < 11 * ns ? 1 : 0) +
        4 * (_numMasked > diff ? 1 : 0) +
        _hiBitsFlag;
  }

  int _seeMean(int see) {
    if (see == _dummySee) return 1;
    final r = _seeSumm[see] >> _seeShift[see];
    _seeSumm[see] = (_seeSumm[see] - r) & 0xFFFF;
    return r + (r == 0 ? 1 : 0);
  }

  void _seeUpdate(int see) {
    if (see == _dummySee) return;
    if (_seeShift[see] < _periodBits && --_seeCount[see] == 0) {
      _seeSumm[see] = (_seeSumm[see] << 1) & 0xFFFF;
      _seeCount[see] = 3 << _seeShift[see]++;
    }
  }

  void _clearMask() {
    _escCount = 1;
    _charMask.fillRange(0, 256, 0);
  }

  bool _valid(int c) => c > _text && c < _start + _size + _unit;

  /// The next byte, or -1 at the end mark or on damage.
  int decodeChar(PpmdCoder rc) {
    var c = _minContext;
    if (!_valid(c)) return -1;
    if (_numStats(c) != 1) {
      final stats = _stats(c);
      if (!_valid(stats)) return -1;
      // decodeSymbol1
      final scale = _summFreq(c);
      final count = rc.threshold(scale);
      if (count >= scale) return -1;
      var p = stats;
      var hiCnt = _freq(p);
      if (count < hiCnt) {
        _prevSuccess = 2 * hiCnt > scale ? 1 : 0;
        _runLength += _prevSuccess;
        _foundState = p;
        hiCnt += 4;
        _setFreq(p, hiCnt);
        _set16(c + 2, scale + 4);
        rc.decode(0, hiCnt - 4);
        if (hiCnt > _maxFreq) _rescale();
      } else {
        if (_foundState == 0) return -1;
        _prevSuccess = 0;
        var i = _numStats(c) - 1;
        var found = false;
        while (true) {
          p += 6;
          hiCnt += _freq(p);
          if (hiCnt > count) {
            found = true;
            break;
          }
          if (--i == 0) break;
        }
        if (found) {
          rc.decode(hiCnt - _freq(p), _freq(p));
          // update1
          _foundState = p;
          _setFreq(p, _freq(p) + 4);
          _set16(c + 2, _summFreq(c) + 4);
          if (_freq(p) > _freq(p - 6)) {
            _swapStates(p, p - 6);
            _foundState = p - 6;
            if (_freq(_foundState) > _maxFreq) _rescale();
          }
        } else {
          _hiBitsFlag = _hb2Flag[_sym(_foundState)];
          rc.decode(hiCnt, scale - hiCnt);
          _charMask[_sym(p)] = _escCount;
          _numMasked = _numStats(c);
          i = _numMasked - 1;
          _foundState = 0;
          do {
            p -= 6;
            _charMask[_sym(p)] = _escCount;
          } while (--i != 0);
        }
      }
    } else {
      // decodeBinSymbol
      final rs = _oneState(c);
      _hiBitsFlag = _hb2Flag[_sym(_foundState)];
      final idx =
          (_freq(rs) - 1) * 64 +
          _prevSuccess +
          _ns2BsIndx[_numStats(_suffix(c)) - 1] +
          _hiBitsFlag +
          2 * _hb2Flag[_sym(rs)] +
          ((_runLength >> 26) & 0x20);
      final bs = _binSumm[idx];
      if (rc.bit(bs) == 0) {
        _foundState = rs;
        if (_freq(rs) < 128) _setFreq(rs, _freq(rs) + 1);
        _binSumm[idx] = (bs + (1 << _intBits) - ((bs + (1 << (_periodBits - 2))) >> _periodBits)) & 0xFFFF;
        _prevSuccess = 1;
        _runLength++;
      } else {
        final nb = (bs - ((bs + (1 << (_periodBits - 2))) >> _periodBits)) & 0xFFFF;
        _binSumm[idx] = nb;
        _initEsc = _expEscape[nb >> 10];
        _numMasked = 1;
        _charMask[_sym(rs)] = _escCount;
        _prevSuccess = 0;
        _foundState = 0;
      }
    }
    while (_foundState == 0) {
      do {
        _orderFall++;
        c = _suffix(c);
        if (!_valid(c)) return -1;
      } while (_numStats(c) == _numMasked);
      _minContext = c;
      // decodeSymbol2
      var i = _numStats(c) - _numMasked;
      final see = _seeFor(i);
      var scale = _seeMean(see);
      final ps = _ps;
      var n = 0;
      var p = _stats(c) - 6;
      var hiCnt = 0;
      do {
        do {
          p += 6;
        } while (_charMask[_heap[p]] == _escCount);
        hiCnt += _heap[p + 1];
        ps[n++] = p;
      } while (--i != 0);
      scale += hiCnt;
      final count = rc.threshold(scale);
      if (count >= scale) return -1;
      if (count < hiCnt) {
        var k = 0;
        p = ps[0];
        hiCnt = _freq(p);
        while (hiCnt <= count) {
          p = ps[++k];
          hiCnt += _freq(p);
        }
        rc.decode(hiCnt - _freq(p), _freq(p));
        _seeUpdate(see);
        // update2
        _foundState = p;
        _setFreq(p, _freq(p) + 4);
        _set16(c + 2, _summFreq(c) + 4);
        if (_freq(p) > _maxFreq) _rescale();
        _escCount = (_escCount + 1) & 0xFF;
        _runLength = _initRL;
      } else {
        rc.decode(hiCnt, scale - hiCnt);
        for (var k = 0; k < n; k++) {
          _charMask[_heap[ps[k]]] = _escCount;
        }
        if (see != _dummySee) _seeSumm[see] = (_seeSumm[see] + scale) & 0xFFFF;
        _numMasked = _numStats(c);
      }
    }
    final symbol = _sym(_foundState);
    final succ = _succ(_foundState);
    if (_orderFall == 0 && succ > _text) {
      _minContext = _maxContext = succ;
    } else {
      _updateModel();
      if (_escCount == 0) _clearMask();
    }
    return symbol;
  }
}

/// 7z's PPMd coder: [props] are the order (1 byte) and memory (u32 LE).
Uint8List ppmdDecode7z(Uint8List input, List<int> props, int size) {
  if (props.length < 5) _bad('properties');
  final order = props[0];
  final mem = props[1] | props[2] << 8 | props[3] << 16 | props[4] << 24;
  // 2 GiB is 32-bit 7-Zip's limit: every archive it writes opens.
  if (order < 2 || order > 64 || mem < 2048 || mem > 1 << 31) _bad('properties');
  // The model is allocated up front: past 256 MiB (7-Zip's -mx9 uses 192)
  // 7-Zip decodes it instead.
  if (mem > 256 << 20) throw ContentException('unsupported in memory: PPMd model of ${mem >> 20} MiB');
  if (size < 0) _bad('size');
  var i = 0;
  // A few zero bytes past the end are the coder's lookahead; more is a
  // stream that never ends.
  final rc = SevenzipPpmdCoder(
    () => i < input.length ? input[i++] : (++i > input.length + 8 ? _bad('data ends early') : 0),
  );
  final model = Ppmd(mem, order);
  // A header can claim any size: past 1 GiB the output grows as it decodes.
  var out = Uint8List(size < 1 << 30 ? size : 1 << 30);
  for (var k = 0; k < size; k++) {
    final b = model.decodeChar(rc);
    if (b < 0) _bad('data ends early');
    if (k == out.length) out = Uint8List(k * 2 < size ? k * 2 : size)..setRange(0, k, out);
    out[k] = b;
  }
  return out;
}

/// A 7z reader in pure Dart for `archive`: the container (encoded headers,
/// streams, folders, substreams, names, attributes), the coders Copy, LZMA,
/// LZMA2, PPMd, Deflate, the BCJ x86/ARM64 and Delta filters, and AES-256
/// (7z's SHA-256 key rounds, CBC). Every file's CRC is checked.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'aes.dart';
import 'bcj.dart';
import 'budget.dart';
import 'crc32.dart';
import 'lzma.dart';
import 'ppmd.dart';
import 'zip.dart' show inflateRaw;

import '../core.dart';

/// The 7z signature: `7z\xBC\xAF\x27\x1C`.
bool isSevenzip(List<int> b) =>
    b.length >= 6 && b[0] == 0x37 && b[1] == 0x7A && b[2] == 0xBC && b[3] == 0xAF && b[4] == 0x27 && b[5] == 0x1C;

/// One member as read.
final class SevenzipEntry {
  SevenzipEntry._(this.name, this.isDir, this.mode, this.mtime, this._data);

  /// `/`-separated; folders have no trailing `/`.
  final String name;
  final bool isDir;

  /// A symlink: [data] is its target.
  bool get isLink => mode & 0xF000 == 0xA000;

  /// When it was last modified, when the archive says.
  final DateTime? mtime;

  /// Unix `st_mode` when the archive recorded one (7-Zip's 0x8000 flag),
  /// else 0.
  final int mode;

  final Uint8List Function() _data;

  /// The member's bytes (its folder decodes once, on first use).
  Uint8List data() => _data();
}

Never _bad(String why) => throw ContentException('corrupt archive: 7z $why');

/// The members of the 7z archive in [b]; [password] opens AES folders and
/// encrypted headers.
List<SevenzipEntry> readSevenzip(Uint8List b, {String? password}) {
  if (!isSevenzip(b) || b.length < 32) _bad('signature');
  final r = _Bytes(b, 12);
  final nextOffset = r.u64();
  final nextSize = r.u64();
  if (nextOffset < 0 || nextSize < 0 || nextOffset > 1 << 48 || nextSize > 1 << 32) _bad('header position');
  final nextCrc = r.u32();
  final start = 32 + nextOffset;
  if (nextSize == 0) return const [];
  if (start + nextSize > b.length) _bad('header past the end');
  if (crc32(b, start: start, end: start + nextSize) != nextCrc) _bad('header CRC');
  var header = _Bytes(Uint8List.sublistView(b, start, start + nextSize), 0);
  final pw = password;
  final budget = Budget();
  // An encoded header is a folder whose output is the real header; 7-Zip
  // nests at most one, so a deeper chain (or one pointing at itself) is
  // damage.
  for (var depth = 0; header.peek() == 0x17; depth++) {
    if (depth == 4) _bad('encoded headers nest too deep');
    header.byte();
    final info = _StreamsInfo.read(header);
    if (info.folders.isEmpty) _bad('empty encoded header');
    // 7-Zip's own headers stay far below this; the size drives allocations.
    if (info.folders[0].unpackSize > 64 << 20) _bad('encoded header of ${info.folders[0].unpackSize} bytes');
    final decoded = _decodeFolder(b, info, 0, pw, budget);
    final crc = info.folders[0].crc;
    if (crc != null && crc32(decoded) != crc) {
      throw pw == null
          ? ContentException('corrupt archive: 7z header CRC')
          : PasswordException('wrong password or corrupt archive');
    }
    header = _Bytes(decoded, 0);
    if (pw != null && header.peek() != 0x01 && header.peek() != 0x17) {
      throw const PasswordException('wrong password or corrupt archive');
    }
  }
  if (header.byte() != 0x01) _bad('missing header');
  _StreamsInfo? main;
  var files = <_File>[];
  for (var id = header.byte(); id != 0x00; id = header.byte()) {
    switch (id) {
      case 0x02: // archive properties
        for (var t = header.byte(); t != 0; t = header.byte()) {
          header.skip(header.number());
        }
      case 0x03: // additional streams
        _StreamsInfo.read(header);
      case 0x04:
        main = _StreamsInfo.read(header);
      case 0x05:
        files = _readFiles(header, budget);
      default:
        _bad('header property $id');
    }
  }
  final info = main ?? _StreamsInfo.empty();
  for (final f in info.folders) {
    budget.take(f.unpackSizes.fold(0, (a, n) => a + n), '7z');
  }
  // Files with data take the substreams in order; empty ones take none.
  final out = <SevenzipEntry>[];
  var folder = 0, inFolder = 0, sub = 0, offset = 0;
  // A decoded folder stays until its last member has taken its bytes.
  final cache = <int, Uint8List>{};
  final left = List.of(info.subCounts);
  for (final f in files) {
    if (!f.hasStream) {
      out.add(SevenzipEntry._(f.name, f.isDir, f.mode, f.mtime, () => Uint8List(0)));
      continue;
    }
    while (folder < info.folders.length && inFolder >= info.subCounts[folder]) {
      folder++;
      inFolder = 0;
      offset = 0;
    }
    if (folder >= info.folders.length || sub >= info.subSizes.length) _bad('more files than streams');
    final fi = folder, si = sub, at = offset;
    final size = info.subSizes[si];
    final crc = info.subCrcs[si];
    out.add(
      SevenzipEntry._(f.name, false, f.mode, f.mtime, () {
        final whole = cache[fi] ??= _decodeFolder(b, info, fi, pw, budget);
        if (--left[fi] <= 0) cache.remove(fi);
        if (size < 0 || at + size > whole.length) _bad('file past its folder');
        final data = Uint8List.sublistView(whole, at, at + size);
        if (crc != null && crc32(data) != crc) {
          throw pw == null
              ? ContentException('corrupt archive: 7z CRC of ${f.name}')
              : PasswordException('wrong password or corrupt archive: ${f.name}');
        }
        return data;
      }),
    );
    inFolder++;
    sub++;
    offset += size;
  }
  return out;
}

final class _File {
  _File(this.name, this.hasStream, this.isDir, this.mode, this.mtime);
  final String name;
  final bool hasStream;
  final bool isDir;
  final int mode;
  final DateTime? mtime;
}

List<_File> _readFiles(_Bytes h, Budget budget) {
  final n = h.number();
  // Every file needs at least its two-byte name terminator.
  if (n > h.b.length) _bad('$n files in a ${h.b.length}-byte header');
  budget.count(n, '7z');
  var emptyStream = List.filled(n, false);
  var emptyFile = <bool>[];
  var names = List.filled(n, '');
  final attrs = List<int?>.filled(n, null);
  final mtimes = List<DateTime?>.filled(n, null);
  for (var type = h.byte(); type != 0; type = h.byte()) {
    final size = h.number();
    final end = h.pos + size;
    switch (type) {
      case 0x0E:
        emptyStream = h.bits(n);
      case 0x0F:
        emptyFile = h.bits(emptyStream.where((e) => e).length);
      case 0x11:
        if (h.byte() != 0) _bad('external names');
        final raw = h.bytes(size - 1);
        final all = <String>[];
        var from = 0;
        for (var i = 0; i + 1 < raw.length; i += 2) {
          if (raw[i] == 0 && raw[i + 1] == 0) {
            all.add(String.fromCharCodes(Uint16List.sublistView(Uint8List.fromList(raw.sublist(from, i)))));
            from = i + 2;
          }
        }
        if (all.length != n) _bad('${all.length} names for $n files');
        names = all;
      case 0x15:
        final defined = h.allOrBits(n);
        if (h.byte() != 0) _bad('external attributes');
        for (var i = 0; i < n; i++) {
          if (defined[i]) attrs[i] = h.u32();
        }
      case 0x14: // modified times: FILETIME, 100 ns steps from 1601
        final defined = h.allOrBits(n);
        if (h.byte() != 0) _bad('external times');
        for (var i = 0; i < n; i++) {
          if (!defined[i]) continue;
          final us = (h.u64() - _epoch1601) ~/ 10;
          if (us.abs() < 8640000000000000000) mtimes[i] = DateTime.fromMicrosecondsSinceEpoch(us);
        }
      default:
        break; // other times, anti items, padding: not needed
    }
    h.pos = end;
  }
  final out = <_File>[];
  var empty = 0;
  for (var i = 0; i < n; i++) {
    final a = attrs[i];
    final hasStream = !emptyStream[i];
    var isDir = false;
    if (!hasStream) {
      final isEmptyFile = empty < emptyFile.length && emptyFile[empty];
      empty++;
      isDir = !isEmptyFile;
    }
    if (a != null && a & 0x10 != 0) isDir = true;
    final mode = a != null && a & 0x8000 != 0 ? a >> 16 & 0xFFFF : 0;
    out.add(_File(names[i].replaceAll('\\', '/'), hasStream, isDir, mode, mtimes[i]));
  }
  return out;
}

final class _Coder {
  _Coder(this.id, this.ins, this.outs, this.props);
  final List<int> id;
  final int ins, outs;
  final Uint8List props;
}

final class _Folder {
  final coders = <_Coder>[];
  final bindIn = <int>[];
  final bindOut = <int>[];
  final packed = <int>[];
  final unpackSizes = <int>[];
  int? crc;

  int get totalOut => coders.fold(0, (a, c) => a + c.outs);

  /// The folder's final output: the one out stream nothing binds.
  int get mainOut {
    for (var i = 0; i < totalOut; i++) {
      if (!bindOut.contains(i)) return i;
    }
    _bad('folder with no output');
  }

  int get unpackSize => unpackSizes[mainOut];
}

final class _StreamsInfo {
  _StreamsInfo.empty();

  int packPos = 0;
  final packSizes = <int>[];
  final folders = <_Folder>[];
  final subCounts = <int>[];
  final subSizes = <int>[];
  final subCrcs = <int?>[];

  // Running sums, built on first use: a lookup per folder stays O(1).
  late final _packStarts = () {
    final out = List<int>.filled(packSizes.length + 1, 32 + packPos);
    for (var k = 0; k < packSizes.length; k++) {
      out[k + 1] = out[k] + packSizes[k];
    }
    return out;
  }();
  late final _firstPacks = () {
    final out = List<int>.filled(folders.length + 1, 0);
    for (var k = 0; k < folders.length; k++) {
      out[k + 1] = out[k] + folders[k].packed.length;
    }
    return out;
  }();

  int packStart(int index) => index < _packStarts.length ? _packStarts[index] : _bad('pack stream $index');

  int firstPack(int folder) => _firstPacks[folder];

  static _StreamsInfo read(_Bytes h) {
    final info = _StreamsInfo.empty();
    for (var id = h.byte(); id != 0; id = h.byte()) {
      switch (id) {
        case 0x06: // pack info
          info.packPos = h.number();
          final n = h.number();
          if (n > h.b.length) _bad('$n pack streams');
          for (var t = h.byte(); t != 0; t = h.byte()) {
            if (t == 0x09) {
              for (var k = 0; k < n; k++) {
                info.packSizes.add(h.number());
              }
            } else if (t == 0x0A) {
              final defined = h.allOrBits(n);
              for (var k = 0; k < n; k++) {
                if (defined[k]) h.u32();
              }
            } else {
              _bad('pack info property $t');
            }
          }
        case 0x07: // coders info
          if (h.byte() != 0x0B) _bad('missing folders');
          final n = h.number();
          if (h.byte() != 0) _bad('external folders');
          for (var k = 0; k < n; k++) {
            info.folders.add(_readFolder(h));
          }
          if (h.byte() != 0x0C) _bad('missing unpack sizes');
          for (final f in info.folders) {
            for (var k = 0; k < f.totalOut; k++) {
              f.unpackSizes.add(h.number());
            }
          }
          for (var t = h.byte(); t != 0; t = h.byte()) {
            if (t != 0x0A) _bad('coders info property $t');
            final defined = h.allOrBits(n);
            for (var k = 0; k < n; k++) {
              if (defined[k]) info.folders[k].crc = h.u32();
            }
          }
        case 0x08: // substreams
          _readSubstreams(h, info);
        default:
          _bad('streams property $id');
      }
    }
    if (info.subCounts.isEmpty) {
      for (final f in info.folders) {
        info.subCounts.add(1);
        info.subSizes.add(f.unpackSize);
        info.subCrcs.add(f.crc);
      }
    }
    return info;
  }
}

_Folder _readFolder(_Bytes h) {
  final f = _Folder();
  final n = h.number();
  var totalIn = 0;
  for (var k = 0; k < n; k++) {
    final flag = h.byte();
    final id = h.bytes(flag & 0x0F);
    var ins = 1, outs = 1;
    if (flag & 0x10 != 0) {
      ins = h.number();
      outs = h.number();
    }
    final props = flag & 0x20 != 0 ? h.bytes(h.number()) : Uint8List(0);
    if (flag & 0x80 != 0) _bad('alternative coders');
    f.coders.add(_Coder(id, ins, outs, props));
    totalIn += ins;
  }
  for (var k = 0; k < f.totalOut - 1; k++) {
    f.bindIn.add(h.number());
    f.bindOut.add(h.number());
  }
  final packedCount = totalIn - f.bindIn.length;
  if (packedCount == 1) {
    for (var i = 0; i < totalIn; i++) {
      if (!f.bindIn.contains(i)) {
        f.packed.add(i);
        break;
      }
    }
  } else {
    for (var k = 0; k < packedCount; k++) {
      f.packed.add(h.number());
    }
  }
  return f;
}

void _readSubstreams(_Bytes h, _StreamsInfo info) {
  final counts = List.filled(info.folders.length, 1);
  var id = h.byte();
  if (id == 0x0D) {
    for (var k = 0; k < counts.length; k++) {
      counts[k] = h.number();
    }
    id = h.byte();
  }
  final sizes = <int>[];
  final hasSizes = id == 0x09;
  for (var k = 0; k < counts.length; k++) {
    if (counts[k] == 0) continue;
    // Without sizes a folder holds one stream; each further one is a
    // number in the header, so a count can never outgrow it.
    if (!hasSizes && counts[k] > 1) _bad('substreams without sizes');
    var sum = 0;
    if (hasSizes) {
      for (var j = 1; j < counts[k]; j++) {
        final s = h.number();
        sizes.add(s);
        sum += s;
      }
    }
    final last = info.folders[k].unpackSize - sum;
    if (last < 0) _bad('substreams larger than their folder');
    sizes.add(last);
  }
  if (hasSizes) id = h.byte();
  // CRCs: a folder with one substream and a folder CRC already has its own.
  final crcs = <int?>[];
  var needing = 0;
  for (var k = 0; k < counts.length; k++) {
    if (!(counts[k] == 1 && info.folders[k].crc != null)) needing += counts[k];
  }
  List<int?> digests = List.filled(needing, null);
  while (id != 0) {
    if (id == 0x0A) {
      final defined = h.allOrBits(needing);
      digests = [for (var k = 0; k < needing; k++) defined[k] ? h.u32() : null];
    } else {
      h.skip(h.number());
    }
    id = h.byte();
  }
  var d = 0;
  for (var k = 0; k < counts.length; k++) {
    if (counts[k] == 1 && info.folders[k].crc != null) {
      crcs.add(info.folders[k].crc);
    } else {
      for (var j = 0; j < counts[k]; j++) {
        crcs.add(digests[d++]);
      }
    }
  }
  info.subCounts.addAll(counts);
  info.subSizes.addAll(sizes);
  info.subCrcs.addAll(crcs);
}

/// Decode folder [index] of [info] to its final bytes. With a password,
/// any decoding failure inside an AES folder reads as a wrong password: the
/// cipher cannot tell, and the coders after it only see garbage.
Uint8List _decodeFolder(Uint8List b, _StreamsInfo info, int index, String? password, Budget budget) {
  final aes = info.folders[index].coders.any((c) => _hex(c.id) == '06f10701');
  if (!aes || password == null) return _decodeFolderRaw(b, info, index, password, budget);
  try {
    return _decodeFolderRaw(b, info, index, password, budget);
  } on FormatException {
    throw const PasswordException('wrong password or corrupt archive');
  }
}

Uint8List _decodeFolderRaw(Uint8List b, _StreamsInfo info, int index, String? password, Budget budget) {
  final f = info.folders[index];
  final firstPack = info.firstPack(index);
  final cache = <int, Uint8List>{};

  Uint8List packedStream(int k) {
    if (firstPack + k >= info.packSizes.length) _bad('missing packed stream');
    final start = info.packStart(firstPack + k);
    final size = info.packSizes[firstPack + k];
    if (start + size > b.length) _bad('packed stream past the end');
    return Uint8List.sublistView(b, start, start + size);
  }

  // The coder that owns out stream [out], and its first in stream.
  (int, int) owner(int out) {
    var o = 0, i = 0;
    for (var c = 0; c < f.coders.length; c++) {
      if (out < o + f.coders[c].outs) return (c, i);
      o += f.coders[c].outs;
      i += f.coders[c].ins;
    }
    _bad('bad out stream $out');
  }

  late Uint8List Function(int) output;

  Uint8List input(int inIndex) {
    final bound = f.bindIn.indexOf(inIndex);
    if (bound >= 0) return output(f.bindOut[bound]);
    final p = f.packed.indexOf(inIndex);
    if (p < 0) _bad('unbound in stream $inIndex');
    return packedStream(p);
  }

  output = (int out) => cache[out] ??= () {
    final (c, firstIn) = owner(out);
    final coder = f.coders[c];
    if (coder.ins != 1 || coder.outs != 1) {
      throw ContentException('unsupported 7z coder ${_hex(coder.id)} (BCJ2): repack with BCJ or no filter');
    }
    return _run(coder, input(firstIn), f.unpackSizes[out], password, budget);
  }();

  final data = output(f.mainOut);
  final crc = f.crc;
  if (crc != null && info.subCounts.length > index && info.subCounts[index] != 1 && crc32(data) != crc) {
    throw password == null
        ? ContentException('corrupt archive: 7z folder CRC')
        : PasswordException('wrong password or corrupt archive');
  }
  return data;
}

Uint8List _run(_Coder c, Uint8List input, int size, String? password, Budget budget) {
  final id = _hex(c.id);
  switch (id) {
    case '00': // copy
      if (input.length < size) _bad('stored stream is short');
      return input.length == size ? input : Uint8List.sublistView(input, 0, size);
    case '030101':
      return lzmaDecode(input, c.props, size);
    case '21':
      return lzma2Decode(input, size);
    case '030401':
      return ppmdDecode7z(input, c.props, size);
    case '040108': // deflate
      return inflateRaw(input, size, '7z folder');
    case '03030103': // BCJ x86
      return bcjX86(Uint8List.fromList(input));
    case '0a': // ARM64
      return bcjArm64(Uint8List.fromList(input));
    case '03': // delta
      return delta(Uint8List.fromList(input), (c.props.isEmpty ? 0 : c.props[0]) + 1);
    case '06f10701': // AES-256 + SHA-256
      if (password == null) throw const PasswordException('archive is encrypted (pass password:)');
      return _aes(input, c.props, password, size, budget);
    default:
      throw ContentException('unsupported 7z coder $id');
  }
}

Uint8List _aes(Uint8List input, Uint8List props, String password, int size, Budget budget) {
  if (props.isEmpty) _bad('AES properties');
  final b0 = props[0];
  final cycles = b0 & 0x3F;
  var salt = Uint8List(0), iv = Uint8List(16);
  if (b0 & 0xC0 != 0) {
    if (props.length < 2) _bad('AES properties');
    final saltSize = (b0 >> 7 & 1) + (props[1] >> 4);
    final ivSize = (b0 >> 6 & 1) + (props[1] & 0x0F);
    if (2 + saltSize + ivSize > props.length) _bad('AES properties');
    salt = Uint8List.sublistView(props, 2, 2 + saltSize);
    iv.setRange(0, ivSize, props, 2 + saltSize);
  }
  // 7-Zip itself refuses more than 2^24 rounds: the count comes from the
  // archive, and 2^62 would spin for millennia.
  if (cycles > 24 && cycles != 0x3F) _bad('AES key rounds 2^$cycles');
  // One key per (password, salt, rounds): a non-solid archive repeats it per
  // folder and for the header, ~100 ms each at the default 2^19.
  final id = '$cycles ${salt.join(',')} $password';
  var key = _keys.remove(id);
  if (key == null) {
    budget.kdf(cycles == 0x3F ? 0 : 1 << cycles, '7z');
    key = sevenzipKey(password, salt, cycles);
  }
  _keys[id] = key;
  if (_keys.length > 8) _keys.remove(_keys.keys.first);
  final plain = Aes(key).cbcDecrypt(input, iv);
  return size <= plain.length ? Uint8List.sublistView(plain, 0, size) : plain;
}

final _keys = <String, Uint8List>{};

/// 7z's key: SHA-256 over 2^[cycles] rounds of salt, UTF-16LE password and
/// a 64-bit round counter.
Uint8List sevenzipKey(String password, List<int> salt, int cycles) {
  final pw = Uint8List(password.length * 2);
  for (var i = 0; i < password.length; i++) {
    pw[2 * i] = password.codeUnitAt(i) & 0xFF;
    pw[2 * i + 1] = password.codeUnitAt(i) >> 8;
  }
  if (cycles == 0x3F) {
    final key = Uint8List(32);
    final both = [...salt, ...pw];
    key.setRange(0, both.length < 32 ? both.length : 32, both);
    return key;
  }
  final out = _DigestSink();
  final sink = crypto.sha256.startChunkedConversion(out);
  final unit = Uint8List(salt.length + pw.length + 8)
    ..setRange(0, salt.length, salt)
    ..setRange(salt.length, salt.length + pw.length, pw);
  final counter = salt.length + pw.length;
  final rounds = 1 << cycles;
  for (var round = 0; round < rounds; round++) {
    var v = round;
    for (var k = 0; k < 8; k++) {
      unit[counter + k] = v & 0xFF;
      v >>= 8;
    }
    sink.add(unit);
  }
  sink.close();
  return Uint8List.fromList(out.value!.bytes);
}

final class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

String _hex(List<int> id) => id.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

/// 1970-01-01 as a FILETIME.
const _epoch1601 = 116444736000000000;

final class _Bytes {
  _Bytes(this.b, this.pos);
  final Uint8List b;
  int pos;

  int peek() => pos < b.length ? b[pos] : _bad('header ends early');

  int byte() {
    if (pos >= b.length) _bad('header ends early');
    return b[pos++];
  }

  Uint8List bytes(int n) {
    if (n < 0 || pos + n > b.length) _bad('header ends early');
    final out = Uint8List.sublistView(b, pos, pos + n);
    pos += n;
    return out;
  }

  void skip(int n) => pos += n;

  int u32() {
    final v = bytes(4);
    return v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24;
  }

  int u64() => u32() + u32() * 0x100000000;

  /// 7z's variable-length number: leading 1 bits of the first byte count
  /// the extra little-endian bytes.
  int number() {
    final first = byte();
    var mask = 0x80;
    var value = 0;
    for (var i = 0; i < 8; i++) {
      if (first & mask == 0) {
        value |= (first & (mask - 1)) << (8 * i);
        break;
      }
      value |= byte() << (8 * i);
      mask >>= 1;
    }
    // No real size, count or offset reaches 2^48; a bigger (or wrapped
    // negative) one is damage.
    if (value < 0 || value > 1 << 48) _bad('number out of range');
    return value;
  }

  List<bool> bits(int n) {
    if (n > (b.length - pos) * 8) _bad('header ends early');
    final out = List.filled(n, false);
    var mask = 0, cur = 0;
    for (var i = 0; i < n; i++) {
      if (mask == 0) {
        cur = byte();
        mask = 0x80;
      }
      out[i] = cur & mask != 0;
      mask >>= 1;
    }
    return out;
  }

  List<bool> allOrBits(int n) {
    if (n > b.length * 8) _bad('$n items in a ${b.length}-byte header');
    return byte() != 0 ? List.filled(n, true) : bits(n);
  }
}

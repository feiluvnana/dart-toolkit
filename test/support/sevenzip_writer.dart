/// The Deflate 7z writer the library had before 7-Zip wrote its 7z files,
/// kept to build exact fixtures (key rounds, folder reuse) for the reader.
library;

import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_toolkit/core.dart';
import 'package:dart_toolkit/src/aes.dart';
import 'package:dart_toolkit/src/crc32.dart';
import 'package:dart_toolkit/src/sevenzip.dart' show sevenzipKey;

/// 1970-01-01 as a FILETIME.
const _epoch1601 = 116444736000000000;

/// A solid 7z of [entries] (a name ending in `/` is a folder; a [link]'s
/// data is its target): one Deflate folder (the SDK's zlib, so it is
/// fast; 7-Zip and libarchive read it). With [password] the data and the
/// header (names included) are AES-256.
Uint8List writeSevenzip(
  List<({String name, int mode, List<int> data, DateTime mtime, bool link})> entries, {
  String? password,
}) {
  final files = [
    for (final e in entries)
      (
        name: e.name.endsWith('/') ? e.name.substring(0, e.name.length - 1) : e.name,
        dir: e.name.endsWith('/'),
        mode: e.mode,
        data: e.data,
        mtime: e.mtime,
        link: e.link,
      ),
  ];
  final streams = [
    for (final f in files)
      if (!f.dir && f.data.isNotEmpty) f,
  ];
  // The SDK's one-shot deflate keeps only the low 32 bits of its input
  // length: past 4 GiB it would write a short stream without an error.
  if (streams.fold(0, (n, f) => n + f.data.length) > 0xFFFFFFFF) {
    throw const ContentException('7z over 4 GiB of data: use ArchiveFormat.tgz');
  }
  final plain = BytesBuilder(copy: false);
  for (final f in streams) {
    plain.add(f.data);
  }
  final pack = BytesBuilder(copy: false);
  final h = _Out()..byte(0x01); // header
  if (streams.isNotEmpty) {
    final raw = plain.takeBytes();
    final (packed, coders) = _encode(raw, password);
    pack.add(packed);
    h.byte(0x04); // main streams
    _writeStreams(
      h,
      packPos: 0,
      packSize: packed.length,
      coders: coders,
      unpackSizes: [raw.length, if (password != null) coders.deflated],
    );
    h
      ..byte(0x08) // substreams
      ..byte(0x0D)
      ..number(streams.length)
      ..byte(0x09);
    for (final f in streams.take(streams.length - 1)) {
      h.number(f.data.length);
    }
    h
      ..byte(0x0A)
      ..byte(1);
    for (final f in streams) {
      h.u32(crc32(f.data));
    }
    h
      ..byte(0x00)
      ..byte(0x00);
  }
  h
    ..byte(0x05) // files
    ..number(files.length);
  final empty = [for (final f in files) f.dir || f.data.isEmpty];
  if (empty.contains(true)) {
    h.property(0x0E, _bitBytes(empty));
    h.property(
      0x0F,
      _bitBytes([
        for (final f in files)
          if (f.dir || f.data.isEmpty) !f.dir,
      ]),
    );
  }
  final names = _Out()..byte(0);
  for (final f in files) {
    for (final c in f.name.codeUnits) {
      names
        ..byte(c & 0xFF)
        ..byte(c >> 8);
    }
    names
      ..byte(0)
      ..byte(0);
  }
  h.property(0x11, names.bytes());
  final times = _Out()
    ..byte(1)
    ..byte(0);
  for (final f in files) {
    times.u64(f.mtime.microsecondsSinceEpoch * 10 + _epoch1601);
  }
  h.property(0x14, times.bytes());
  final attrs = _Out()
    ..byte(1)
    ..byte(0);
  for (final f in files) {
    final unix = (f.dir ? 0x4000 : (f.link ? 0xA000 : 0x8000)) | (f.mode & 0xFFF);
    attrs.u32(unix << 16 | 0x8000 | (f.dir ? 0x10 : 0x20));
  }
  h
    ..property(0x15, attrs.bytes())
    ..byte(0x00) // end of files
    ..byte(0x00); // end of header
  var header = h.bytes();
  if (password != null) {
    // An encoded header: the header itself, AES-encrypted after the data.
    final (packed, coders) = _encode(header, password, compress: false);
    final encoded = _Out()..byte(0x17);
    _writeStreams(encoded, packPos: pack.length, packSize: packed.length, coders: coders, unpackSizes: [header.length]);
    encoded.byte(0x00);
    pack.add(packed);
    header = encoded.bytes();
  }
  final body = pack.takeBytes();
  final start = ByteData(20)
    ..setUint32(0, body.length, Endian.little)
    ..setUint32(8, header.length, Endian.little)
    ..setUint32(16, crc32(header), Endian.little);
  final startBytes = start.buffer.asUint8List();
  final out = BytesBuilder(copy: false)
    ..add(const [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4])
    ..add((ByteData(4)..setUint32(0, crc32(startBytes), Endian.little)).buffer.asUint8List())
    ..add(startBytes)
    ..add(body)
    ..add(header);
  return out.takeBytes();
}

typedef _Coders = ({List<(List<int>, Uint8List)> list, int deflated});

/// [data] deflated (unless [compress] is false) then AES-encrypted with
/// [password]; the coders in 7z's order (the final output first).
(Uint8List, _Coders) _encode(Uint8List data, String? password, {bool compress = true}) {
  var packed = data;
  final coders = <(List<int>, Uint8List)>[];
  if (compress) {
    final d = io.ZLibEncoder(raw: true, level: 6).convert(data);
    packed = d is Uint8List ? d : Uint8List.fromList(d);
    coders.add((const [0x04, 0x01, 0x08], Uint8List(0)));
  }
  final deflated = packed.length;
  if (password != null) {
    const cycles = 19;
    final iv = Uint8List.fromList(List.generate(16, (_) => _random.nextInt(256)));
    final padded = Uint8List((packed.length + 15) & ~15)..setRange(0, packed.length, packed);
    packed = Aes(sevenzipKey(password, const [], cycles)).cbcEncrypt(padded, iv);
    coders.add((const [0x06, 0xF1, 0x07, 0x01], Uint8List.fromList([cycles | 0x40, 0x0F, ...iv])));
  }
  if (coders.isEmpty) coders.add((const [0x00], Uint8List(0)));
  return (packed, (list: coders, deflated: deflated));
}

final _random = Random.secure();

void _writeStreams(
  _Out h, {
  required int packPos,
  required int packSize,
  required _Coders coders,
  required List<int> unpackSizes,
}) {
  final list = coders.list;
  h
    ..byte(0x06)
    ..number(packPos)
    ..number(1)
    ..byte(0x09)
    ..number(packSize)
    ..byte(0x00)
    ..byte(0x07)
    ..byte(0x0B)
    ..number(1)
    ..byte(0)
    ..number(list.length);
  for (final (id, props) in list) {
    h.byte(id.length | (props.isEmpty ? 0 : 0x20));
    h.raw(id);
    if (props.isNotEmpty) {
      h
        ..number(props.length)
        ..raw(props);
    }
  }
  // Each coder after the first feeds the one before it: in k <- out k+1.
  for (var k = 0; k + 1 < list.length; k++) {
    h
      ..number(k)
      ..number(k + 1);
  }
  h.byte(0x0C);
  for (final s in unpackSizes) {
    h.number(s);
  }
  h.byte(0x00); // end of coders info; the caller ends the streams info
}

Uint8List _bitBytes(List<bool> bits) {
  final out = Uint8List((bits.length + 7) >> 3);
  for (var i = 0; i < bits.length; i++) {
    if (bits[i]) out[i >> 3] |= 0x80 >> (i & 7);
  }
  return out;
}

final class _Out {
  final _b = BytesBuilder(copy: false);

  void byte(int v) => _b.addByte(v);
  void raw(List<int> v) => _b.add(v);

  void u32(int v) => _b.add([v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF]);

  void u64(int v) => _b.add([for (var k = 0; k < 8; k++) v >> (8 * k) & 0xFF]);

  /// 7z's variable-length number.
  void number(int v) {
    var n = 0;
    while (n < 8 && v >= 1 << (7 * (n + 1))) {
      n++;
    }
    if (n == 8 || v >= 1 << 56) {
      byte(0xFF);
      for (var k = 0; k < 8; k++) {
        byte(v >> (8 * k) & 0xFF);
      }
      return;
    }
    final high = v >> (8 * n);
    byte((0xFF00 >> n) & 0xFF | high);
    for (var k = 0; k < n; k++) {
      byte(v >> (8 * k) & 0xFF);
    }
  }

  void property(int id, List<int> data) {
    byte(id);
    number(data.length);
    raw(data);
  }

  Uint8List bytes() => _b.takeBytes();
}

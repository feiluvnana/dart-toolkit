/// CRC-32 (IEEE 802.3), as zip, 7z, gzip and RAR use.
library;

import 'dart:typed_data';

/// The CRC-32 of [data] (or of [start]..[end]), continuing from [crc].
/// A [Uint8List] goes 8 bytes a step (slicing-by-8).
int crc32(List<int> data, {int crc = 0, int start = 0, int? end}) {
  var c = crc ^ 0xFFFFFFFF;
  final stop = end ?? data.length;
  var i = start;
  if (data is Uint8List) {
    final t = _slices;
    for (; i + 8 <= stop; i += 8) {
      final a = c ^ (data[i] | data[i + 1] << 8 | data[i + 2] << 16 | data[i + 3] << 24);
      c =
          t[0x700 + (a & 0xFF)] ^
          t[0x600 + (a >> 8 & 0xFF)] ^
          t[0x500 + (a >> 16 & 0xFF)] ^
          t[0x400 + (a >> 24)] ^
          t[0x300 + data[i + 4]] ^
          t[0x200 + data[i + 5]] ^
          t[0x100 + data[i + 6]] ^
          t[data[i + 7]];
    }
  }
  for (; i < stop; i++) {
    c = crcTable[(c ^ data[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// The byte-wise table; ZipCrypto's key schedule steps it directly.
final crcTable = Uint32List.fromList(
  List.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  }),
);

/// Eight tables: slice k advances a byte through k more zero bytes.
final _slices = () {
  final t = Uint32List(0x800)..setRange(0, 256, crcTable);
  for (var k = 1; k < 8; k++) {
    for (var n = 0; n < 256; n++) {
      final prev = t[(k - 1) * 256 + n];
      t[k * 256 + n] = crcTable[prev & 0xFF] ^ (prev >> 8);
    }
  }
  return t;
}();

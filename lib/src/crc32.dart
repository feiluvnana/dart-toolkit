/// CRC-32 (IEEE 802.3), as zip, 7z, gzip and RAR use.
library;

import 'dart:typed_data';

/// The CRC-32 of [data] (or of [start]..[end]), continuing from [crc].
int crc32(List<int> data, {int crc = 0, int start = 0, int? end}) {
  var c = crc ^ 0xFFFFFFFF;
  final stop = end ?? data.length;
  for (var i = start; i < stop; i++) {
    c = crcTable[(c ^ data[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// The byte-wise table; ZipCrypto's key schedule steps it directly.
final crcTable = Uint32List.fromList(List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
}));

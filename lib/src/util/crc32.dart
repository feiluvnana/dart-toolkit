part of '../../util.dart';

/// A running CRC-32 (IEEE), as zip and PNG use it.
///
/// {@category Utilities}
final class Crc32 {
  static final Uint32List _table = () {
    final table = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      }
      table[n] = c;
    }
    return table;
  }();

  int _state = 0xFFFFFFFF;

  /// Bytes seen so far.
  int length = 0;

  /// Folds [data] into the checksum.
  void add(List<int> data) {
    var c = _state;
    final table = _table;
    for (var i = 0; i < data.length; i++) {
      c = table[(c ^ data[i]) & 0xff] ^ (c >>> 8);
    }
    _state = c;
    length += data.length;
  }

  /// The checksum of everything added so far.
  int get value => (_state ^ 0xFFFFFFFF) & 0xFFFFFFFF;

  /// The checksum of [data] in one go.
  static int of(List<int> data) => (Crc32()..add(data)).value;
}

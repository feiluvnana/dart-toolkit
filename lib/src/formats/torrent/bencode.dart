part of '../../../torrent.dart';

/// Bencode (BEP 3), the encoding a `.torrent` is made of. One Dart type per bencode type: an
/// [int], a byte string as a [Uint8List] (decode it with `utf8.decode` when it is text), a
/// `List<Object>` and a `Map<String, Object>` (keys are text in every torrent).
///
/// ```dart
/// Bencode.decode(ascii.encode('d3:fooi42ee'));   // {'foo': 42}
/// Bencode.encode({'a': 1, 'b': 'text'});          // d1:ai1e1:b4:texte
/// ```
///
/// {@category Formats}
abstract final class Bencode {
  /// How deep lists and dictionaries may nest: an untrusted file nested deeper is refused, never
  /// a stack overflow.
  static const maxDepth = 256;

  /// [bytes] decoded; malformed input, trailing bytes, an integer past 64 bits and nesting past
  /// [maxDepth] are a [FormatException] with the byte offset.
  static Object decode(List<int> bytes) {
    final decoder = _BencodeDecoder(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    final result = decoder.value(0);
    if (decoder.offset < decoder.bytes.length) decoder._fail('trailing bytes');
    return result;
  }

  /// [value] as bytes: an [int]; a [String] (as UTF-8) or a [Uint8List] as a byte string; a
  /// [List] (any other `List<int>` too) as a list; a [Map] with [String] keys as a dictionary,
  /// its keys sorted by their bytes. Anything else is an [ArgumentError].
  static Uint8List encode(Object value) {
    final out = BytesBuilder(copy: false);
    _encode(value, out, 0);
    return out.takeBytes();
  }
}

void _encode(Object? value, BytesBuilder out, int depth) {
  // As deep as [Bencode.decode] reads back: a list or dictionary at most [Bencode.maxDepth] down.
  if (depth >= Bencode.maxDepth && value is! Uint8List && (value is List || value is Map)) {
    throw ArgumentError.value(value, 'value', 'Invalid bencode: nested past ${Bencode.maxDepth}');
  }
  void bytes(List<int> b) => out
    ..add(ascii.encode('${b.length}'))
    ..addByte(0x3A)
    ..add(b);
  switch (value) {
    case int():
      out
        ..addByte(0x69)
        ..add(ascii.encode('$value'))
        ..addByte(0x65);
    case String():
      bytes(utf8.encode(value));
    case Uint8List():
      bytes(value);
    case List():
      out.addByte(0x6C);
      for (final item in value) {
        _encode(item, out, depth + 1);
      }
      out.addByte(0x65);
    case Map():
      final entries = [
        for (final MapEntry(:key, :value) in value.entries)
          if (key is String)
            (utf8.encode(key), value)
          else
            throw ArgumentError.value(key, 'value', 'Invalid bencode key, expected a String'),
      ]..sort((a, b) => _compareBytes(a.$1, b.$1));
      out.addByte(0x64);
      for (final (key, item) in entries) {
        bytes(key);
        _encode(item, out, depth + 1);
      }
      out.addByte(0x65);
    case _:
      throw ArgumentError.value(value, 'value', 'Invalid bencode value: a ${value.runtimeType}');
  }
}

int _compareBytes(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

final class _BencodeDecoder {
  final Uint8List bytes;
  int offset = 0;

  /// Where the root dictionary's `info` value starts and ends: the bytes the info hash is of.
  (int, int)? info;

  _BencodeDecoder(this.bytes);

  Never _fail(String why, [int? at]) {
    final pos = at ?? offset;
    throw FormatException('Invalid bencode at offset $pos: $why', bytes, pos);
  }

  Object value(int depth) {
    if (offset >= bytes.length) _fail('unexpected end of input');
    final byte = bytes[offset];
    if (byte >= 0x30 && byte <= 0x39) return _string();
    if (byte == 0x69) return _integer();
    if (byte != 0x6C && byte != 0x64) _fail('unexpected byte 0x${byte.toRadixString(16)}');
    if (depth >= Bencode.maxDepth) _fail('nested past ${Bencode.maxDepth}');
    return byte == 0x6C ? _list(depth) : _dictionary(depth);
  }

  int _integer() {
    final start = offset++;
    final negative = offset < bytes.length && bytes[offset] == 0x2D;
    if (negative) offset++;
    final digits = offset;
    while (offset < bytes.length && bytes[offset] >= 0x30 && bytes[offset] <= 0x39) {
      offset++;
    }
    if (offset == digits) _fail('empty integer', start);
    if (offset >= bytes.length || bytes[offset] != 0x65) _fail('unterminated integer, expected "e"', start);
    if (bytes[digits] == 0x30 && (offset - digits > 1 || negative)) _fail('leading zero or negative zero', start);
    final text = ascii.decode(Uint8List.sublistView(bytes, start + 1, offset));
    offset++;
    return int.tryParse(text) ?? _fail('integer past 64 bits', start);
  }

  Uint8List _string() {
    final start = offset;
    while (offset < bytes.length && bytes[offset] >= 0x30 && bytes[offset] <= 0x39) {
      offset++;
    }
    if (offset - start > 1 && bytes[start] == 0x30) _fail('leading zero in a string length', start);
    if (offset >= bytes.length || bytes[offset] != 0x3A) _fail('expected ":" after a string length', start);
    final length = int.tryParse(ascii.decode(Uint8List.sublistView(bytes, start, offset)));
    offset++;
    if (length == null || length > bytes.length - offset) _fail('string length past the end of input', start);
    return Uint8List.sublistView(bytes, offset, offset += length);
  }

  List<Object> _list(int depth) {
    final start = offset++;
    final list = <Object>[];
    while (offset < bytes.length && bytes[offset] != 0x65) {
      list.add(value(depth + 1));
    }
    if (offset >= bytes.length) _fail('unterminated list, expected "e"', start);
    offset++;
    return list;
  }

  Map<String, Object> _dictionary(int depth) {
    final start = offset++;
    final map = <String, Object>{};
    while (offset < bytes.length && bytes[offset] != 0x65) {
      if (bytes[offset] < 0x30 || bytes[offset] > 0x39) _fail('a dictionary key must be a byte string');
      final key = utf8.decode(_string(), allowMalformed: true);
      final at = offset;
      map[key] = value(depth + 1);
      if (depth == 0 && key == 'info') info = (at, offset);
    }
    if (offset >= bytes.length) _fail('unterminated dictionary, expected "e"', start);
    offset++;
    return map;
  }
}

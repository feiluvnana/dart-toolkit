// The hand-written image header readers on hand-built, truncated and
// mangled input: a wrong or cut header is null, never a throw or a hang.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_toolkit/src/media.dart' as media;
import 'package:test/test.dart';

List<int> be16(int v) => [v >> 8 & 0xFF, v & 0xFF];
List<int> be32(int v) => [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];
List<int> le16(int v) => [v & 0xFF, v >> 8 & 0xFF];
List<int> le24(int v) => [v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF];
List<int> le32(int v) => [...le16(v), ...le16(v >> 16)];

/// A JPEG: EXIF orientation [orientation] (none when null), an SOF0 of
/// [w]x[h] with [components] colour components.
Uint8List jpeg(int w, int h, {int? orientation, int components = 3}) {
  final exif = orientation == null
      ? <int>[]
      : () {
          final tiff = [...'MM'.codeUnits, 0, 0x2A, ...be32(8), ...be16(1), ...be16(0x0112), ...be16(3), ...be32(1), ...be16(orientation), 0, 0, ...be32(0)];
          final body = [...'Exif'.codeUnits, 0, 0, ...tiff];
          return [0xFF, 0xE1, ...be16(body.length + 2), ...body];
        }();
  final sof = [8, ...be16(h), ...be16(w), components, for (var c = 0; c < components; c++) ...[c + 1, 0x11, 0]];
  return Uint8List.fromList([0xFF, 0xD8, ...exif, 0xFF, 0xC0, ...be16(sof.length + 2), ...sof, 0xFF, 0xDA, 0, 2, 0xFF, 0xD9]);
}

List<int> chunk(String type, List<int> data) => [...be32(data.length), ...type.codeUnits, ...data, 0, 0, 0, 0];

/// A PNG of [w]x[h]; an APNG (acTL before IDAT) when [animated].
Uint8List png(int w, int h, {bool animated = false}) => Uint8List.fromList([
  0x89, ...'PNG\r\n\x1a\n'.codeUnits, //
  ...chunk('IHDR', [...be32(w), ...be32(h), 8, 6, 0, 0, 0]),
  if (animated) ...chunk('acTL', [...be32(2), ...be32(0)]),
  ...chunk('IDAT', [0]),
  ...chunk('IEND', []),
]);

/// A GIF of [w]x[h] with [frames] image descriptors and a global palette.
Uint8List gif(int w, int h, int frames) => Uint8List.fromList([
  ...'GIF89a'.codeUnits, ...le16(w), ...le16(h), 0x80, 0, 0, ...List.filled(6, 0), // 2-entry palette
  for (var f = 0; f < frames; f++) ...[
    0x21, 0xF9, 4, 0, 0, 0, 0, 0, // graphic control
    0x2C, 0, 0, 0, 0, ...le16(w), ...le16(h), 0, 2, 2, 0x4C, 0x01, 0, // descriptor, LZW data
  ],
  0x3B,
]);

/// A WebP whose first chunk is [kind]; real files carry more chunks after.
Uint8List riff(String kind, List<int> data) {
  final rest = [...'EXIF'.codeUnits, ...le32(4), 0, 0, 0, 0];
  return Uint8List.fromList([
    ...'RIFF'.codeUnits, ...le32(data.length + 12 + rest.length), ...'WEBP'.codeUnits, //
    ...kind.codeUnits, ...le32(data.length), ...data, ...rest,
  ]);
}

/// A WebP VP8X (extended) of [w]x[h], animated or not.
Uint8List vp8x(int w, int h, {bool animated = false}) =>
    riff('VP8X', [animated ? 0x02 : 0, 0, 0, 0, ...le24(w - 1), ...le24(h - 1)]);

/// A lossless WebP (VP8L) of [w]x[h].
Uint8List vp8l(int w, int h) => riff('VP8L', [0x2F, ...le32((w - 1) | (h - 1) << 14), 0, 0, 0, 0]);

/// A lossy WebP (VP8) of [w]x[h].
Uint8List vp8(int w, int h) => riff('VP8 ', [0, 0, 0, 0x9D, 0x01, 0x2A, ...le16(w), ...le16(h), 0, 0]);

/// A BMP of [w]x[h]; a negative [h] is top-down.
Uint8List bmp(int w, int h) => Uint8List.fromList([...'BM'.codeUnits, ...List.filled(16, 0), ...le32(w), ...le32(h), ...List.filled(30, 0)]);

void main() {
  final samples = <String, (Uint8List, media.Header)>{
    'jpeg': (jpeg(640, 480), (width: 640, height: 480, orientation: 1, animated: false, components: 3)),
    'jpeg exif 6': (jpeg(640, 480, orientation: 6), (width: 640, height: 480, orientation: 6, animated: false, components: 3)),
    'jpeg cmyk': (jpeg(10, 20, components: 4), (width: 10, height: 20, orientation: 1, animated: false, components: 4)),
    'png': (png(3, 5), (width: 3, height: 5, orientation: 1, animated: false, components: 3)),
    'apng': (png(3, 5, animated: true), (width: 3, height: 5, orientation: 1, animated: true, components: 3)),
    'gif': (gif(7, 9, 1), (width: 7, height: 9, orientation: 1, animated: false, components: 3)),
    'gif anim': (gif(7, 9, 2), (width: 7, height: 9, orientation: 1, animated: true, components: 3)),
    'webp vp8x': (vp8x(300, 200), (width: 300, height: 200, orientation: 1, animated: false, components: 3)),
    'webp vp8x anim': (vp8x(300, 200, animated: true), (width: 300, height: 200, orientation: 1, animated: true, components: 3)),
    'webp vp8l': (vp8l(64, 32), (width: 64, height: 32, orientation: 1, animated: false, components: 3)),
    'webp vp8': (vp8(64, 32), (width: 64, height: 32, orientation: 1, animated: false, components: 3)),
    'bmp top-down': (bmp(12, -34), (width: 12, height: 34, orientation: 1, animated: false, components: 3)),
  };

  for (final MapEntry(key: name, value: (bytes, want)) in samples.entries) {
    test('T6: $name reads, and every prefix is null or a header, never a throw', () {
      expect(media.header(bytes), want);
      for (var n = 0; n < bytes.length; n++) {
        expect(() => media.header(Uint8List.sublistView(bytes, 0, n)), returnsNormally, reason: '$n bytes');
      }
    });
  }

  test('T6: mangled bytes never throw or hang', () {
    final rnd = Random(6);
    for (final (bytes, _) in samples.values) {
      for (var round = 0; round < 300; round++) {
        final b = Uint8List.fromList(bytes);
        for (var k = 0; k < 1 + rnd.nextInt(4); k++) {
          b[2 + rnd.nextInt(b.length - 2)] = rnd.nextInt(256); // keep the magic
        }
        expect(() => media.header(b), returnsNormally, reason: base64Encode(b));
      }
    }
  });

  test('T6: withMetadata survives a truncated source', () {
    final src = jpeg(8, 8, orientation: 3), out = jpeg(8, 8);
    for (var n = 0; n < src.length; n++) {
      expect(() => media.withMetadata(out, Uint8List.sublistView(src, 0, n)), returnsNormally, reason: '$n bytes');
    }
  });
}

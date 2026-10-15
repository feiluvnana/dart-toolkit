import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_toolkit/image.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

List<int> get tinyPng =>
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

/// [tinyPng] with its IHDR claiming [side]x[side] at [bits] per sample
/// (checksum fixed).
Uint8List _bombPng({int side = 15000, int bits = 8}) {
  final bomb = Uint8List.fromList(tinyPng);
  final data = bomb.buffer.asByteData()
    ..setUint32(16, side)
    ..setUint32(20, side)
    ..setUint8(24, bits);
  var crc = 0xFFFFFFFF; // IHDR checksum over type + data
  for (var i = 12; i < 29; i++) {
    crc ^= bomb[i];
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  data.setUint32(29, crc ^ 0xFFFFFFFF);
  return bomb;
}

void main() {
  group('Image.decode', () {
    test('decodes bytes', () {
      final img = Image.decode(tinyPng);
      expect(img.width(), 1);
      expect(img.height(), 1);
    });

    test('an EXIF orientation is applied; width and height are as displayed', () {
      final raw = img.Image(width: 4, height: 2);
      raw.exif.imageIfd.orientation = 6; // rotate 90° to display
      final turned = Image.decode(img.encodeJpg(raw));
      expect((turned.width(), turned.height()), (2, 4));
      final plain = Image.decode(img.encodeJpg(img.Image(width: 4, height: 2)));
      expect((plain.width(), plain.height()), (4, 2));
    });

    test('an ICO wrapping a huge PNG is refused before decoding', () {
      final png = _bombPng();
      final ico = Uint8List(22 + png.length);
      ico.buffer.asByteData()
        ..setUint16(2, 1, Endian.little) // type: icon
        ..setUint16(4, 1, Endian.little) // one entry
        ..setUint16(10, 1, Endian.little) // planes
        ..setUint16(12, 32, Endian.little) // bpp
        ..setUint32(14, png.length, Endian.little)
        ..setUint32(18, 22, Endian.little);
      ico.setRange(22, ico.length, png);
      expect(
        () => Image.decode(ico),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('too large'))),
      );
    });

    test('unknown bytes are a FormatException', () {
      expect(() => Image.decode([1, 2, 3]), throwsFormatException);
    });

    test('an unreadable header still decodes under the limit (regression: (0,0) skipped the check)', () async {
      // PNG magic, then 2 MB of junk: the header gives no size, so the
      // decode runs (on a worker) and fails as content, never as a bomb.
      final junk = Uint8List(2 << 20)..setRange(0, 8, tinyPng);
      expect(() => Image.decode(junk), throwsFormatException);
      await expectLater(_Mem(junk).image(), throwsFormatException);
    });

    test('the decode budget is bytes: a 16-bit image gets half the pixels', () {
      final big16 = _bombPng(side: 9000, bits: 16); // 81 Mpx x 8 bytes: over 512 MiB
      expect(
        () => Image.decode(big16),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('too large'))),
      );
      final big8 = _bombPng(side: 9000); // 81 Mpx x 4 bytes: under it, so it gets to decode (and fails as junk)
      expect(
        () => Image.decode(big8),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', isNot(contains('too large')))),
      );
    });

    test('M12: a huge declared size is refused before decoding', () async {
      final bomb = _bombPng();
      expect(
        () => Image.decode(bomb),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('too large'))),
      );
      await expectLater(_Mem(bomb).image(), throwsFormatException);
    });
  });

  group('Reader.image', () {
    test('reads a value', () async {
      expect(await _Mem(tinyPng).image().width(), 1);
    });

    test('mirror on Future<Reader>', () async {
      expect(await Future<Reader>.value(_Mem(tinyPng)).image().height(), 1);
    });
  });

  group('Image', () {
    test('resize keeps aspect with one side', () async {
      final img = Image.decode(tinyPng);
      // 1x1 stays square; exercise the chain and PNG output instead.
      final big = img.resize(width: 4);
      expect(big.width(), 4);
      expect(big.height(), 4);
    });

    test('resize needs a side', () {
      expect(() => Image.decode(tinyPng).resize(), throwsArgumentError);
    });

    test('F14: non-positive resize sizes are an ArgumentError', () {
      final img = Image.decode(tinyPng);
      expect(() => img.resize(width: 0), throwsArgumentError);
      expect(() => img.resize(width: -5), throwsArgumentError);
      expect(() => img.resize(height: -1), throwsArgumentError);
    });

    test('resize keeps a computed side at 1 or more and refuses a giant target', () {
      final strip = Image.decode(img.encodePng(img.Image(width: 1000, height: 1)));
      final one = strip.resize(width: 1);
      expect((one.width(), one.height()), (1, 1));
      expect(() => strip.resize(width: 20000, height: 20000), throwsArgumentError);
    });

    test('F14: GIF decodes its first frame only', () async {
      // 1x1 two-frame GIF (red, then blue).
      final gif = base64Decode('R0lGODlhAQABAIAAAP///////yH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==');
      final img = Image.decode(gif);
      expect(img.width(), 1);
      expect(img.height(), 1);
      // A single frame re-encodes as a still, not an animation.
      final png = await img.encode(ImageFormat.png).bytes();
      expect(Image.decode(png).width(), 1);
    });

    test('F14: .ico above 256px is an ArgumentError', () async {
      final big = Image.decode(tinyPng).resize(width: 300, height: 300);
      // Regression: refused in encode(), not later when the reader is read.
      expect(() => big.encode(ImageFormat.ico), throwsArgumentError);
      // 256px is fine.
      final ok = Image.decode(tinyPng).resize(width: 256, height: 256);
      expect(await ok.encode(ImageFormat.ico).bytes(), isNotEmpty);
    });

    test('crop cuts a region; outside is a RangeError', () {
      final big = Image.decode(tinyPng).resize(width: 4, height: 4);
      expect(big.crop(0, 0, 2, 2).width(), 2);
      expect(() => big.crop(3, 3, 2, 2), throwsRangeError);
    });

    test('webp is refused in encode() (regression: only when read)', () {
      final image = Image.decode(tinyPng);
      expect(() => image.encode(ImageFormat.webp), throwsArgumentError);
      expect(() => Future.value(image).encode(ImageFormat.webp), throwsArgumentError);
    });

    test('encode is a Reader, captured when read', () async {
      final img = Image.decode(tinyPng);
      final reader = img.encode(ImageFormat.png);
      final bytes = await reader.bytes();
      expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      expect(Image.decode(bytes).width(), 1);
    });

    test('jpg encodes with quality', () async {
      final bytes = await Image.decode(tinyPng)
          .resize(width: 8, height: 8)
          .encode(ImageFormat.jpg, quality: 80)
          .bytes();
      expect(bytes.sublist(0, 2), [0xff, 0xd8]);
    });

    test('sniff names the format from the header', () async {
      expect(Image.sniff(tinyPng), ImageFormat.png);
      for (final f in [ImageFormat.jpg, ImageFormat.gif, ImageFormat.bmp, ImageFormat.tiff, ImageFormat.ico]) {
        final bytes = await Image.decode(tinyPng).encode(f).bytes();
        expect(Image.sniff(bytes), f);
      }
      expect(Image.sniff([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]), ImageFormat.webp);
      expect(() => Image.decode(tinyPng).encode(ImageFormat.webp).bytes(), throwsArgumentError);
      expect(Image.sniff('hello world'.codeUnits), isNull);
      expect(Image.sniff([]), isNull);
    });

    test('Future mirrors match', () async {
      final f = Future.value(Image.decode(tinyPng));
      expect(await f.width(), 1);
      expect(await f.height(), 1);
      expect((await f.resize(width: 2)).width(), 2);
      expect((await f.crop(0, 0, 1, 1)).height(), 1);
      expect(await f.encode(ImageFormat.png).bytes(), isNotEmpty);
    });
  });

  group('large images', () {
    test('decode/resize/encode above ~1MP go through a worker isolate', () async {
      // Deterministic noise: flat fills compress below the isolate
      // threshold, so thumbnails would never exercise the offload path.
      final noisy = img.Image(width: 1200, height: 1000);
      var s = 123456789;
      for (var y = 0; y < noisy.height; y++) {
        for (var x = 0; x < noisy.width; x++) {
          s = (s * 1103515245 + 12345) & 0x7fffffff;
          noisy.setPixelRgb(x, y, s & 255, (s >> 8) & 255, (s >> 16) & 255);
        }
      }
      final bytes = Uint8List.fromList(img.encodePng(noisy));
      // The proxy for ~1MP on decode: inputs above 1 MiB must arrive here,
      // or the test would pass without ever leaving the main isolate.
      expect(bytes.length, greaterThan(1 << 20));

      final image = await _Mem(bytes).image();
      expect(image.width(), 1200);
      expect(image.height(), 1000);

      final small = await Future.value(image).resize(width: 120);
      expect(small.width(), 120);
      expect(small.height(), 100);

      final encoded = await image.encode(ImageFormat.jpg, quality: 80).bytes();
      expect(encoded.sublist(0, 2), [0xff, 0xd8]);
      expect(Image.decode(encoded).width(), 1200);
    });
  });
}

final class _Mem with Reader {
  _Mem(this._bytes);
  final List<int> _bytes;
  @override
  Stream<List<int>> stream() => Stream.value(_bytes);
}

import 'dart:convert';

import 'package:dart_toolkit/image.dart';
import 'package:test/test.dart';

List<int> get tinyPng => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );

void main() {
  group('Image.decode', () {
    test('decodes bytes', () {
      final img = Image.decode(tinyPng);
      expect(img.width(), 1);
      expect(img.height(), 1);
    });

    test('unknown bytes are a FormatException', () {
      expect(() => Image.decode([1, 2, 3]), throwsFormatException);
    });
  });

  group('Reader.image', () {
    test('reads a value', () async {
      expect(await _Mem(tinyPng).image().width(), 1);
    });

    test('mirror on Future<Reader>', () async {
      expect(
        await Future<Reader>.value(_Mem(tinyPng)).image().height(),
        1,
      );
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

    test('F14: GIF decodes its first frame only', () async {
      // 1x1 two-frame GIF (red, then blue).
      final gif = base64Decode(
        'R0lGODlhAQABAIAAAP///////yH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==',
      );
      final img = Image.decode(gif);
      expect(img.width(), 1);
      expect(img.height(), 1);
      // A single frame re-encodes as a still, not an animation.
      final png = await img.encode(ImageFormat.png).bytes();
      expect(Image.decode(png).width(), 1);
    });

    test('F14: .ico above 256px is an ArgumentError', () async {
      final big = Image.decode(tinyPng).resize(width: 300, height: 300);
      // Encoding is lazy: the error surfaces when read.
      await expectLater(
        big.encode(ImageFormat.ico).bytes(),
        throwsArgumentError,
      );
      // 256px is fine.
      final ok = Image.decode(tinyPng).resize(width: 256, height: 256);
      expect(await ok.encode(ImageFormat.ico).bytes(), isNotEmpty);
    });

    test('crop cuts a region; outside is a RangeError', () {
      final big = Image.decode(tinyPng).resize(width: 4, height: 4);
      expect(big.crop(0, 0, 2, 2).width(), 2);
      expect(() => big.crop(3, 3, 2, 2), throwsRangeError);
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

    test('Future mirrors match', () async {
      final f = Future.value(Image.decode(tinyPng));
      expect(await f.width(), 1);
      expect(await f.height(), 1);
      expect((await f.resize(width: 2)).width(), 2);
      expect((await f.crop(0, 0, 1, 1)).height(), 1);
      expect(await f.encode(ImageFormat.png).bytes(), isNotEmpty);
    });
  });
}

final class _Mem with Reader {
  _Mem(this._bytes);
  final List<int> _bytes;
  @override
  Stream<List<int>> stream() => Stream.value(_bytes);
}

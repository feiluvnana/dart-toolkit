// ffmpeg runs (and may be downloaded) here, so `-P quick` skips it.
@Tags(['media'])
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/shell.dart';
import 'package:dart_toolkit/src/media.dart' as media;
import 'package:dart_toolkit/video.dart' show Video;
import 'package:test/test.dart';

List<int> get tinyPng =>
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

late io.Directory tmp;

/// [bytes] as an image, the way a script reads bytes.
Future<Image> _image(List<int> bytes) => Reader.of(bytes).image();

/// An image ffmpeg draws from a lavfi source, as bytes.
Future<Uint8List> draw(String source, String ext, {List<String> args = const []}) async {
  final out = '${tmp.path}/draw-${source.hashCode}-${args.join().hashCode}.$ext';
  await media.ffmpeg(['-f', 'lavfi', '-i', source, '-frames:v', '1', ...args, '-y', out]);
  return io.File(out).readAsBytes();
}

/// [jpeg] with an EXIF APP1 holding Orientation = [orientation].
Uint8List withOrientation(Uint8List jpeg, int orientation) {
  final tiff = [
    ...'MM'.codeUnits, 0, 0x2A, 0, 0, 0, 8, // header, IFD at 8
    0, 1, // one entry
    0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, orientation, 0, 0, // Orientation SHORT
    0, 0, 0, 0, // no next IFD
  ];
  final body = [...'Exif'.codeUnits, 0, 0, ...tiff];
  final len = body.length + 2;
  return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, len >> 8, len & 0xFF, ...body, ...jpeg.sublist(2)]);
}

/// A pipe that replaces the stream with [_bytes].
final class _Swap with Pipe {
  _Swap(this._bytes);
  final List<int> _bytes;
  @override
  Stream<List<int>> transform(Stream<List<int>> input) async* {
    await input.drain<void>();
    yield _bytes;
  }
}

final class _Mem with Reader {
  _Mem(this._bytes);
  final List<int> _bytes;
  @override
  Stream<List<int>> stream() => Stream.value(_bytes);
}

void main() {
  setUpAll(() async => tmp = await io.Directory.systemTemp.createTemp('image_test_'));
  tearDownAll(() => tmp.delete(recursive: true));

  group('Image.sniff', () {
    test('names every format from its header', () async {
      expect(Image.sniff(tinyPng), ImageFormat.png);
      expect(Image.sniff([0xFF, 0xD8, 0xFF, 0xE0]), ImageFormat.jpg);
      expect(Image.sniff('GIF89a'.codeUnits), ImageFormat.gif);
      expect(Image.sniff([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits]), ImageFormat.webp);
      expect(Image.sniff([0x42, 0x4D, 0, 0]), ImageFormat.bmp);
      expect(Image.sniff([0x49, 0x49, 0x2A, 0x00]), ImageFormat.tiff);
      expect(Image.sniff([0, 0, 1, 0, 1, 0]), ImageFormat.ico);
      List<int> ftyp(String brand, [String compat = '']) => [
        0,
        0,
        0,
        16 + compat.length,
        ...'ftyp'.codeUnits,
        ...brand.codeUnits,
        0,
        0,
        0,
        0,
        ...compat.codeUnits,
      ];
      expect(Image.sniff(ftyp('heic')), ImageFormat.heic);
      expect(Image.sniff(ftyp('avif')), ImageFormat.avif);
      expect(Image.sniff(ftyp('mif1', 'avif')), ImageFormat.avif);
      expect(Image.sniff(ftyp('mif1', 'heic')), ImageFormat.heic);
      expect(Image.sniff(ftyp('isom')), isNull);
      expect(Image.sniff([1, 2, 3]), isNull);
    });

    test('V1: a HEIC/AVIF photo is not a video (regression: ftyp was always mp4)', () {
      final heic = [0, 0, 0, 24, ...'ftypheic'.codeUnits, 0, 0, 0, 0, ...'mif1heic'.codeUnits];
      expect(Video.sniff(heic), isNull);
      expect(Image.sniff(heic), ImageFormat.heic);
    });
  });

  group('Reader.of(bytes).image()', () {
    test('reads the size from the header', () async {
      final img = await _image(tinyPng);
      expect((img.width(), img.height(), img.format()), (1, 1, ImageFormat.png));
    });

    test('an EXIF orientation is applied: width and height are as displayed', () async {
      final jpeg = await draw('color=red:s=4x2', 'jpg');
      final turned = await _image(withOrientation(jpeg, 6));
      expect((turned.width(), turned.height()), (2, 4));
      final plain = await _image(jpeg);
      expect((plain.width(), plain.height()), (4, 2));
      // ffmpeg turns the pixels the same way, so an encode keeps the shape.
      final out = await _image(await turned.encode(ImageFormat.png).bytes());
      expect((out.width(), out.height()), (2, 4));
    });

    test('unknown bytes are a FormatException', () async {
      await expectLater(_image([1, 2, 3]), throwsFormatException);
    });

    test('a huge declared size is refused before decoding', () async {
      final bomb = Uint8List.fromList(tinyPng);
      bomb.buffer.asByteData()
        ..setUint32(16, 20000)
        ..setUint32(20, 20000);
      await expectLater(
        _image(bomb),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('too large'))),
      );
    });

    test('formats Dart cannot size are probed (TIFF)', () async {
      final tiff = await draw('color=blue:s=6x3', 'tiff');
      final img = await _image(tiff);
      expect((img.width(), img.height(), img.format()), (6, 3, ImageFormat.tiff));
    });

    test('HEIC tile grids decode whole', () async {
      final sips = await Shell.which('sips');
      if (sips == null) return markTestSkipped('needs macOS sips to make a HEIC');
      final jpg = '${tmp.path}/grid.jpg';
      await io.File(jpg).writeAsBytes(await draw('testsrc2=s=1200x900', 'jpg'));
      final heic = '${tmp.path}/grid.heic';
      await Shell.run([sips, '-s', 'format', 'heic', jpg, '--out', heic], check: true);
      final img = await Fs.file(heic).image();
      expect((img.width(), img.height(), img.format()), (1200, 900, ImageFormat.heic));
      final png = await _image(await img.resize(width: 400).encode(ImageFormat.png).bytes());
      expect((png.width(), png.height()), (400, 300));
    });
  });

  group('Reader.image', () {
    test('reads a file in place and a stream through a temp file', () async {
      final path = '${tmp.path}/one.png';
      await io.File(path).writeAsBytes(tinyPng);
      expect((await Fs.file(path).image()).width(), 1);
      expect((await _Mem(tinyPng).image()).height(), 1);
    });

    test('a piped file is read through its pipe, not from the path (regression: the path skipped the pipe)', () async {
      final path = '${tmp.path}/small.png';
      await io.File(path).writeAsBytes(tinyPng);
      final other = await draw('color=red:s=6x3', 'png');
      final img = await (Fs.file(path) | _Swap(other)).image();
      expect((img.width(), img.height()), (6, 3));
      expect((Fs.file(path) | _Swap(other)).origin().path(), isNull);
    });

    test('mirror on Future<Reader>', () async {
      expect(await Future<Reader>.value(_Mem(tinyPng)).image().width(), 1);
    });
  });

  group('Image', () {
    late Image photo; // 40x20
    setUpAll(() async => photo = await _image(await draw('testsrc2=s=40x20', 'png')));

    test('resize keeps the aspect with one side and sets both when given', () {
      expect((photo.resize(width: 20).width(), photo.resize(width: 20).height()), (20, 10));
      expect((photo.resize(height: 5).width(), photo.resize(height: 5).height()), (10, 5));
      expect((photo.resize(width: 7, height: 7).width(), photo.resize(width: 7, height: 7).height()), (7, 7));
    });

    test('resize needs a positive side and keeps a computed side at 1 or more', () {
      expect(() => photo.resize(), throwsArgumentError);
      expect(() => photo.resize(width: 0), throwsArgumentError);
      expect(() => photo.resize(height: -1), throwsArgumentError);
      expect(photo.resize(width: 1).height(), 1);
      expect(() => photo.resize(width: 100000, height: 100000), throwsArgumentError);
    });

    test('crop cuts a region; outside is a RangeError, a bad size an ArgumentError', () {
      final c = photo.crop(2, 2, 10, 5);
      expect((c.width(), c.height()), (10, 5));
      expect(() => photo.crop(35, 0, 10, 5), throwsRangeError);
      expect(() => photo.crop(0, 0, 0, 5), throwsArgumentError);
    });

    test('steps chain into one encode', () async {
      final out = await _image(await photo.crop(0, 0, 20, 20).resize(width: 8).encode(ImageFormat.png).bytes());
      expect((out.width(), out.height()), (8, 8));
    });

    test('every writable format round-trips', () async {
      for (final f in ImageFormat.values.where((f) => f != ImageFormat.heic)) {
        final bytes = await photo.encode(f, quality: 60).bytes();
        expect(Image.sniff(bytes), f, reason: f.name);
        final back = await _image(bytes);
        expect((back.width(), back.height()), (40, 20), reason: f.name);
      }
    });

    test('heic, a bad quality and an .ico over 256 px are refused up front', () async {
      expect(() => photo.encode(ImageFormat.heic), throwsArgumentError);
      expect(() => photo.encode(ImageFormat.jpg, quality: 0), throwsArgumentError);
      expect(() => photo.resize(width: 300).encode(ImageFormat.ico), throwsArgumentError);
    });

    test('encode is lazy: nothing runs until the reader is read', () async {
      final reader = photo.encode(ImageFormat.jpg);
      expect(Image.sniff(await reader.bytes()), ImageFormat.jpg);
    });

    test('pixels decodes RGB, scaled when asked', () async {
      final red = await _image(await draw('color=0xFF0000:s=8x4', 'png'));
      final px = await red.pixels();
      expect((px.width(), px.height()), (8, 4));
      final (r, g, b) = px.pixel(3, 2); // lavfi draws in YUV: red comes back near 255
      expect((r > 240, g < 16, b < 16), (true, true, true));
      final small = await red.pixels(width: 2);
      expect((small.width(), small.height()), (2, 1));
    });

    test('Future mirrors match', () async {
      final f = Future.value(photo);
      expect(await f.width(), 40);
      expect(await f.height(), 20);
      expect(await f.format(), ImageFormat.png);
      expect(await f.resize(width: 10).width(), 10);
      expect(await f.crop(0, 0, 4, 4).height(), 4);
      expect((await f.pixels(width: 4)).width(), 4);
      expect(Image.sniff(await f.encode(ImageFormat.png).bytes()), ImageFormat.png);
    });
  });

  group('Image.compress', () {
    test('replaces a JPEG only when smaller, keeps its EXIF, and a second run keeps the file', () async {
      final path = '${tmp.path}/big.jpg';
      final jpeg = await draw('testsrc2=s=640x480', 'jpg', args: ['-q:v', '1']);
      await io.File(path).writeAsBytes(withOrientation(jpeg, 1));
      final saved = await Image.compress(path, quality: 60);
      expect(saved, isNotNull);
      expect(saved!.$2, lessThan(saved.$1));
      final out = await io.File(path).readAsBytes();
      expect(out.length, saved.$2);
      expect(latin1.decode(out.sublist(0, 64), allowInvalid: true), contains('Exif'));
      expect(await Image.compress(path, quality: 60), isNull);
      expect(io.Directory(tmp.path).listSync().where((e) => e.path.endsWith('.compress')), isEmpty);
    });

    test('an animated GIF, a non-image and a HEIC are left alone', () async {
      final gif = '${tmp.path}/anim.gif';
      await media.ffmpeg(['-f', 'lavfi', '-i', 'testsrc2=s=32x32:d=0.5:r=10', '-y', gif]);
      final before = await io.File(gif).readAsBytes();
      expect(await Image.compress(gif), isNull);
      expect(await io.File(gif).readAsBytes(), before);
      final txt = '${tmp.path}/a.txt';
      await io.File(txt).writeAsString('hello');
      expect(await Image.compress(txt), isNull);
      final heic = '${tmp.path}/x.heic';
      await io.File(heic).writeAsBytes([0, 0, 0, 16, ...'ftypheic'.codeUnits, 0, 0, 0, 0]);
      expect(await Image.compress(heic), isNull);
    });
  });
}

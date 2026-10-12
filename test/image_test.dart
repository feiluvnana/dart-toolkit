import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/path.dart';
import 'package:test/test.dart';

void main() {
  group('image round-trips', () {
    test('png round-trip keeps dimensions and pixels', () async {
      final img = Image.empty(32, 24).fill(0xFF112233);
      final bytes = img.encode(format: 'png');
      expect(Image.formatOf(bytes), 'png');
      final back = Image.decode(bytes);
      expect((back.w, back.h), (32, 24));
      expect(back.rgba, img.rgba);
    });

    test('qoi round-trip keeps dimensions and pixels', () async {
      final img = Image.empty(17, 9).fill(0xFF445566);
      final bytes = img.encode(format: 'qoi');
      expect(Image.formatOf(bytes), 'qoi');
      final back = Image.decode(bytes);
      expect((back.w, back.h), (17, 9));
      expect(back.rgba, img.rgba);
    });

    test('jpeg/webp round-trip keeps dimensions when native loads', () async {
      final img = Image.empty(48, 32).fill(0xFF778899);
      for (final format in ['jpeg', 'webp']) {
        final bytes = img.encode(format: format, quality: 80);
        expect(Image.formatOf(bytes), format);
        final back = Image.decode(bytes);
        expect((back.w, back.h), (48, 32));
      }
    });

    test('unknown bytes are a FormatException', () async {
      expect(() => Image.decode([1, 2, 3, 4]), throwsFormatException);
    });

    test('blur of a solid image is solid; draw leaves pixels', () {
      final solid = Image.empty(16, 16).fill(0xFF102030);
      final blurred = solid.blur(2);
      expect(blurred.rgba, solid.rgba);
      final base = Image.empty(16, 16).fill(0xFF000000);
      final mark = Image.empty(4, 4).fill(0xFFFFFFFF);
      final composed = base.draw(mark, x: 2, y: 2);
      expect(composed.rgba, isNot(equals(base.rgba)));
      expect(composed.pixel(2, 2), isNot(equals(base.pixel(2, 2))));
      expect(composed.pixel(0, 0), equals(base.pixel(0, 0)));
    });

    test('crop(x, y, w, h) cuts the region', () {
      final img = Image.empty(4, 4).fill(0xFF102030);
      final cut = img.crop(1, 1, 2, 2);
      expect((cut.w, cut.h), (2, 2));
      expect(cut.pixel(0, 0), img.pixel(1, 1));
    });

    test('crop outside the bounds clips to transparent', () {
      final img = Image.empty(4, 4).fill(0xFF102030);
      final cut = img.crop(-1, -1, 3, 3);
      expect((cut.w, cut.h), (3, 3));
      expect(cut.pixel(0, 0), 0x00000000);
      expect(cut.pixel(1, 1), img.pixel(0, 0));
    });
  });

  group('image quality', () {
    test('webp quality moves bytes; png ignores it', () async {
      // Gradient: quality has something to chew on.
      final rgba = Uint8List(64 * 64 * 4);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final i = (y * 64 + x) * 4;
          rgba[i] = (x * 4) & 0xFF;
          rgba[i + 1] = (y * 4) & 0xFF;
          rgba[i + 2] = 128;
          rgba[i + 3] = 255;
        }
      }
      final img = Image.fromRgba(rgba, 64, 64);
      final loose = img.encode(format: 'webp', quality: 10);
      final fine = img.encode(format: 'webp', quality: 95);
      expect(loose.length, lessThan(fine.length));
      expect(Image.formatOf(loose), 'webp');
      final pngDefault = img.encode(format: 'png');
      final pngQuality = img.encode(format: 'png', quality: 10);
      expect(pngQuality, orderedEquals(pngDefault));
    });
  });

  group('image readings', () {
    test('fill leaves the receiver unchanged', () {
      final img = Image.empty(4, 4);
      final filled = img.fill(0xFFFFFFFF);
      expect(img.pixel(0, 0), 0x00000000);
      expect(filled.pixel(0, 0), 0xFFFFFFFF);
    });

    test('File image fit save round-trips as webp', () async {
      final dir = await Dir.temp();
      try {
        final src = dir.file('photo.png');
        await Image.empty(100, 50).fill(0xFF112233).encode(format: 'png').pipe(src);
        final out = dir.file('thumb.webp');
        await src.image().fit(8, 8).save(out);
        expect(Image.formatOf(await out.bytes()), 'webp');
        final back = await out.image();
        expect((back.w, back.h), (8, 4));
      } finally {
        await dir.drop();
      }
    });

    test('Http.get(u).image() decodes a served png', () async {
      final png = Image.empty(20, 12).fill(0xFF334455).encode(format: 'png');
      final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
      try {
        server.listen((request) async {
          request.response.headers.contentType = io.ContentType('image', 'png');
          request.response.contentLength = png.length;
          request.response.add(png);
          await request.response.close();
        });
        final url = 'http://${server.address.host}:${server.port}/x.png';
        final img = await Http.get(url).image();
        expect((img.w, img.h), (20, 12));
      } finally {
        await server.close(force: true);
      }
    });
  });
}

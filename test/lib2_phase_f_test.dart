// Phase F polish gate (reports/roadmap.md): tar.zst pack/unpack, BarGlyphs
// presets on both bars, the half-block picture widget, and the webp quality
// knob (with PNG ignoring quality, documented).
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/tui.dart';
import 'package:test/test.dart';

void main() {
  group('compressed tars', () {
    late io.Directory tmp;
    setUp(() async {
      tmp = await io.Directory.systemTemp.createTemp('lib2_phasef_tars_');
      await io.Directory('${tmp.path}/d/sub').create(recursive: true);
      await io.File('${tmp.path}/d/a.txt').writeAsString('hello tar');
      await io.File('${tmp.path}/d/sub/b.bin').writeAsBytes(List.generate(20000, (i) => i & 0xFF));
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    for (final ext in ['tar.zst', 'tzst', 'tar.xz', 'txz', 'tar.bz2', 'tbz2']) {
      test('unpack(pack(d)) == d for .$ext', () async {
        final bundle = '${tmp.path}/b.$ext';
        final out = '${tmp.path}/out-$ext';
        await Archive.pack('${tmp.path}/d', bundle);
        expect(await Archive.list(bundle), containsAll(['a.txt', 'sub/b.bin']));
        await Archive.unpack(bundle, out);
        expect(await io.File('$out/a.txt').readAsString(), 'hello tar');
        expect(await io.File('$out/sub/b.bin').readAsBytes(), List.generate(20000, (i) => i & 0xFF));
      });
    }
  });

  group('BarGlyphs', () {
    test('presets draw the fraction', () {
      expect(BarGlyphs.blocks.draw(0.5, 4), '██░░');
      expect(BarGlyphs.ascii.draw(0.5, 4), '##--');
      expect(BarGlyphs.arrow.draw(0.5, 4), '==>-');
      expect(BarGlyphs.blocks.draw(0.0, 3), '░░░');
      expect(BarGlyphs.blocks.draw(1.0, 3), '███');
    });

    test('canvas bar honors glyphs', () {
      final term = FakeTerminal(width: 30, height: 4);
      term.draw((ui) => ui.bar(val: 1, max: 2, label: 'L', glyphs: BarGlyphs.ascii));
      expect(term.snapshot[0], contains('#'));
      expect(term.snapshot[0], isNot(contains('█')));
    });

    test('Cli bar honors glyphs', () {
      final bar = Cli.bar(total: 4, glyphs: BarGlyphs.ascii);
      bar.set(2);
      expect(bar.value, 2);
      bar.done();
    });
  });

  group('picture', () {
    // 4×2 red/green/blue/white checker, opaque.
    Uint8List frame() => Uint8List.fromList([
      255,
      0,
      0,
      255,
      0,
      255,
      0,
      255,
      0,
      0,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      0,
      0,
      255,
      255,
      0,
      255,
      0,
      255,
      255,
      0,
      0,
      255,
    ]);

    test('half-blocks paint two rows a cell', () {
      final term = FakeTerminal(width: 10, height: 4);
      term.draw((ui) => ui.picture([frame()], width: 4, height: 2));
      expect(term.snapshot[0], contains('▀'));
      expect(term.snapshot.length, 4);
    });

    test('bad frames are ArgumentErrors', () {
      final term = FakeTerminal(width: 10, height: 4);
      expect(() => term.draw((ui) => ui.picture([], width: 4, height: 2)), throwsArgumentError);
      expect(() => term.draw((ui) => ui.picture([Uint8List(3)], width: 4, height: 2)), throwsArgumentError);
    });
  });

  group('image quality', () {
    test('webp quality moves bytes; png ignores it', () async {
      // Gradient: quality has something to chew on.
      final img = Image.blank(width: 64, height: 64);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final i = (y * 64 + x) * 4;
          img.bytes[i] = (x * 4) & 0xFF;
          img.bytes[i + 1] = (y * 4) & 0xFF;
          img.bytes[i + 2] = 128;
          img.bytes[i + 3] = 255;
        }
      }
      final loose = img.encode(format: 'webp', quality: 10);
      final fine = img.encode(format: 'webp', quality: 95);
      expect(loose.length, lessThan(fine.length));
      expect(Image.formatOf(loose), 'webp');
      final pngDefault = img.encode(format: 'png');
      final pngQuality = img.encode(format: 'png', quality: 10);
      expect(pngQuality, orderedEquals(pngDefault));
    });
  });
}

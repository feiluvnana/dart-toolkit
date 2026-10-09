import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_toolkit/image.dart';
import 'package:test/test.dart' hide Retry;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('tk_image_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String at(String name) => '${tmp.path}/$name';
  Future<String> write(String name, List<int> bytes) async => (await File(at(name)).writeAsBytes(bytes)).path;
  List<String> names() => [for (final e in tmp.listSync()) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)]..sort();

  group('Image', () {
    test('blank has its size and colour, and prints them', () async {
      final img = Image.blank(width: 100, height: 50, color: Rgba.red);
      expect((img.width, img.height), (100, 50));
      expect(img.dominantColor, Rgba(255, 0, 0));
      expect('$img', 'Image(100×50)');
      await img.close();
      expect('$img', 'Image(closed)');
    });

    test('a closed image is a StateError; closing twice does nothing', () async {
      final img = Image.blank(width: 20, height: 20);
      await img.close();
      await img.close();
      expect(() => img.grayscale(), throwsStateError);
      expect(() => img.encode(ImageFormat.png), throwsStateError);
    });

    test('close waits for an encode and a save under way (X-11, IMG-12)', () async {
      // Past the 4 MiB inline limit, so both run on a worker that holds the handle.
      final img = Image.blank(width: 1100, height: 1000, color: Rgba.red);
      final bytes = img.encode(ImageFormat.png);
      final saved = img.save(at('big.png'));
      await img.close();
      expect((await Image.decode(await bytes)).width, 1100);
      expect((await Image.read(await saved)).height, 1000);
    });

    test('read and decode round-trip PNG, JPEG and WebP', () async {
      final img = await _photo(64, 32);
      for (final f in [ImageFormat.png, ImageFormat.jpeg, ImageFormat.webp]) {
        final back = await Image.decode(await img.encode(f));
        expect((back.width, back.height), (64, 32), reason: f.name);
      }
      final lossless = await Image.decode(await img.encode(ImageFormat.png));
      expect(_rgb(await lossless.encode(ImageFormat.bmp)), _rgb(await img.encode(ImageFormat.bmp)));
      final webp = await Image.decode(await img.encode(ImageFormat.webp, quality: Quality.lossless));
      expect(_rgb(await webp.encode(ImageFormat.bmp)), _rgb(await img.encode(ImageFormat.bmp)));
    });

    test('maxSide decodes no side longer, a JPEG scaled while decoding', () async {
      final img = await _photo(800, 400);
      final jpeg = await write('a.jpg', await img.encode(ImageFormat.jpeg));
      final small = await Image.read(jpeg, maxSide: 200);
      expect((small.width, small.height), (200, 100));
      final png = await Image.decode(await img.encode(ImageFormat.png), maxSide: 100);
      expect((png.width, png.height), (100, 50));
      expect(() => Image.read(jpeg, maxSide: 0), throwsArgumentError);
    });

    test('a missing file, bytes that are no image and a format this does not read', () async {
      await expectLater(Image.read(at('none.jpg')), throwsA(isA<PathNotFoundException>()));
      await expectLater(Image.decode(utf8.encode('not an image')), throwsFormatException);
      final text = await write('a.txt', utf8.encode('hello'));
      await expectLater(Image.read(text), throwsFormatException);
    });

    test('a file is read by its content, whatever its extension says', () async {
      final png = await write('really-png.jpg', await (await _photo(16, 8)).encode(ImageFormat.png));
      expect((await Image.read(png)).width, 16);
      expect((await ImageInfo.read(png)).format, ImageFormat.png);
    });

    test('read turns a photo upright by its EXIF orientation (IMG-13)', () async {
      final plain = await Image.blank(width: 16, height: 8, color: Rgba.blue).encode(ImageFormat.jpeg);
      final turned = await write('t.jpg', _withExif(plain, orientation: 6));
      final img = await Image.read(turned);
      expect((img.width, img.height), (8, 16));
      final info = await ImageInfo.read(turned);
      expect((info.width, info.height, info.orientation), (8, 16, 6), reason: 'the size as it is seen');
      final again = await Image.decode(await img.encode(ImageFormat.png));
      expect((again.width, again.height), (8, 16), reason: 'saved as it is seen, so a re-save is not sideways');
    });
  });

  group('transforms', () {
    test('resize takes either side or both; fit only with both (IMG-16)', () async {
      final img = Image.blank(width: 200, height: 100);
      expect(img.resize(width: 100).height, 50);
      expect(img.resize(height: 25).width, 50);
      final cover = img.resize(width: 50, height: 50);
      expect((cover.width, cover.height), (50, 50));
      final inside = img.resize(width: 50, height: 50, fit: ImageFit.inside);
      expect((inside.width, inside.height), (50, 25));
      expect(() => img.resize(), throwsArgumentError);
      expect(() => img.resize(width: 50, fit: ImageFit.fill), throwsArgumentError);
      expect(() => img.resize(width: 0), throwsArgumentError);
    });

    test('crop, cropAspect, rotate, flip and pad', () async {
      final img = Image.blank(width: 100, height: 50, color: Rgba.green);
      final c = img.crop(x: 10, y: 10, width: 30, height: 20);
      expect((c.width, c.height), (30, 20));
      final wide = img.cropAspect(1);
      expect((wide.width, wide.height), (50, 50));
      expect(img.rotate(90).width, 50);
      expect(img.rotate(-90).height, 100);
      expect(img.flip(horizontal: true).width, 100);
      final padded = img.pad(top: 5, left: 3);
      expect((padded.width, padded.height), (103, 55));
    });

    test('an argument out of range is an ArgumentError, never a wrapped native value (IMG-14, IMG-18)', () {
      final img = Image.blank(width: 20, height: 20);
      expect(() => img.crop(x: -1, y: 0, width: 5, height: 5), throwsArgumentError);
      expect(() => img.crop(x: 10, y: 10, width: 20, height: 5), throwsArgumentError);
      expect(() => img.trim(threshold: 300), throwsArgumentError);
      expect(() => img.pad(top: -1), throwsArgumentError);
      expect(() => img.rotate(45), throwsArgumentError);
      expect(() => img.flip(), throwsArgumentError);
      expect(() => img.blur(sigma: 0), throwsArgumentError);
      expect(() => img.cropAspect(0), throwsArgumentError);
      expect(() => img.adjust(contrast: -1), throwsArgumentError);
      expect(() => img.watermark(img, opacity: 2), throwsArgumentError);
      expect(() => img.drawText('x', x: 0, y: 0, fontSize: 0), throwsArgumentError);
      expect(() => Rgba(300, 0, 0), throwsArgumentError);
      expect(() => Image.blank(width: 0, height: 1), throwsArgumentError);
    });

    test('colour and filters run, and change what they should', () async {
      final img = await _photo(64, 64);
      expect(img.grayscale().dominantColor.r, img.grayscale().dominantColor.b);
      final inv = Image.blank(width: 8, height: 8, color: Rgba.white).invert().dominantColor;
      expect((inv.r, inv.g, inv.b), (0, 0, 0));
      for (final out in [
        img.sepia(),
        img.blur(),
        img.sharpen(),
        img.denoise(),
        img.vignette(),
        img.adjust(brightness: 0.2, contrast: 1.1, saturation: 0.5),
        img.trim(),
      ]) {
        expect(out.width, greaterThan(0));
      }
      final soft = img.sharpen(amount: 0.5), hard = img.sharpen(amount: 3);
      expect(img.similarity(hard), lessThan(img.similarity(soft)));
    });

    test('watermark, composite, mask and drawText', () {
      final base = Image.blank(width: 100, height: 100, color: Rgba.white);
      final logo = Image.blank(width: 20, height: 20, color: Rgba.red);
      expect(base.watermark(logo, size: 0.2).dominantColor.g, lessThan(255));
      expect(base.composite(logo, x: -5, y: 90).width, 100);
      expect(base.mask(logo).width, 100);
      expect(base.drawText('Hi', x: 10, y: 10, color: Rgba.black, shadow: Rgba.blue).dominantColor.r, lessThan(255));
    });

    test('cropSmart keeps the detailed, skin-toned region a centre crop misses (was Anchor.auto)', () async {
      final scene = await _paint(800, 400, (x, y) {
        if (x < 600 || x >= 760 || y < 120 || y >= 280) return (128, 128, 128);
        return (x ~/ 8 + y ~/ 8).isEven ? (230, 180, 150) : (200, 150, 120);
      });
      Future<int> skin(Image img) async {
        final px = _rgb(await img.encode(ImageFormat.bmp));
        var n = 0;
        for (var i = 0; i < px.length; i += 3) {
          if (px[i] > 190 && px[i + 1] > 140 && px[i + 2] > 110 && px[i] - px[i + 2] > 60) n++;
        }
        return n;
      }

      final smart = scene.cropSmart(1);
      expect((smart.width, smart.height), (400, 400));
      expect(await skin(smart), 160 * 160);
      expect(await skin(scene.cropAspect(1)), 0);
    });

    test('grid lays images out in cells on the background', () async {
      final tiles = [for (var i = 0; i < 5; i++) Image.blank(width: 200 + 40 * i, height: 120, color: Rgba.red)];
      final sheet = Image.grid(tiles, columns: 2, cell: 100, gap: 10, background: Rgba.blue);
      expect((sheet.width, sheet.height), (2 * 100 + 3 * 10, 3 * 100 + 4 * 10));
      final px = _rgb(await sheet.encode(ImageFormat.bmp));
      expect(px.sublist(0, 3), [0, 0, 255]);
      final mid = ((10 + 50) * sheet.width + 10 + 50) * 3;
      expect(px.sublist(mid, mid + 3), [255, 0, 0]);
      expect(() => Image.grid([]), throwsArgumentError);
    });

    test('deblock, autoLevels, enhance and sharpness', () async {
      final smooth = await _paint(
        256,
        256,
        (x, y) => (
          (128 + 100 * sin(x / 37) * cos(y / 53)).round(),
          (128 + 90 * cos(x / 29 + y / 61)).round(),
          (128 + 80 * sin((x + y) / 47)).round(),
        ),
      );
      final source = _rgb(await smooth.encode(ImageFormat.bmp));
      final lossy = await Image.decode(await smooth.encode(ImageFormat.jpeg, quality: Quality.fixed(30)));
      final before = _psnr(source, _rgb(await lossy.encode(ImageFormat.bmp)));
      final after = _psnr(source, _rgb(await lossy.deblock().encode(ImageFormat.bmp)));
      expect(after, greaterThan(before + 0.05));
      final flat = await _paint(64, 64, (x, y) => (100 + x * 50 ~/ 63, 100 + y * 50 ~/ 63, 125));
      final red = _rgb(await flat.autoLevels().encode(ImageFormat.bmp));
      expect([for (var i = 0; i < red.length; i += 3) red[i]].reduce(max), greaterThan(225));
      expect((lossy.enhance().width, lossy.enhance().height), (256, 256));
      final crisp = await _paint(128, 128, (x, y) => (x ~/ 8 + y ~/ 8).isEven ? (230, 230, 230) : (20, 20, 20));
      expect(crisp.sharpness, greaterThan(crisp.blur(sigma: 1).sharpness * 2));
    });
  });

  group('hashes and similarity', () {
    test('hex is 16 digits for a hash; a colour is #rrggbb, with alpha when not opaque (IMG-25)', () {
      expect(const PerceptualHash(-1).hex, 'ffffffffffffffff');
      expect(const PerceptualHash(1).hex, '0000000000000001');
      expect(Rgba(1, 2, 255).hex, '#0102ff');
      expect(Rgba(1, 2, 255, 128).hex, '#0102ff80');
    });

    test('similarity is 100 for the same pixels, lower for a lossy copy, and needs one size', () async {
      final img = await _photo(256, 192);
      expect(img.similarity(await Image.decode(await img.encode(ImageFormat.png))), 100);
      final lossy = await Image.decode(await img.encode(ImageFormat.jpeg, quality: Quality.fixed(30)));
      expect(img.similarity(lossy), allOf(greaterThan(0), lessThan(90)));
      expect(() => img.similarity(Image.blank(width: 10, height: 10)), throwsArgumentError);
    });

    test('phash agrees across a resize, differs for another picture', () async {
      final a = await _paint(
        256,
        256,
        (x, y) => ((128 + 100 * sin(x / 37)).round(), (128 + 90 * cos(y / 29)).round(), 128),
      );
      final b = await _paint(256, 256, (x, y) => ((x * y) % 256, (x + 2 * y) % 256, (3 * x) % 256));
      expect(a.phash.distance(a.resize(width: 128).phash), lessThanOrEqualTo(6));
      expect(a.phash.distance(b.phash), greaterThan(6), reason: "past what similar() groups");
      expect(a.dhash, a.dhash);
      expect(a.ahash.hex, hasLength(16));
    });

    test('similar groups re-encodes, best copy first, on any list of paths (IMG-22)', () async {
      final a = await _paint(
        400,
        400,
        (x, y) => ((128 + 100 * sin(x / 37)).round(), (128 + 90 * cos(y / 29)).round(), 128),
      );
      final b = await _paint(300, 300, (x, y) => ((x * y) % 256, (x + 2 * y) % 256, (3 * x) % 256));
      await Directory(at('sub')).create();
      final paths = [
        await a.save(at('a.jpg'), quality: Quality.fixed(95)),
        await a.resize(width: 300).save(at('sub/a_small.jpg'), quality: Quality.fixed(60)),
        await a.save(at('a_low.jpg'), quality: Quality.fixed(40)),
        await b.save(at('b.png')),
        await b.save(at('b.jpg'), quality: Quality.fixed(70)),
        Path(await write('broken.jpg', utf8.encode('not a jpeg'))),
      ];
      final task = paths.similar();
      final counts = task.statuses
          .where((s) => s is Running)
          .cast<Running<Object?, List<List<Path>>>>()
          .map((r) => r.received)
          .toList();
      final groups = {for (final g in await task) g.map((p) => p.name).join(',')};
      expect(groups, {'a.jpg,a_low.jpg,a_small.jpg', 'b.png,b.jpg'});
      expect((await counts).last, 6, reason: 'it reports the files hashed');
      expect(() => paths.similar(distance: 65), throwsArgumentError);
      expect(await <Path>[].similar(), isEmpty);
    });
  });

  group('encode and save', () {
    test('Quality checks its numbers and its format at the call (IMG-3, IMG-10)', () async {
      expect(() => Quality.fixed(0), throwsArgumentError);
      expect(() => Quality.fixed(300), throwsArgumentError);
      expect(() => Quality.visual(150), throwsArgumentError);
      expect(() => Quality.under(0), throwsArgumentError);
      final img = Image.blank(width: 8, height: 8, color: Rgba.red);
      expect(() => img.encode(ImageFormat.png, quality: Quality.fixed(80)), throwsArgumentError);
      expect(() => img.encode(ImageFormat.jpeg, quality: Quality.lossless), throwsArgumentError);
      expect(() => img.encode(ImageFormat.gif, quality: Quality.lossless), throwsArgumentError);
      expect(() => img.save(at('a.png'), quality: Quality.visual()), throwsArgumentError);
      expect('${Quality.under(1000, visual: 80)}', 'Quality.under(1000, visual: 80.0)');
    });

    test('JPEG refuses transparency in encode as compress does (IMG-9)', () async {
      await expectLater(Image.blank(width: 8, height: 8).encode(ImageFormat.jpeg), throwsArgumentError);
      expect(await Image.blank(width: 8, height: 8, color: Rgba.red).encode(ImageFormat.jpeg), isNotEmpty);
    });

    test('visual finds the smallest quality that reaches the score; under keeps a budget', () async {
      final img = await _photo(512, 384);
      final visual = await Image.decode(await img.encode(ImageFormat.jpeg, quality: Quality.visual(85)));
      expect(img.similarity(visual), greaterThanOrEqualTo(85));
      final small = await img.encode(ImageFormat.jpeg, quality: Quality.under(20000));
      expect(small.length, lessThanOrEqualTo(20000));
      await expectLater(img.encode(ImageFormat.jpeg, quality: Quality.under(200)), throwsA(isA<NativeException>()));
    });

    test('save picks the format by extension, writes atomically and never makes a folder (IMG-11)', () async {
      final img = Image.blank(width: 16, height: 8, color: Rgba.red);
      final path = await img.save(at('a.webp'));
      expect(path, at('a.webp'));
      expect((await ImageInfo.read(path)).format, ImageFormat.webp);
      expect(() => img.save(at('a.xyz')), throwsArgumentError);
      await expectLater(img.save(at('no/such/dir/a.png')), throwsA(isA<PathNotFoundException>()));
      expect(Directory(at('no')).existsSync(), isFalse);
      expect(names(), ['a.webp'], reason: 'no temporary file left');
    });

    test('save keeps what is there with Conflict.skip, as Done(fresh: false)', () async {
      final img = Image.blank(width: 16, height: 8, color: Rgba.red);
      await File(at('a.png')).writeAsString('mine');
      final status = await img.save(at('a.png'), conflict: Conflict.skip).settled;
      expect(status, isA<Done<Object?, Path>>().having((d) => d.fresh, 'fresh', isFalse));
      expect(File(at('a.png')).readAsStringSync(), 'mine');
      await img.save(at('a.png'));
      expect((await ImageInfo.read(at('a.png'))).width, 16, reason: 'a value in hand overwrites by default');
    });
  });

  group('ImageInfo', () {
    test('read takes the header only: size, format, EXIF and JPEG quality', () async {
      final plain = await Image.blank(width: 16, height: 8, color: Rgba.blue).encode(ImageFormat.jpeg);
      final file = await write(
        'a.jpg',
        _withExif(plain, taken: '2021:07:04 09:30:15', orientation: 1, make: 'Canon', model: 'Canon EOS 5D'),
      );
      final info = await ImageInfo.read(file);
      expect((info.width, info.height, info.format), (16, 8, ImageFormat.jpeg));
      expect((info.taken, info.orientation, info.camera), (DateTime(2021, 7, 4, 9, 30, 15), 1, 'Canon EOS 5D'));
      expect(info.quality, inInclusiveRange(70, 90), reason: "mozjpeg's tables are near libjpeg's at 85");
      expect('$info', 'ImageInfo(16×8 jpeg)');
      await expectLater(ImageInfo.read(at('none.png')), throwsA(isA<PathNotFoundException>()));
      final text = await write('a.txt', utf8.encode('hello there'));
      await expectLater(
        ImageInfo.read(text),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(text))),
      );
    });

    test("a PNG's eXIf orientation turns its size as Image.read turns its pixels", () async {
      final png = await Image.blank(width: 40, height: 20, color: Rgba.red).encode(ImageFormat.png);
      final file = await write('turned.png', _pngWithOrientation(png, 6));
      final info = await ImageInfo.read(file);
      final img = await Image.read(file);
      expect((info.width, info.height, info.orientation), (img.width, img.height, 6));
      expect((img.width, img.height), (20, 40));
    });

    test('quality reads the luminance table as libjpeg quality, in either order', () async {
      for (final q in [10, 30, 50, 75, 95]) {
        expect((await ImageInfo.read(await write('q$q.jpg', _jpegHeader(q)))).quality, q);
        expect((await ImageInfo.read(await write('z$q.jpg', _jpegHeader(q, zigzag: true)))).quality, q);
      }
    });

    test('detect names the format from the content, null for anything else', () async {
      final img = Image.blank(width: 8, height: 8, color: Rgba.red);
      for (final f in ImageFormat.values) {
        expect(await ImageInfo.detect(await write('x.${f.extensions.first}', await img.encode(f))), f);
      }
      expect(await ImageInfo.detect(await write('x.txt', utf8.encode('hi'))), isNull);
      await expectLater(ImageInfo.detect(at('none')), throwsA(isA<PathNotFoundException>()));
    });
  });

  group('compress', () {
    test('a file is replaced only by something smaller, in its own format', () async {
      final file = await write(
        'a.jpg',
        await (await _photo(512, 384)).encode(ImageFormat.jpeg, quality: Quality.fixed(97)),
      );
      final r = await Path(file).compress(original: Original.delete);
      expect((r.path, r.after < r.before, r.format, r.width, r.height), (file, true, ImageFormat.jpeg, 512, 384));
      expect(File(file).lengthSync(), r.after);
      expect(r.score, greaterThanOrEqualTo(85));
      expect(r.quality, inInclusiveRange(40, 100));
      expect(names(), ['a.jpg'], reason: 'no temporary file left');
    });

    test('nothing smaller is Done(fresh: false) with after == before, the reason a step', () async {
      final file = await write(
        'a.jpg',
        await (await _photo(256, 192)).encode(ImageFormat.jpeg, quality: Quality.fixed(40)),
      );
      final bytes = File(file).readAsBytesSync();
      final task = Path(file).compress(quality: Quality.fixed(100), original: Original.delete);
      final steps = task.statuses
          .where((s) => s is Running)
          .cast<Running<Object?, Compressed>>()
          .map((r) => r.step)
          .toList();
      final status = await task.settled;
      expect(status, isA<Done<Object?, Compressed>>().having((d) => d.fresh, 'fresh', isFalse));
      final r = (status as Done<Object?, Compressed>).value;
      expect((r.after, r.path, r.quality), (r.before, file, null));
      expect(await steps, containsAllInOrder(['compressing', 'not smaller']), reason: 'IMG-28: a step per stage');
      expect(File(file).readAsBytesSync(), bytes);
    });

    test('the original goes to the trash by default, after the result is in place (X-1)', () async {
      await Env.scope(() async {
        Env.set('HOME', tmp.path);
        Env.set('XDG_DATA_HOME', at('.local/share'));
        final file = await write(
          'e.jpg',
          await (await _photo(256, 192)).encode(ImageFormat.jpeg, quality: Quality.fixed(97)),
        );
        final before = File(file).lengthSync();
        await Path(file).compress();
        final bin = Platform.isMacOS ? at('.Trash') : at('.local/share/Trash/files');
        final trashed = Directory(bin).listSync().whereType<File>().single;
        expect((trashed.uri.pathSegments.last, trashed.lengthSync()), ('e.jpg', before));
        expect(File(file).lengthSync(), lessThan(before));
        expect(tmp.listSync().where((e) => e.path.contains('.compressing-')), isEmpty);
      });
    }, testOn: 'mac-os || linux');

    test('a new format gets its extension; the original goes only after it is written (X-1)', () async {
      final file = await write('b.png', await (await _photo(256, 192)).encode(ImageFormat.png));
      final r = await Path(file).compress(format: ImageFormat.webp, original: Original.delete);
      expect(r.path, at('b.webp'));
      expect((File(file).existsSync(), File(r.path).existsSync()), (false, true));
      final kept = await write('c.png', await (await _photo(256, 192)).encode(ImageFormat.png));
      await Path(kept).compress(format: ImageFormat.webp, original: Original.keep);
      expect((File(kept).existsSync(), File(at('c.webp')).existsSync()), (true, true));
    });

    test('a new format whose file is there is a PathExistsException, the original untouched', () async {
      final file = await write('d.png', await (await _photo(128, 96)).encode(ImageFormat.png));
      await File(at('d.webp')).writeAsString('mine');
      await expectLater(
        Path(file).compress(format: ImageFormat.webp, original: Original.delete),
        throwsA(isA<PathExistsException>()),
      );
      expect((File(file).existsSync(), File(at('d.webp')).readAsStringSync()), (true, 'mine'));
    });

    test('Original.keep without a new format, and a quality not for the format, are ArgumentErrors', () async {
      final file = await write(
        'e.png',
        await Image.blank(width: 8, height: 8, color: Rgba.red).encode(ImageFormat.png),
      );
      expect(() => Path(file).compress(original: Original.keep), throwsArgumentError);
      expect(() => Path(file).compress(format: ImageFormat.png, quality: Quality.fixed(80)), throwsArgumentError);
      expect(() => Path(file).compress(maxSide: 0), throwsArgumentError);
      // The format of the file itself is known once it is read.
      await expectLater(Path(file).compress(quality: Quality.fixed(80)), throwsArgumentError);
    });

    test('maxSide shrinks a larger picture to fit, and says so', () async {
      final file = await write(
        'c.jpg',
        await (await _photo(800, 400)).encode(ImageFormat.jpeg, quality: Quality.fixed(97)),
      );
      final r = await Path(file).compress(maxSide: 400, original: Original.delete);
      expect((r.width, r.height), (400, 200));
      final info = await ImageInfo.read(file);
      expect((info.width, info.height), (400, 200));
    });

    test('Quality.under reports a shrunk picture in width and height (IMG-4)', () async {
      final file = await write(
        'u.jpg',
        await (await _photo(512, 512)).encode(ImageFormat.jpeg, quality: Quality.fixed(97)),
      );
      final r = await Path(file).compress(quality: Quality.under(4000), original: Original.delete);
      expect(r.after, lessThanOrEqualTo(4000));
      final info = await ImageInfo.read(file);
      expect((r.width, r.height), (info.width, info.height));
    });

    test('EXIF goes along, its orientation reset since the pixels are upright (IMG-5)', () async {
      final plain = await (await _photo(256, 128)).encode(ImageFormat.jpeg, quality: Quality.fixed(97));
      final tagged = _withExif(plain, taken: '2020:01:02 03:04:05', orientation: 6, make: 'FUJIFILM', model: 'X-T4');
      final file = await write('x.jpg', tagged);
      final r = await Path(file).compress(original: Original.delete);
      expect((r.width, r.height), (128, 256));
      final info = await ImageInfo.read(file);
      expect((info.width, info.height, info.orientation), (128, 256, 1));
      expect((info.taken, info.camera), (DateTime(2020, 1, 2, 3, 4, 5), 'FUJIFILM X-T4'));
      final webp = await write('y.jpg', tagged);
      final w = await Path(webp).compress(format: ImageFormat.webp, original: Original.delete);
      final bytes = File(w.path).readAsBytesSync();
      expect(latin1.decode(bytes).contains('EXIF'), isTrue);
      expect(latin1.decode(bytes).contains('FUJIFILM'), isTrue);
    });

    test('what a redraw would change is left as it is, with the real reason as a note (IMG-6)', () async {
      Future<String> reason(String file, {ImageFormat? format}) async {
        final task = Path(file).compress(format: format, original: Original.delete);
        final note = task.statuses
            .where((s) => s is Warned)
            .cast<Warned<Object?, Compressed>>()
            .map((w) => '${w.warning}')
            .first;
        final status = await task.settled;
        expect(status, isA<Done<Object?, Compressed>>().having((d) => d.fresh, 'fresh', isFalse));
        return note;
      }

      final animated = [..._gifHead, ..._gifFrame, ..._gifHead.sublist(19), ..._gifFrame, 0x3B];
      final gif = await write('m.gif', animated);
      expect(await reason(gif, format: ImageFormat.png), contains('animation'));
      expect(File(gif).readAsBytesSync(), animated);

      final jpeg = await (await _photo(64, 48)).encode(ImageFormat.jpeg, quality: Quality.fixed(97));
      for (var i = 2; i + 9 < jpeg.length;) {
        if (jpeg[i + 1] == 0xC0 || jpeg[i + 1] == 0xC2) {
          jpeg[i + 9] = 4; // four components: CMYK
          break;
        }
        i += 2 + (jpeg[i + 2] << 8 | jpeg[i + 3]);
      }
      expect(await reason(await write('k.jpg', jpeg)), contains('CMYK'));

      final plain = await (await _photo(256, 192)).encode(ImageFormat.jpeg, quality: Quality.fixed(97));
      final icc = [0xFF, 0xE2, 0x00, 0x10, ...'ICC_PROFILE'.codeUnits, 0, 1, 1];
      final profiled = await write('c.jpg', [...plain.sublist(0, 2), ...icc, ...plain.sublist(2)]);
      expect(await reason(profiled, format: ImageFormat.webp), contains('colour profile'));
      await Path(profiled).compress(original: Original.delete);
      expect(latin1.decode(File(profiled).readAsBytesSync()).contains('ICC_PROFILE'), isTrue, reason: 'JPEG keeps it');

      final clear = await write('t.png', await Image.blank(width: 64, height: 48).encode(ImageFormat.png));
      expect(await reason(clear, format: ImageFormat.jpeg), contains('transparency'));
      final bmp = await write('s.bmp', await (await _photo(64, 48)).encode(ImageFormat.bmp));
      expect(await reason(bmp), contains('format: png'));
    });

    test('a BMP asked to be a PNG keeps every pixel; a PNG not resized is recompressed as it is', () async {
      final img = await _photo(64, 48);
      final bmp = await write('s.bmp', await img.encode(ImageFormat.bmp));
      final png = await Path(bmp).compress(format: ImageFormat.png, original: Original.delete);
      expect(png.path, at('s.png'));
      expect(_rgb(await (await Image.read(png.path)).encode(ImageFormat.bmp)), _rgb(await img.encode(ImageFormat.bmp)));
      expect((png.quality, png.score), (null, null), reason: 'lossless: nothing measured');
    });

    test('a batch through parallelize reports every file, a broken one failed', () async {
      final paths = [
        for (var i = 0; i < 3; i++)
          Path(
            await write(
              'f$i.jpg',
              await (await _photo(128, 96, i)).encode(ImageFormat.jpeg, quality: Quality.fixed(97)),
            ),
          ),
        Path(await write('broken.jpg', utf8.encode('not an image'))),
      ];
      final batch = paths.parallelize((p) => p.compress(original: Original.delete), concurrency: 2);
      final settled = await batch.settled;
      expect(settled.whereType<Failed<Path, Compressed>>().single.item.name, 'broken.jpg');
      expect(settled.whereType<Done<Path, Compressed>>(), hasLength(3));
      await expectLater(batch, throwsA(isA<BatchException<Path, Compressed>>()));
    });

    test('a cancelled compress leaves the file as it was', () async {
      final file = await write(
        'g.jpg',
        await (await _photo(512, 384)).encode(ImageFormat.jpeg, quality: Quality.fixed(97)),
      );
      final before = File(file).readAsBytesSync();
      final task = Path(file).compress(original: Original.delete)..cancel();
      expect(await task.settled, isA<Stopped<Object?, Compressed>>());
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(File(file).readAsBytesSync(), before);
    });
  });

  group('optimize', () {
    test('a JPEG loses its metadata and keeps every pixel', () async {
      final plain = await (await _photo(256, 192)).encode(ImageFormat.jpeg, quality: Quality.fixed(90));
      final app1 = [0xFF, 0xE1, 0x00, 0x0A, ...'Exif'.codeUnits, 0, 0, 0, 0];
      final com = [0xFF, 0xFE, 0x00, 0x06, ...'note'.codeUnits];
      final file = await write('d.jpg', [0xFF, 0xD8, ...app1, ...com, ...plain.sublist(2)]);
      final r = await Path(file).optimize(original: Original.delete);
      expect((r.after, r.quality), (plain.length, null));
      expect(File(file).readAsBytesSync(), plain);
    });

    test('a turned PNG keeps its EXIF, so it still shows upright', () async {
      final png = await (await _photo(40, 20)).encode(ImageFormat.png);
      final file = await write('turned.png', _pngWithOrientation(png, 6));
      await Path(file).optimize(original: Original.delete);
      final img = await Image.read(file);
      expect((img.width, img.height), (20, 40));
      expect((await ImageInfo.read(file)).orientation, 6);
    });

    test('a PNG is recompressed; a GIF is left with a note; keep is an ArgumentError', () async {
      final img = await _photo(64, 48);
      final png = await write('o.png', await img.encode(ImageFormat.png));
      await Path(png).optimize(original: Original.delete);
      expect(_rgb(await (await Image.read(png)).encode(ImageFormat.bmp)), _rgb(await img.encode(ImageFormat.bmp)));
      final gif = await write('o.gif', await img.encode(ImageFormat.gif));
      final status = await Path(gif).optimize(original: Original.delete).settled;
      expect(status, isA<Done<Object?, Compressed>>().having((d) => d.fresh, 'fresh', isFalse));
      expect(() => Path(gif).optimize(original: Original.keep), throwsArgumentError);
    });
  });
}

const _gifHead = [
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0, 0xFF, 0xFF, 0xFF, 0, 0, 0, //
  0x21, 0xF9, 4, 0, 0, 0, 0, 0,
];
const _gifFrame = [0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0];

/// [jpeg] with an EXIF segment after SOI: IFD0 holds Make, Model, Orientation and a pointer to
/// an Exif IFD holding DateTimeOriginal. Big-endian; strings are stored out of line, so each
/// must be at least 4 characters.
Uint8List _withExif(
  Uint8List jpeg, {
  String taken = '2000:01:01 00:00:00',
  required int orientation,
  String make = 'Make',
  String model = 'Model',
}) {
  List<int> z(String s) => [...latin1.encode(s), 0];
  final strings = [z(make), z(model), z(taken)];
  const ifd0At = 8, ifd0Size = 2 + 4 * 12 + 4, subAt = ifd0At + ifd0Size, subSize = 2 + 12 + 4;
  var data = subAt + subSize;
  final at = [for (final s in strings) (data += s.length) - s.length];
  final t = ByteData(data)
    ..setUint16(0, 0x4D4D)
    ..setUint16(2, 42)
    ..setUint32(4, ifd0At);
  void entry(int o, int tag, int type, int count, int value) {
    t
      ..setUint16(o, tag)
      ..setUint16(o + 2, type)
      ..setUint32(o + 4, count);
    type == 3 ? t.setUint16(o + 8, value) : t.setUint32(o + 8, value);
  }

  t.setUint16(ifd0At, 4);
  entry(ifd0At + 2, 0x010F, 2, strings[0].length, at[0]);
  entry(ifd0At + 14, 0x0110, 2, strings[1].length, at[1]);
  entry(ifd0At + 26, 0x0112, 3, 1, orientation);
  entry(ifd0At + 38, 0x8769, 4, 1, subAt);
  t.setUint16(subAt, 1);
  entry(subAt + 2, 0x9003, 2, strings[2].length, at[2]);
  final tiff = t.buffer.asUint8List();
  for (var i = 0; i < strings.length; i++) {
    tiff.setRange(at[i], at[i] + strings[i].length, strings[i]);
  }
  final len = 2 + 6 + tiff.length;
  return Uint8List.fromList([
    0xFF,
    0xD8,
    0xFF,
    0xE1,
    len >> 8,
    len & 0xFF,
    ...'Exif'.codeUnits,
    0,
    0,
    ...tiff,
    ...jpeg.sublist(2),
  ]);
}

/// [png] with an `eXIf` chunk after its header whose Orientation is [orientation].
Uint8List _pngWithOrientation(Uint8List png, int orientation) {
  final tiff = [
    0x4D, 0x4D, 0, 0x2A, 0, 0, 0, 8, 0, 1, //
    0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, orientation, 0, 0, 0, 0, 0, 0,
  ];
  List<int> be32(int v) => [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];
  var crc = 0xFFFFFFFF;
  for (final b in [...'eXIf'.codeUnits, ...tiff]) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = crc & 1 != 0 ? (crc >>> 1) ^ 0xEDB88320 : crc >>> 1;
    }
  }
  final chunk = [...be32(tiff.length), ...'eXIf'.codeUnits, ...tiff, ...be32(crc ^ 0xFFFFFFFF)];
  // After the signature (8) and IHDR (25).
  return Uint8List.fromList([...png.sublist(0, 33), ...chunk, ...png.sublist(33)]);
}

/// A photo-like picture: smooth gradients under per-pixel noise, so a codec has detail to keep.
Future<Image> _photo(int width, int height, [int seed = 1]) {
  final rnd = Random(seed);
  return _paint(width, height, (x, y) {
    int c(int base) => (base + rnd.nextInt(8)).clamp(0, 255);
    return (c(((x + y) * 100 ~/ (width + height)) + 60), c(y * 200 ~/ height), c(x * 200 ~/ width));
  });
}

/// A [w]×[h] image whose pixel (x, y) is [color], built from a 24-bit BMP.
Future<Image> _paint(int w, int h, (int, int, int) Function(int x, int y) color) {
  final stride = (w * 3 + 3) & ~3;
  final b = ByteData(54 + stride * h)
    ..setUint16(0, 0x4D42, Endian.little)
    ..setUint32(2, 54 + stride * h, Endian.little)
    ..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, w, Endian.little)
    ..setInt32(22, h, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 24, Endian.little);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final (r, g, bl) = color(x, y);
      final at = 54 + (h - 1 - y) * stride + x * 3;
      b
        ..setUint8(at, bl)
        ..setUint8(at + 1, g)
        ..setUint8(at + 2, r);
    }
  }
  return Image.decode(b.buffer.asUint8List());
}

/// The pixels of [bmp], a BMP file, as RGB triples row by row.
Uint8List _rgb(Uint8List bytes) {
  final d = ByteData.sublistView(bytes);
  final off = d.getUint32(10, Endian.little), w = d.getInt32(18, Endian.little), h = d.getInt32(22, Endian.little);
  final bpp = d.getUint16(28, Endian.little) ~/ 8, stride = (w * bpp + 3) & ~3;
  final out = Uint8List(w * h.abs() * 3);
  for (var y = 0; y < h.abs(); y++) {
    for (var x = 0; x < w; x++) {
      final s = off + (h > 0 ? h - 1 - y : y) * stride + x * bpp;
      out
        ..[(y * w + x) * 3] = bytes[s + 2]
        ..[(y * w + x) * 3 + 1] = bytes[s + 1]
        ..[(y * w + x) * 3 + 2] = bytes[s];
    }
  }
  return out;
}

/// A JPEG header: SOI, one 8-bit luminance table (libjpeg's at [quality], in zigzag order when
/// [zigzag]), SOF0 for 64×32, EOI.
Uint8List _jpegHeader(int quality, {bool zigzag = false}) {
  const annexK = [
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, //
    14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
  ];
  const zz = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, //
    28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61,
    54, 47, 55, 62, 63,
  ];
  final scale = quality < 50 ? 5000 ~/ quality : 200 - 2 * quality;
  final table = [for (var i = 0; i < 64; i++) ((annexK[zigzag ? zz[i] : i] * scale + 50) ~/ 100).clamp(1, 255)];
  return Uint8List.fromList([
    0xFF, 0xD8, //
    0xFF, 0xDB, 0, 67, 0, ...table,
    0xFF, 0xC0, 0, 11, 8, 0, 32, 0, 64, 1, 1, 0x11, 0,
    0xFF, 0xD9,
  ]);
}

double _psnr(Uint8List a, Uint8List b) {
  var se = 0.0;
  for (var i = 0; i < a.length; i++) {
    se += (a[i] - b[i]) * (a[i] - b[i]);
  }
  return 10 * log(255 * 255 / (se / a.length)) / ln10;
}

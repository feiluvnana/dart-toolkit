import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_toolkit/image.dart';
import 'framework.dart';

class ImageResizeBenchmark extends BenchmarkCase {
  ImageResizeBenchmark() : super('image_resize_thumbnail', module: 'image', throughputUnit: 'ops/s');

  late Image img;

  @override
  Future<void> setup() async => img = Image.blank(width: 1920, height: 1080, color: Rgba(100, 150, 200));

  @override
  Future<void> teardown() => img.close();

  @override
  int get iterations => 20;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      await img.resize(width: 300, height: 300, fit: ImageFit.inside).close();
    }
    return count;
  }
}

class ImagePhashBenchmark extends BenchmarkCase {
  ImagePhashBenchmark() : super('image_phash', module: 'image', throughputUnit: 'ops/s');

  late Image img;

  @override
  Future<void> setup() async => img = Image.blank(width: 512, height: 512, color: Rgba(120, 80, 40));

  @override
  Future<void> teardown() => img.close();

  @override
  int get iterations => 50;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final h = img.phash;
      if (h.value == 0) throw StateError('fail');
    }
    return count;
  }
}

/// A 2560×1440 JPEG at quality 87, a common full-size photo: gradients under mild noise.
Future<Uint8List> _samplePhoto() async {
  final rnd = Random(7);
  const width = 2560, height = 1440, row = width * 3;
  final bmp = ByteData(54 + row * height)
    ..setUint16(0, 0x4D42, Endian.little)
    ..setUint32(2, 54 + row * height, Endian.little)
    ..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, width, Endian.little)
    ..setInt32(22, height, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 24, Endian.little);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final o = 54 + y * row + x * 3;
      bmp
        ..setUint8(o, (x * 200 ~/ width + rnd.nextInt(8)).clamp(0, 255))
        ..setUint8(o + 1, (y * 200 ~/ height + rnd.nextInt(8)).clamp(0, 255))
        ..setUint8(o + 2, ((x + y) * 100 ~/ (width + height) + 60 + rnd.nextInt(8)).clamp(0, 255));
    }
  }
  final img = await Image.decode(bmp.buffer.asUint8List());
  final jpeg = await img.encode(ImageFormat.jpeg, quality: Quality.fixed(87));
  await img.close();
  return jpeg;
}

/// One photo encoded at `Quality.visual()`, the default target of `compress`: the quality
/// search, its scores and the final mozjpeg encode.
class ImageCompressBenchmark extends BenchmarkCase {
  ImageCompressBenchmark() : super('image_compress_2560', module: 'image', throughputUnit: 'images/s');

  late Image img;

  @override
  Future<void> setup() async => img = await Image.decode(await _samplePhoto());

  @override
  Future<void> teardown() => img.close();

  @override
  int get iterations => 3;

  @override
  int get warmupIterations => 1;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      if ((await img.encode(ImageFormat.jpeg, quality: Quality.visual())).isEmpty) throw StateError('empty');
    }
    return count;
  }
}

/// Eight photo files through `Path.compress`, parallelized at the default concurrency.
class ImageCompressBatchBenchmark extends BenchmarkCase {
  ImageCompressBatchBenchmark() : super('image_compress_batch_8', module: 'image', throughputUnit: 'images/s');

  late Directory dir;
  late Uint8List photo;

  @override
  Future<void> setup() async {
    dir = Directory.systemTemp.createTempSync('bench_compress_');
    photo = await _samplePhoto();
  }

  @override
  Future<void> teardown() async => dir.deleteSync(recursive: true);

  @override
  int get iterations => 1;

  @override
  int get warmupIterations => 0;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final files = [for (var k = 0; k < 8; k++) Path((File('${dir.path}/$i-$k.jpg')..writeAsBytesSync(photo)).path)];
      await files.parallelize((f) => f.compress(original: Original.delete));
    }
    return count * 8;
  }
}

/// One [op] on a 2560×1440 image, a common full-size photo.
class ImageOpBenchmark extends BenchmarkCase {
  ImageOpBenchmark(super.name, this.op) : super(module: 'image', throughputUnit: 'ops/s');

  final Object? Function(Image img) op;
  late Image img;

  @override
  Future<void> setup() async {
    // Textured, so deblock, sharpness and the smart crop have work to do.
    final blank = Image.blank(width: 64, height: 64, color: Rgba(180, 120, 90));
    final tile = blank.drawText('TK', x: 4, y: 4);
    img = tile.resize(width: 2560, height: 1440, fit: ImageFit.fill, filter: ImageFilter.nearest);
    await Future.wait([blank.close(), tile.close()]);
  }

  @override
  Future<void> teardown() => img.close();

  @override
  int get iterations => 20;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      final out = op(img);
      if (out is Image) await out.close();
    }
    return count;
  }
}

/// The folder's files listed, then `similar` over them: 60 JPEGs, 20 shots each saved three ways.
class ImageSimilarBenchmark extends BenchmarkCase {
  ImageSimilarBenchmark() : super('image_similar_60_files', module: 'image', throughputUnit: 'files/s');

  late Directory dir;

  @override
  Future<void> setup() async {
    dir = Directory.systemTemp.createTempSync('bench_similar_');
    for (var i = 0; i < 20; i++) {
      final blank = Image.blank(width: 1280, height: 720, color: Rgba(i * 12, 255 - i * 12, 128));
      final shot = blank.drawText('shot $i', x: 40 + i * 20, y: 60, fontSize: 96, color: Rgba.white);
      final small = shot.resize(width: 800);
      await shot.save('${dir.path}/$i.jpg', quality: Quality.fixed(90));
      await shot.save('${dir.path}/${i}_low.jpg', quality: Quality.fixed(50));
      await small.save('${dir.path}/${i}_small.jpg');
      await Future.wait([blank.close(), shot.close(), small.close()]);
    }
  }

  @override
  Future<void> teardown() async => dir.deleteSync(recursive: true);

  @override
  int get iterations => 5;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      await (await Path(dir.path).files().toList()).similar();
    }
    return 60 * count;
  }
}

List<BenchmarkCase> createImageBenchmarks() {
  return [
    ImageResizeBenchmark(),
    ImagePhashBenchmark(),
    ImageCompressBenchmark(),
    ImageCompressBatchBenchmark(),
    ImageOpBenchmark('image_deblock_2560', (img) => img.deblock()),
    ImageOpBenchmark('image_enhance_2560', (img) => img.enhance()),
    ImageOpBenchmark('image_sharpness_2560', (img) => img.sharpness),
    ImageOpBenchmark('image_crop_auto_2560', (img) => img.cropSmart(1)),
    ImageOpBenchmark('image_grid_12', (img) => Image.grid(List.filled(12, img))),
    ImageSimilarBenchmark(),
  ];
}

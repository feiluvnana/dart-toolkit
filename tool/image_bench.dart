// Measure the image pipeline against the acceptance table on a real photo library.
//
//   dart run tool/image_bench.dart --dir=D:/PureMedia/imgs
//   dart run tool/image_bench.dart --sample=6 --repeat=20 --control=false
//   dart run tool/image_bench.dart --full            # every file through WebP + thumbnail
//
// The library is warmed before the first measurement, because a `dart run` pays for DLL load
// on the first call, and the control stage holds N canvases open on purpose: without it a
// stable RSS line proves nothing about whether RSS would have moved.
library;

import 'dart:io';

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/collection.dart';
import 'package:dart_toolkit/image.dart';

const _images = '**/*.{jpg,jpeg,png,webp}';

/// Targets from the acceptance table; a missed one fails the run.
const _probePerSecond = 15000;
final _probeBudget = 70.ms;
final _resizeBudget = 120.ms;
const _leakPerIteration = 1024 * 1024;
const _reductionMin = 0.60;
const _reductionMax = 0.75;

final _dir = Option.of<Path>('dir', 'Photo library to measure', short: 'd').or(const Path('D:/PureMedia/imgs'));
final _sample = Option.of<int>('sample', 'Largest images pushed through the whole chain', short: 'n').or(4);
final _spread = Option.of<int>('spread', 'Evenly spread images used for the WebP reduction', short: 'p').or(24);
final _repeat = Option.of<int>('repeat', 'Leak-loop iterations on the biggest image', short: 'r').or(100);
final _quality = Option.of<int>('quality', 'WebP encoder quality', short: 'q').or(82);
final _edge = Option.of<int>('size', 'Thumbnail edge in pixels', short: 's').or(852);
final _full = Option.flag('full', 'Run every file through WebP + thumbnail as well');
final _control = Option.flag('control', 'Hold canvases open to prove RSS sees a leak');
final _keep = Option.flag('keep', 'Keep the encoded output instead of deleting it');

/// One stage of the chain, timed once per sample image.
final class _Stage {
  _Stage(this.name);

  final String name;
  final List<int> _us = [];

  void add(Duration elapsed) => _us.add(elapsed.inMicroseconds);

  int get mean => _us.isEmpty ? 0 : _us.fold(0, (a, b) => a + b) ~/ _us.length;

  int get p95 {
    if (_us.isEmpty) return 0;
    final sorted = _us.toList()..sort();
    return sorted[((sorted.length - 1) * 0.95).round()];
  }
}

/// A row of the report: what was measured, what it had to be, and whether it was.
final class _Row {
  _Row(this.metric, this.target, this.measured, {required this.passed});

  final String metric;
  final String target;
  final String measured;
  final bool passed;
}

/// What the whole-chain pass measured.
typedef _Chain = ({
  List<_Stage> stages,
  int decodeMean,
  int resizeMean,
  int resizeP95,
  int totalMean,
  int sourceBytes,
  int webpBytes,
  String sourceEdge,
  String sourceMegapixels,
  double reduction,
  int sample,
});

String _ms(int microseconds) =>
    microseconds >= 1000 ? '${(microseconds / 1000).toStringAsFixed(1)} ms' : '$microseconds us';

Future<void> _main(CliContext ctx) async {
  final dir = ctx(_dir);
  final sample = ctx(_sample);
  final repeat = ctx(_repeat);
  final quality = ctx(_quality);
  final edge = ctx(_edge);
  final control = ctx(_control);
  final keep = ctx(_keep);

  if (!await dir.exists()) Console.exit('No such directory: $dir');

  final files = await dir.files(only: _images, order: Order.natural).toList();
  if (files.isEmpty) Console.exit('No images under $dir');

  final rows = <_Row>[];

  Console.info('warming the native library');
  await ImageInfo.read(files.first);
  await Image.blank(width: 8, height: 8).close();

  Console.info('probing ${files.length} file headers, twice');
  final cold = Stopwatch()..start();
  for (final f in files) {
    await ImageInfo.read(f);
  }
  cold.stop();
  final warm = Stopwatch()..start();
  for (final f in files) {
    await ImageInfo.read(f);
  }
  warm.stop();
  final probeRate = files.length / (warm.elapsed.inMicroseconds / 1e6);
  rows.add(
    _Row(
      'Probe throughput',
      '>= ${_probePerSecond ~/ 1000}k/s, < ${_probeBudget.inMilliseconds} ms for ${files.length}',
      '${probeRate.round()}/s in ${warm.elapsed.inMilliseconds} ms '
          '(cold run ${cold.elapsed.inMilliseconds} ms, kept out of the number)',
      passed: probeRate >= _probePerSecond && warm.elapsed < _probeBudget,
    ),
  );

  Console.info('checking blend accuracy on synthetic canvases');
  final failures = await _blendFailures();
  rows.add(
    _Row(
      'Watermark & composite',
      'exact pixels, background untouched',
      failures.isEmpty ? 'exact' : failures.join('; '),
      passed: failures.isEmpty,
    ),
  );

  Console.info('running the chain on the $sample largest of ${files.length} images');
  final chain = await _chain(files, sample, quality, edge);

  rows.add(
    _Row(
      'Resize ${chain.sourceEdge} -> $edge (lanczos)',
      '<= ${_resizeBudget.inMilliseconds} ms/image',
      '${_ms(chain.resizeMean)} mean, ${_ms(chain.resizeP95)} p95',
      passed: chain.resizeMean <= _resizeBudget.inMicroseconds,
    ),
  );
  rows.add(_Row('Decode ${chain.sourceMegapixels} MP', 'reported', '${_ms(chain.decodeMean)} mean', passed: true));

  if (ctx(_spread) > 0) {
    Console.info('encoding ${ctx(_spread)} evenly spread images at q$quality');
    final spread = await _spreadEncode(files, ctx(_spread), quality);
    rows.add(
      _Row(
        'WebP q$quality against source',
        'median ${(_reductionMin * 100).round()}-${(_reductionMax * 100).round()}% smaller',
        'median ${(spread.median * 100).toStringAsFixed(1)}% '
            '(p10 ${(spread.p10 * 100).toStringAsFixed(1)}%, p90 ${(spread.p90 * 100).toStringAsFixed(1)}%), '
            '${spread.beating}/${spread.count} over ${(_reductionMin * 100).round()}%, '
            '${spread.sourceBytes.humanBytes} -> ${spread.webpBytes.humanBytes}',
        passed: spread.median >= _reductionMin,
      ),
    );
    Console.info('WebP reduction per image: ${spread.ratios.map((r) => '${(r * 100).round()}%').join(' ')}');
  }

  Console.info('');
  await Table.cells(
    ['chain stage', 'mean', 'p95'],
    [
      for (final stage in chain.stages) [stage.name, _ms(stage.mean), _ms(stage.p95)],
    ],
  ).show();
  Console.info(
    'Chain total ${_ms(chain.totalMean)} per image over ${chain.sample} images '
    '(${chain.sourceMegapixels} MP source, ${chain.sourceBytes.humanBytes} -> ${chain.webpBytes.humanBytes} '
    'after the watermark and sharpen, peak RSS ${ProcessInfo.maxRss.humanBytes})',
  );

  Console.info('looping $repeat opens on the biggest image');
  final sizes = {for (final f in files) f: await f.size()};
  final biggest = files.reduce((a, b) => sizes[a]! >= sizes[b]! ? a : b);
  final resident = <int>[];
  final leakWatch = Stopwatch()..start();
  for (var i = 0; i < repeat; i++) {
    final img = await Image.read(biggest);
    await _thumbnail(img, edge).close();
    await img.close();
    if (i % 5 == 0) resident.add(ProcessInfo.currentRss);
  }
  leakWatch.stop();
  final drift = (resident.last - resident.first) ~/ (repeat - 1);
  rows.add(
    _Row(
      'Memory safety ($repeat x ${biggest.name})',
      '0 byte leak',
      '${drift >= 0 ? '+' : ''}${drift.humanBytes}/iteration, '
          'RSS ${resident.first.humanBytes} -> ${resident.last.humanBytes}, peak ${ProcessInfo.maxRss.humanBytes}',
      passed: drift.abs() < _leakPerIteration,
    ),
  );
  Console.info(
    'Leak loop: $repeat opens of ${biggest.name} in ${leakWatch.elapsedMilliseconds} ms, '
    'peak RSS ${ProcessInfo.maxRss.humanBytes}',
  );

  if (control) {
    Console.info('control: 20 canvases held open, then released');
    final before = ProcessInfo.currentRss;
    final held = [for (var i = 0; i < 20; i++) Image.blank(width: 3000, height: 2000, color: Rgba(20, 20, 20))];
    final live = ProcessInfo.currentRss;
    for (final img in held) {
      await img.close();
    }
    final released = ProcessInfo.currentRss;
    rows.add(
      _Row(
        'Leak detection works',
        'RSS climbs while handles live',
        '20 x 12 MP held +${(live - before).humanBytes}, released +${(released - before).humanBytes}',
        passed: live - before > 120 * 1024 * 1024,
      ),
    );
  }

  if (ctx(_full)) {
    Console.info('converting all ${files.length} images');
    final whole = await _fullLibrary(files, quality, edge, keep: keep);
    final sorted = List<double>.of(whole.ratios)..sort();
    final median = sorted[sorted.length ~/ 2];
    rows.add(
      _Row(
        'Full library',
        'every file written',
        '${whole.count} images in ${whole.elapsed.inSeconds} s '
            '(${_perSecond(whole.count, whole.elapsed)}/s), '
            '${whole.sourceBytes.humanBytes} -> ${whole.webpBytes.humanBytes} '
            '(${(100 - 100 * whole.webpBytes / whole.sourceBytes).toStringAsFixed(1)}% smaller, '
            'median per image ${(median * 100).toStringAsFixed(1)}%)',
        passed: whole.count == files.length,
      ),
    );
    Console.info(
      'Per-image reduction deciles: '
      '${[0.1, 0.25, 0.5, 0.75, 0.9].map((f) => '${(sorted[(sorted.length * f).floor()] * 100).round()}%').join(' ')}',
    );
  } else {
    Console.info('Skipping the library-wide run; pass --full to convert every image.');
  }

  Console.info('');
  await Table.cells(
    ['metric', 'target', 'measured', 'result'],
    [
      for (final r in rows) [r.metric, r.target, r.measured, r.passed ? 'PASS' : 'FAIL'],
    ],
  ).show();

  final failed = rows.where((r) => !r.passed).toList();
  if (failed.isNotEmpty) {
    Console.exit('${failed.length} of ${rows.length} targets missed: ${failed.map((r) => r.metric).join(', ')}');
  }
  Console.ok('All ${rows.length} targets met (peak RSS ${ProcessInfo.maxRss.humanBytes})');
}

/// [img] shrunk so neither side exceeds [edge].
Image _thumbnail(Image img, int edge) => img.resize(width: edge, height: edge, fit: ImageFit.inside);

String _perSecond(int count, Duration elapsed) => (count / (elapsed.inMilliseconds / 1000)).toStringAsFixed(2);

/// Verifies the blend maths through the public surface only: a canvas of one colour, a logo of
/// another, and the colour that comes out where the logo landed and where it did not.
Future<List<String>> _blendFailures() async {
  const white = Rgba.white;
  const black = Rgba.black;
  final failures = <String>[];

  Future<(Rgba, Rgba)> blend(Rgba logoColor, {double opacity = 1.0, BlendMode mode = BlendMode.srcOver}) async {
    final bg = Image.blank(width: 64, height: 64, color: white);
    final logo = Image.blank(width: 16, height: 16, color: logoColor);
    final merged = bg.composite(logo, x: 48, y: 48, opacity: opacity, blend: mode);
    final inner = merged.crop(x: 48, y: 48, width: 8, height: 8);
    final outer = merged.crop(x: 0, y: 0, width: 32, height: 32);
    final colors = (inner.dominantColor, outer.dominantColor);
    await Future.wait([
      for (final img in [logo, bg, merged, inner, outer]) img.close(),
    ]);
    return colors;
  }

  void expect(String what, Rgba got, Set<Rgba> want) {
    if (!want.contains(got)) failures.add('$what got ${got.hex} want ${want.map((c) => c.hex).join('|')}');
  }

  expect('opaque logo', (await blend(black)).$1, {black});
  expect('untouched background', (await blend(black)).$2, {white});
  final grey = {Rgba(127, 127, 127), Rgba(128, 128, 128)};
  expect('50% opacity', (await blend(black, opacity: 0.5)).$1, grey);
  expect('logo alpha 128', (await blend(Rgba(0, 0, 0, 128))).$1, grey);
  expect('black multiply', (await blend(black, mode: BlendMode.multiply)).$1, {black});
  expect('black screen', (await blend(black, mode: BlendMode.screen)).$1, {white});
  expect('white multiply', (await blend(white, mode: BlendMode.multiply)).$1, {white});
  expect('white screen over black', (await blend(white, mode: BlendMode.screen)).$1, {white});

  return failures;
}

/// The photo chain on the largest photographs, where the time budget is tightest: decode
/// (upright), adjust, watermark, sharpen, encode WebP, write it, and thumbnail the original.
Future<_Chain> _chain(List<Path> files, int sample, int quality, int edge) async {
  final sizes = {for (final f in files) f: await f.size()};
  final ranked = List<Path>.of(files)..sort((a, b) => sizes[b]!.compareTo(sizes[a]!));
  final picked = ranked.take(sample).toList();
  final decode = _Stage('decode');
  final adjust = _Stage('adjust');
  final mark = _Stage('watermark');
  final sharpen = _Stage('sharpen');
  final encode = _Stage('encode WebP');
  final write = _Stage('write WebP');
  final resize = _Stage('thumbnail $edge');
  final thumbEncode = _Stage('encode thumbnail');
  final thumbWrite = _Stage('write thumbnail');

  final plate = Image.blank(width: 320, height: 80, color: Rgba(255, 255, 255, 170));
  final logo = plate.drawText('PURE MEDIA', x: 8, y: 24, fontSize: 32, color: Rgba(20, 20, 20));
  await plate.close();

  var sourceBytes = 0, webpBytes = 0, totalUs = 0;
  var sourceEdge = '', sourceMegapixels = 0.0;

  await Path.tempDir((out) async {
    for (final file in picked) {
      final total = Stopwatch()..start();
      final watch = Stopwatch()..start();

      final image = await Image.read(file);
      decode.add(watch.elapsed);

      watch.reset();
      final toned = image.adjust(contrast: 1.05, brightness: 0.02);
      adjust.add(watch.elapsed);

      watch.reset();
      final marked = toned.watermark(logo, anchor: Anchor.bottomRight, opacity: 0.7, size: 0.15, margin: 24);
      mark.add(watch.elapsed);

      watch.reset();
      final crisp = marked.sharpen(amount: 1.2);
      sharpen.add(watch.elapsed);

      watch.reset();
      final encoded = await crisp.encode(ImageFormat.webp, quality: Quality.fixed(quality));
      encode.add(watch.elapsed);

      watch.reset();
      await (out / file.withExt('webp').name).writeBytes(encoded);
      write.add(watch.elapsed);

      watch.reset();
      final thumb = _thumbnail(image, edge);
      resize.add(watch.elapsed);

      watch.reset();
      final thumbBytes = await thumb.encode(ImageFormat.jpeg, quality: Quality.fixed(85));
      thumbEncode.add(watch.elapsed);

      watch.reset();
      await (out / '${file.name}.thumb.jpg').writeBytes(thumbBytes);
      thumbWrite.add(watch.elapsed);

      total.stop();
      totalUs += total.elapsedMicroseconds;
      sourceBytes += sizes[file]!;
      webpBytes += encoded.length;
      final megapixels = image.width * image.height / 1e6;
      if (megapixels >= sourceMegapixels) {
        sourceMegapixels = megapixels;
        sourceEdge = '${image.width}x${image.height}';
      }

      await Future.wait([
        for (final img in [image, toned, marked, crisp, thumb]) img.close(),
      ]);
    }
  });

  await logo.close();

  return (
    stages: [decode, adjust, mark, sharpen, encode, write, resize, thumbEncode, thumbWrite],
    decodeMean: decode.mean,
    resizeMean: resize.mean,
    resizeP95: resize.p95,
    totalMean: totalUs ~/ (picked.isEmpty ? 1 : picked.length),
    sourceBytes: sourceBytes,
    webpBytes: webpBytes,
    sourceEdge: sourceEdge,
    sourceMegapixels: sourceMegapixels.toStringAsFixed(1),
    reduction: sourceBytes == 0 ? 0.0 : 1 - webpBytes / sourceBytes,
    sample: picked.length,
  );
}

/// What the spread pass measured: one WebP encode per file, no other work, so the reduction
/// belongs to the encoder rather than to the chain around it.
typedef _Spread = ({
  int count,
  int sourceBytes,
  int webpBytes,
  int beating,
  double median,
  double p10,
  double p90,
  List<double> ratios,
});

/// Encodes one image every `stride` files, because a run of neighbouring files in a photo library
/// share a source and encoding all of them would weight the median towards one shoot.
Future<_Spread> _spreadEncode(List<Path> files, int count, int quality) async {
  final stride = (files.length / count).floor().clamp(1, files.length);
  final ratios = <double>[];
  var sourceBytes = 0, webpBytes = 0, beating = 0;

  for (var i = 0; i < files.length; i += stride) {
    final file = files[i];
    final image = await Image.read(file);
    final encoded = await image.encode(ImageFormat.webp, quality: Quality.fixed(quality));
    final source = await file.size();
    await image.close();
    sourceBytes += source;
    webpBytes += encoded.length;
    final ratio = 1 - encoded.length / source;
    ratios.add(ratio);
    if (ratio >= _reductionMin) beating++;
  }

  ratios.sort();
  double at(double fraction) => ratios[(ratios.length * fraction).clamp(0, ratios.length - 1).floor()];
  return (
    count: ratios.length,
    sourceBytes: sourceBytes,
    webpBytes: webpBytes,
    beating: beating,
    median: at(0.5),
    p10: at(0.1),
    p90: at(0.9),
    ratios: ratios,
  );
}

/// Every file through encode + thumbnail, written to disk, for the library-wide number.
Future<({int count, Duration elapsed, int sourceBytes, int webpBytes, List<double> ratios})> _fullLibrary(
  List<Path> files,
  int quality,
  int edge, {
  required bool keep,
}) async {
  var sourceBytes = 0, webpBytes = 0, count = 0;
  final ratios = <double>[];
  final watch = Stopwatch()..start();

  await Path.tempDir((out) async {
    for (final file in files) {
      final image = await Image.read(file);
      final webp = await image.save(out / file.withExt('webp').name, quality: Quality.fixed(quality));
      final thumb = _thumbnail(image, edge);
      await thumb.save(out / '${file.name}.thumb.jpg');
      await thumb.close();
      final source = await file.size();
      final encoded = await webp.size();
      sourceBytes += source;
      webpBytes += encoded;
      ratios.add(1 - encoded / source);
      await image.close();
      count++;
      if (count % 25 == 0) {
        Console.info(
          '  $count/${files.length} images, ${watch.elapsed.inSeconds} s, '
          '${ProcessInfo.currentRss.humanBytes} resident, ${sourceBytes.humanBytes} -> ${webpBytes.humanBytes}',
        );
      }
    }
    if (keep) Console.ok('Output kept in $out');
  });

  watch.stop();
  return (count: count, elapsed: watch.elapsed, sourceBytes: sourceBytes, webpBytes: webpBytes, ratios: ratios);
}

void main(List<String> args) => Cli(
  'Measure the image pipeline on a real photo library.',
  values: [_dir, _sample, _repeat, _quality, _edge, _spread, _full, _control, _keep],
  handler: _main,
).run(args);

/// Read, resize, crop, encode and compress images. Facade over ffmpeg
/// (downloaded once on first use when PATH has no fitting copy).
///
/// ```dart
/// final photo = await Fs.file('photo.heic').image();          // reads the header, decodes nothing
/// await (photo.crop(0, 0, 512, 512).resize(width: 256).encode(.webp) > Fs.file('a.webp'));
/// final saved = await Image.compress('photo.jpg', quality: 80);  // Compressed(before, after) or Kept(reason)
/// r.picture(await photo.pixels());                             // draw it in a Tui
/// ```
///
/// Public surface is exactly: [Image], [ImageFormat], [Pixels] (what
/// `pixels()` returns), and `compress`'s
/// [Compression] ([Compressed] or [Kept] with a [KeptReason]).
/// - `Reader.image()` reads any reader: a file in place (never copied into
///   memory), bytes (`Reader.of(bytes).image()`) or a stream spooled once.
/// - `Image.sniff()` names the format from the header bytes.
/// - `Image.compress()` re-encodes a file in its own format, replacing it
///   only when smaller.
/// - [Image] supports `width` `height` `format` `resize` `crop` `encode`
///   `pixels`. `resize`/`crop` only record a step: `encode` runs them all
///   in one ffmpeg call.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'core.dart';
import 'src/media.dart' as media;
import 'src/media.dart' show Compression, Compressed, Kept, KeptReason;
import 'src/pixels.dart';
export 'core.dart';
export 'src/media.dart' show Compression, Compressed, Kept, KeptReason;
export 'src/pixels.dart' show Pixels;

/// Images over this many pixels are refused (from the header, before
/// anything decodes): 16384 × 16384.
const _maxPixels = 1 << 28;

/// Image formats. [Image.sniff] names one; [Image.encode] writes all but
/// [heic] (read only: no free encoder). `.name` is the usual extension.
enum ImageFormat { png, jpg, gif, bmp, tiff, ico, webp, avif, heic }

/// An image: a source, its size as displayed, and the steps to apply.
final class Image {
  Image._(this._src, this._format, this._width, this._height, this._steps, this._header, this._grid, [this._temp]);

  final String _src;
  final ImageFormat _format;
  final int _width;
  final int _height;
  final List<String> _steps;
  final media.Header? _header;

  /// A HEIF tile grid: ffmpeg joins the tiles as stream group 0.
  final bool _grid;

  /// The spooled source, when this image owns one: deleted with the last
  /// image that holds it.
  final media.Temp? _temp;

  /// The format named by the magic bytes, or null when they are not an
  /// image. Reads the header only:
  /// `'page.${(Image.sniff(data) ?? .jpg).name}'` names a downloaded file.
  static ImageFormat? sniff(List<int> bytes) {
    bool at(int i, List<int> magic) {
      if (bytes.length < i + magic.length) return false;
      for (var k = 0; k < magic.length; k++) {
        if (bytes[i + k] != magic[k]) return false;
      }
      return true;
    }

    if (at(0, [0xFF, 0xD8, 0xFF])) return ImageFormat.jpg;
    if (at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return ImageFormat.png;
    if (at(0, [0x47, 0x49, 0x46, 0x38]) &&
        bytes.length >= 6 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      return ImageFormat.gif;
    }
    if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) return ImageFormat.webp;
    if (at(0, [0x42, 0x4D])) return ImageFormat.bmp;
    if (at(0, [0x49, 0x49, 0x2A, 0x00]) || at(0, [0x4D, 0x4D, 0x00, 0x2A])) return ImageFormat.tiff;
    if (at(0, [0x00, 0x00, 0x01, 0x00]) && bytes.length >= 6) return ImageFormat.ico;
    if (at(4, [0x66, 0x74, 0x79, 0x70])) {
      return switch (media.heif(bytes)) {
        'avif' => ImageFormat.avif,
        'heic' => ImageFormat.heic,
        _ => null,
      };
    }
    return null;
  }

  /// [path] read once: Dart's header reader for the common formats,
  /// ffprobe for the rest (HEIC/AVIF grids, TIFF, ICO).
  static Future<Image> _open(String path, ImageFormat format, Uint8List head, [media.Temp? temp]) async {
    final h = media.header(head);
    int w, ht;
    var grid = false;
    if (h != null) {
      final turned = h.orientation >= 5; // 5–8 swap the sides
      (w, ht) = turned ? (h.height, h.width) : (h.width, h.height);
    } else {
      (w, ht, grid) = await _probeSize(path);
    }
    if (w < 1 || ht < 1) throw ContentException('broken image header: ${w}x$ht');
    if (w * ht > _maxPixels) throw ContentException('image too large: ${w}x$ht');
    return Image._(path, format, w, ht, const [], h, grid, temp);
  }

  /// The displayed size ffprobe reports, and whether it is a tile grid: a
  /// grid's own size, else the first video stream's.
  static Future<(int, int, bool)> _probeSize(String path) async {
    final info = await media.ffprobe(media.file(path));
    for (final g in (info['stream_groups'] as List?) ?? const []) {
      final c = (g as Map)['components'];
      if (c is List && c.isNotEmpty && c.first is Map && (c.first as Map)['width'] is int) {
        return ((c.first as Map)['width'] as int, (c.first as Map)['height'] as int, true);
      }
    }
    for (final s in (info['streams'] as List?) ?? const []) {
      final m = s as Map;
      if (m['codec_type'] == 'video' && m['width'] is int) return (m['width'] as int, m['height'] as int, false);
    }
    throw const ContentException('no picture in this file');
  }

  /// Re-encode the image at [path] in its own format and replace it, atomically,
  /// only when the result is at least 5% smaller (so a second run is a no-op
  /// instead of another generation of loss). Returns [Compressed] with the
  /// sizes before and after, or [Kept] with the reason: not an image, one a
  /// re-encode would degrade (animated GIF/WebP/APNG, CMYK JPEG, HEIC, which
  /// has no encoder), one that does not decode, or no smaller (a disk or
  /// ffmpeg start failure still throws). JPEGs keep their EXIF (date, camera; orientation reset)
  /// and colour profile; a lossless WebP stays lossless.
  static Future<Compression> compress(String path, {int quality = 80}) async {
    media.checkQuality(quality);
    final file = io.File(path);
    final bytes = await file.readAsBytes();
    final format = sniff(bytes);
    if (format == null) return media.kept(KeptReason.unknown);
    if (!const {ImageFormat.jpg, ImageFormat.png, ImageFormat.webp, ImageFormat.avif}.contains(format)) {
      return media.kept(KeptReason.lossy);
    }
    final h = media.header(bytes);
    if (h != null && (h.animated || h.components == 4)) return media.kept(KeptReason.lossy);
    final Uint8List out;
    try {
      final image = await _open(path, format, bytes);
      final lossless = format == ImageFormat.webp && _isLosslessWebp(bytes);
      out = Uint8List.fromList(await image._encode(format, quality, lossless: lossless));
    } on ContentException {
      return media.kept(KeptReason.broken);
    }
    final tmp = p.join(p.dirname(path), '.${p.basename(path)}.compress');
    return media.deletedOnExit(tmp, () async {
      await io.File(tmp).writeAsBytes(format == ImageFormat.jpg ? media.withMetadata(out, bytes) : out, flush: true);
      return media.replaceIfSmaller(path, tmp, by: 0.05);
    });
  }

  /// Width in pixels, as displayed (EXIF orientation applied).
  int width() => _width;

  /// Height in pixels, as displayed.
  int height() => _height;

  /// The source format.
  ImageFormat format() => _format;

  Image _with(String step, int w, int h) => Image._(_src, _format, w, h, [..._steps, step], _header, _grid, _temp);

  /// A resized copy. Keeps the aspect ratio when only one side is given,
  /// sets the exact size when both are. Neither, or a non-positive size,
  /// is an [ArgumentError]. Shrinking averages the source area; enlarging
  /// is bicubic.
  Image resize({int? width, int? height}) {
    if (width == null && height == null) {
      throw ArgumentError('resize needs a width, a height, or both');
    }
    if ((width != null && width < 1) || (height != null && height < 1)) {
      throw ArgumentError.value(width ?? height, width != null ? 'width' : 'height', 'must be >= 1');
    }
    // A computed side is at least 1: 1000x1 at width 1 is 1x1, not 1x0.
    final w = width ?? math.max(1, (height! * _width / _height).round());
    final h = height ?? math.max(1, (width! * _height / _width).round());
    if (w * h > _maxPixels) throw ArgumentError.value('${w}x$h', 'width/height', 'is over $_maxPixels pixels');
    final shrinking = w * h < _width * _height;
    return _with('scale=$w:$h:flags=${shrinking ? 'area' : 'bicubic'}', w, h);
  }

  /// A cut-out copy. A bad size is an [ArgumentError]; a region leaving
  /// the image is a [RangeError].
  Image crop(int x, int y, int width, int height) {
    if (width < 1 || height < 1) {
      throw ArgumentError.value('${width}x$height', 'width/height', 'must be >= 1');
    }
    if (x < 0 || y < 0 || x + width > _width || y + height > _height) {
      throw RangeError('crop ($x,$y ${width}x$height) leaves ${_width}x$_height');
    }
    return _with('crop=$width:$height:$x:$y', width, height);
  }

  /// A [Reader] of the encoded image, encoded when read (lazily: nothing
  /// runs until the reader is stored). Store it with `> Fs.file(…)`, hash
  /// it, or upload it. [quality] (1–100) applies to JPEG, WebP and AVIF.
  /// A bad quality, [ImageFormat.heic] (read only) or an `.ico` over 256x256
  /// is an [ArgumentError] here, not when the reader is read.
  Reader encode(ImageFormat format, {int quality = 90}) {
    _checkEncode(format, quality, this);
    return _Encoded(() async => this, format, quality);
  }

  /// The pixels as 8-bit RGB, decoded now, scaled to [width]/[height] when
  /// given (a Tui picture needs few): `r.picture(await image.pixels(width: 80))`.
  Future<Pixels> pixels({int? width, int? height}) async {
    final img = width == null && height == null ? this : resize(width: width, height: height);
    final rgb = await media.ffmpeg([
      ...img._graph(img._steps),
      '-frames:v',
      '1',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'rgb24',
      'pipe:1',
    ]);
    if (rgb.length < img._width * img._height * 3) throw const ContentException('image decoded short');
    return _Rgb(img._width, img._height, rgb is Uint8List ? rgb : Uint8List.fromList(rgb));
  }

  /// Input and filter graph: a tile grid is fed from its stream group,
  /// which ffmpeg only allows in a complex graph, so every call uses one.
  List<String> _graph(List<String> steps) => [
    '-i',
    media.file(_src),
    '-filter_complex',
    '${_grid ? '[0:g:0]' : '[0:v:0]'}${steps.isEmpty ? 'null' : steps.join(',')}[o]',
    '-map',
    '[o]',
  ];

  Future<List<int>> _encode(ImageFormat format, int quality, {bool lossless = false}) async {
    final steps = [..._steps];
    final args = <String>[];
    var needs = const <String>{};
    switch (format) {
      case ImageFormat.jpg:
        // Calibrated by SSIM against the old pure-Dart encoder: quality 80 is
        // q:v 3 (SSIM 0.94 where the old one gave 0.91, and 4% smaller).
        args.addAll(['-c:v', 'mjpeg', '-q:v', '${math.max(2, (1 + (100 - quality) / 9).round())}', '-f', 'image2']);
      case ImageFormat.png:
        args.addAll(['-c:v', 'png', '-f', 'image2']);
      case ImageFormat.webp:
        needs = const {'libwebp'};
        args.addAll([
          '-c:v',
          'libwebp',
          if (lossless) ...['-lossless', '1'] else ...['-quality', '$quality'],
          '-f',
          'webp',
        ]);
      case ImageFormat.avif:
        needs = const {'libaom-av1'};
        final crf = (63 - (quality - 1) * 53 / 99).round();
        args.addAll([
          '-c:v',
          'libaom-av1',
          '-still-picture',
          '1',
          '-crf',
          '$crf',
          '-cpu-used',
          '6',
          '-row-mt',
          '1',
          '-f',
          'avif',
        ]);
      case ImageFormat.gif:
        steps.add('split[a][b];[a]palettegen[p];[b][p]paletteuse');
        args.addAll(['-f', 'gif']);
      case ImageFormat.bmp:
        args.addAll(['-c:v', 'bmp', '-f', 'image2']);
      case ImageFormat.tiff:
        args.addAll(['-c:v', 'tiff', '-f', 'image2']);
      case ImageFormat.ico:
        args.addAll(['-c:v', 'png', '-pix_fmt', 'rgba', '-f', 'ico']);
      case ImageFormat.heic:
        throw ArgumentError.value(format, 'format', 'heic can be read, not written: use jpg, webp or avif');
    }
    final out = await media.tempOut(format.name);
    try {
      await media.ffmpeg([..._graph(steps), '-frames:v', '1', '-map_metadata', '-1', ...args, '-y', out], needs: needs);
      return await io.File(out).readAsBytes();
    } finally {
      await io.File(out).delete().catchError((_) => io.File(out));
    }
  }
}

bool _isLosslessWebp(Uint8List b) {
  for (var i = 12; i + 4 <= math.min(b.length, 64); i++) {
    if (b[i] == 0x56 && b[i + 1] == 0x50 && b[i + 2] == 0x38 && b[i + 3] == 0x4C) return true; // VP8L
  }
  return false;
}


/// Refuse what [Image._encode] cannot write, up front.
void _checkEncode(ImageFormat format, int quality, Image? image) {
  media.checkQuality(quality);
  if (format == ImageFormat.heic) {
    throw ArgumentError.value(format, 'format', 'heic can be read, not written: use jpg, webp or avif');
  }
  if (format == ImageFormat.ico && image != null && (image.width() > 256 || image.height() > 256)) {
    throw ArgumentError.value('${image.width()}x${image.height()}', 'image', '.ico supports at most 256x256');
  }
}

final class _Rgb implements Pixels {
  _Rgb(this._w, this._h, this._rgb);

  final int _w;
  final int _h;
  final Uint8List _rgb;

  @override
  int width() => _w;

  @override
  int height() => _h;

  @override
  (int, int, int) pixel(int x, int y) {
    final i = (y * _w + x) * 3;
    return (_rgb[i], _rgb[i + 1], _rgb[i + 2]);
  }
}

/// Bytes → a value.
extension ReaderImage on Reader {
  /// Read the image: a file is read in place, any other stream is written
  /// to a temp file once (never held in memory).
  Future<Image> image() async {
    final path = origin().path();
    if (path != null && await io.File(path).exists()) {
      final head = await _head(path);
      final format = Image.sniff(head);
      if (format == null) throw const ContentException('unknown image format');
      return Image._open(path, format, head);
    }
    // Spooled as it streams: the first 64 KiB name the format and size.
    final head = BytesBuilder(copy: false);
    final temp = media.Temp(
      await media.spool(
        stream().map((chunk) {
          if (head.length < 64 << 10) head.add(chunk);
          return chunk;
        }),
      ),
    );
    final first = head.takeBytes();
    final format = Image.sniff(first);
    if (format == null) throw const ContentException('unknown image format');
    // A GIF's frame count needs the whole file.
    final bytes = format == ImageFormat.gif ? await io.File(temp.path).readAsBytes() : first;
    return Image._open(temp.path, format, bytes, temp);
  }
}

/// The first bytes of [path]: enough for every header [media.header] reads
/// except a GIF's frame count, which needs the whole file.
Future<Uint8List> _head(String path) async {
  final f = await io.File(path).open();
  try {
    final first = await f.read(64 << 10);
    if (first.length >= 3 && first[0] == 0x47 && first[1] == 0x49 && first[2] == 0x46) {
      return await io.File(path).readAsBytes();
    }
    return first;
  } finally {
    await f.close();
  }
}

/// Same, from an async reader.
extension ReaderFutureImage on Future<Reader> {
  /// Read the image (see [ReaderImage.image]).
  Future<Image> image() async => (await this).image();
}

/// Future mirrors (rule 4). The extension name is import-only; never reference it.
extension ImageFuture on Future<Image> {
  Future<int> width() async => (await this).width();
  Future<int> height() async => (await this).height();
  Future<ImageFormat> format() async => (await this).format();
  Future<Image> resize({int? width, int? height}) async => (await this).resize(width: width, height: height);
  Future<Image> crop(int x, int y, int width, int height) async => (await this).crop(x, y, width, height);
  Future<Pixels> pixels({int? width, int? height}) async => (await this).pixels(width: width, height: height);
  Reader encode(ImageFormat format, {int quality = 90}) {
    _checkEncode(format, quality, null);
    return _Encoded(() => this, format, quality);
  }
}

final class _Encoded with Reader {
  _Encoded(this._image, this._format, this._quality);

  final Future<Image> Function() _image;
  final ImageFormat _format;
  final int _quality;

  @override
  Stream<List<int>> stream() async* {
    final image = await _image();
    _checkEncode(_format, _quality, image);
    yield await image._encode(_format, _quality);
  }
}

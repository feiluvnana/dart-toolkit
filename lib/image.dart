/// Decode, transform, and encode images. Thin facade over `package:image`.
///
/// ```dart
/// final avatar = await Http.get(avatarUrl).image().crop(0, 0, 256, 256);
/// await (avatar.encode(ImageFormat.png) > Fs.file('avatar.png'));
/// await (avatar.resize(width: 64).encode(ImageFormat.png) > Fs.file('icon.png'));
/// ```
///
/// Public surface is exactly: [Image], [ImageFormat].
/// - `Image.decode()` decodes bytes, `Reader.image()` reads a stream.
/// - `Image.sniff()` names the format from the header bytes.
/// - [Image] supports `width` `height` `pixel` `resize` `crop` `encode`.
/// - `region.picture(image)` draws it in a `Tui` (neither module loads the
///   other).
/// Small images convert inline. Above [_isolatePixels] (decode reads the
/// size from the header) the work goes through [Isolate.run] — whose result comes back
/// through [Isolate.exit] without a copy — so a large photo never freezes
/// the event loop under a `Console` spinner or a `Tui` frame.
/// CPU-bound batches go through Pool.runAll (see pool.dart).
/// Everything else is private.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'core.dart';
import 'src/pixels.dart';
export 'core.dart';

/// Above this many pixels, decode/resize/encode run on a worker isolate via
/// [Isolate.run] instead of blocking the event loop.
const _isolatePixels = 1000000;

/// Larger declared sizes are refused before decoding (decompression bomb).
const _maxPixels = 100000000;

/// Image formats: [Image.sniff] names one, [Image.encode] writes all but
/// [webp] (decoded, never encoded). `.name` is the usual file extension.
enum ImageFormat { png, jpg, gif, bmp, tiff, ico, webp }

/// An image value.
final class Image implements Pixels {
  Image._(this._inner);

  final img.Image _inner;

  /// The format named by the magic bytes, or null when they are not an
  /// image. Reads the header only, no decode:
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
    if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) {
      return ImageFormat.webp;
    }
    if (at(0, [0x42, 0x4D])) return ImageFormat.bmp;
    if (at(0, [0x49, 0x49, 0x2A, 0x00]) || at(0, [0x4D, 0x4D, 0x00, 0x2A])) {
      return ImageFormat.tiff;
    }
    if (at(0, [0x00, 0x00, 0x01, 0x00]) && bytes.length >= 6) return ImageFormat.ico;
    return null;
  }

  /// Decode [bytes] (PNG, JPEG, GIF first frame, BMP, WebP, TIFF, ICO).
  /// Applies the EXIF orientation, so [width]/[height] are the size as
  /// displayed. An unknown format is a [FormatException].
  ///
  /// Inline, on this isolate: for a large photo prefer `Reader.image()`,
  /// which decodes off the main isolate.
  static Image decode(List<int> bytes) {
    img.Image? decoded;
    try {
      // frame: 0 keeps GIF to its first frame (an animated GIF otherwise
      // decodes every frame and re-encodes as animated).
      // Inputs arrive as Uint8List through the zero-copy readers, so this
      // takes them as is; anything else is converted once.
      final raw = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      final (w, h) = _declaredSize(raw);
      if (w * h > _maxPixels) throw FormatException('image too large: ${w}x$h');
      decoded = img.decodeImage(raw, frame: 0);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('unknown image format: $e');
    }
    if (decoded == null) {
      throw const FormatException('unknown image format');
    }
    // bakeOrientation always copies the pixels; most images need no turn.
    final ifd = decoded.exif.imageIfd;
    final turned = ifd.hasOrientation && ifd.orientation != 1;
    return Image._(turned ? img.bakeOrientation(decoded) : decoded);
  }

  /// Width in pixels, as displayed.
  @override
  int width() => _inner.width;

  /// Height in pixels, as displayed.
  @override
  int height() => _inner.height;

  /// The colour at ([x], [y]) as 8-bit (r, g, b).
  @override
  (int, int, int) pixel(int x, int y) {
    final p = _inner.getPixel(x, y);
    return (
      (p.rNormalized * 255).round().clamp(0, 255),
      (p.gNormalized * 255).round().clamp(0, 255),
      (p.bNormalized * 255).round().clamp(0, 255),
    );
  }

  /// A resized copy. Keeps the aspect ratio when only one side is given,
  /// sets the exact size when both are. Neither, or a non-positive size,
  /// is an [ArgumentError]. Shrinking averages the source area (nearest
  /// neighbour aliases); enlarging uses cubic interpolation.
  ///
  /// Inline, on this isolate: batch resizes go through Pool.runAll
  /// (see pool.dart), and the `Future<Image>` mirror below offloads large
  /// images to a worker isolate.
  Image resize({int? width, int? height}) {
    if (width == null && height == null) {
      throw ArgumentError('resize needs a width, a height, or both');
    }
    if ((width != null && width < 1) || (height != null && height < 1)) {
      throw ArgumentError.value(
        width ?? height,
        width != null ? 'width' : 'height',
        'must be >= 1',
      );
    }
    final targetWidth =
        width ?? (height! * _inner.width / _inner.height).round();
    final targetHeight =
        height ?? (width! * _inner.height / _inner.width).round();
    final shrinking =
        targetWidth * targetHeight < _inner.width * _inner.height;
    return Image._(img.copyResize(_inner,
        width: width,
        height: height,
        interpolation: shrinking
            ? img.Interpolation.average
            : img.Interpolation.cubic));
  }

  /// A cut-out copy. A bad size is an [ArgumentError]; a region leaving
  /// the image is a [RangeError].
  Image crop(int x, int y, int width, int height) {
    if (width < 1 || height < 1) {
      throw ArgumentError.value(
        '${width}x$height',
        'width/height',
        'must be >= 1',
      );
    }
    if (x < 0 ||
        y < 0 ||
        x + width > _inner.width ||
        y + height > _inner.height) {
      throw RangeError(
        'crop ($x,$y ${width}x$height) leaves '
        '${_inner.width}x${_inner.height}',
      );
    }
    return Image._(
      img.copyCrop(_inner, x: x, y: y, width: width, height: height),
    );
  }

  /// A [Reader] of the encoded image, encoded when read (lazily: nothing
  /// runs until the reader is stored). Large images encode on a worker
  /// isolate. Store it with `> Fs.file(…)`, hash it, or upload it.
  /// [quality] applies to JPEG (1–100, else [ArgumentError]).
  Reader encode(ImageFormat format, {int quality = 90}) {
    if (quality < 1 || quality > 100) {
      throw ArgumentError.value(quality, 'quality', 'must be 1..100');
    }
    return _Encoded(this, format, quality: quality);
  }
}

/// Declared size from the header, `(0, 0)` when it cannot be read.
(int, int) _declaredSize(Uint8List raw) {
  try {
    final info = img.findDecoderForData(raw)?.startDecode(raw);
    if (info is img.IcoInfo) {
      // An ICO reports 0x0; the first entry (the one decoded) may wrap a PNG
      // that declares any size, so judge that entry's own header.
      if (info.images.isEmpty) return (0, 0);
      final e = info.images.first;
      final end = e.bytesOffset + e.bytesSize;
      if (e.bytesOffset < 0 || end > raw.length) return (0, 0);
      final inner = Uint8List.sublistView(raw, e.bytesOffset, end);
      final png = img.PngDecoder().startDecode(inner);
      return png != null ? (png.width, png.height) : (e.width == 0 ? 256 : e.width, e.height == 0 ? 256 : e.height);
    }
    return info == null ? (0, 0) : (info.width, info.height);
  } catch (_) {
    return (0, 0);
  }
}

/// Decode on a worker isolate when the header declares a large image.
Future<Image> _decodeAsync(Uint8List bytes) {
  final (w, h) = _declaredSize(bytes);
  if (w * h <= _isolatePixels) {
    return Future.value(Image.decode(bytes));
  }
  return Isolate.run(() => Image.decode(bytes));
}

/// Resize on a worker isolate for large images.
Future<Image> _resizeAsync(Image image, {int? width, int? height}) {
  if (image._inner.width * image._inner.height <= _isolatePixels) {
    return Future.value(image.resize(width: width, height: height));
  }
  return Isolate.run(() => image.resize(width: width, height: height));
}

/// Encode on a worker isolate for large images.
Future<List<int>> _encodeAsync(Image image, ImageFormat format, int quality) {
  if (image._inner.width * image._inner.height <= _isolatePixels) {
    return Future.value(_encode(image, format, quality));
  }
  return Isolate.run(() => _encode(image, format, quality));
}

/// The stream's bytes as a [Uint8List] without copying: core's readers
/// already hand over [Uint8List] chunks.
Future<Uint8List> _readBytes(Reader reader) async {
  final bytes = await reader.bytes();
  return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}

/// Bytes → a value.
extension ReaderImage on Reader {
  /// Decode the stream; large inputs decode on a worker isolate.
  Future<Image> image() async => _decodeAsync(await _readBytes(this));
}

/// Same, from an async reader.
extension ReaderFutureImage on Future<Reader> {
  /// Decode the stream; large inputs decode on a worker isolate.
  Future<Image> image() async => (await this).image();
}

/// Future mirrors (rule 6). The extension name is import-only; never reference it.
extension ImageFuture on Future<Image> {
  Future<int> width() async => (await this).width();
  Future<int> height() async => (await this).height();

  /// Resize; large images resize on a worker isolate.
  Future<Image> resize({int? width, int? height}) async =>
      _resizeAsync(await this, width: width, height: height);
  Future<Image> crop(int x, int y, int width, int height) async =>
      (await this).crop(x, y, width, height);
  Reader encode(ImageFormat format, {int quality = 90}) {
    if (quality < 1 || quality > 100) {
      throw ArgumentError.value(quality, 'quality', 'must be 1..100');
    }
    return _FutureEncoded(this, format, quality: quality);
  }
}

final class _Encoded with Reader {
  _Encoded(this._image, this._format, {required this.quality});

  final Image _image;
  final ImageFormat _format;
  final int quality;

  @override
  Stream<List<int>> stream() async* {
    yield await _encodeAsync(_image, _format, quality);
  }
}

final class _FutureEncoded with Reader {
  _FutureEncoded(this._future, this._format, {required this.quality});

  final Future<Image> _future;
  final ImageFormat _format;
  final int quality;

  @override
  Stream<List<int>> stream() async* {
    final image = await _future;
    yield await _encodeAsync(image, _format, quality);
  }
}

List<int> _encode(Image image, ImageFormat format, int quality) {
  final inner = image._inner;
  switch (format) {
    case ImageFormat.png:
      return img.encodePng(inner);
    case ImageFormat.jpg:
      return img.encodeJpg(inner, quality: quality);
    case ImageFormat.gif:
      return img.encodeGif(inner);
    case ImageFormat.bmp:
      return img.encodeBmp(inner);
    case ImageFormat.tiff:
      return img.encodeTiff(inner);
    case ImageFormat.webp:
      throw ArgumentError.value(format, 'format', 'webp can be decoded, not encoded: use png or jpg');
    case ImageFormat.ico:
      if (inner.width > 256 || inner.height > 256) {
        throw ArgumentError.value(
          '${inner.width}x${inner.height}',
          'image',
          '.ico supports at most 256x256',
        );
      }
      return img.encodeIco(inner);
  }
}

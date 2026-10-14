/// Decode, transform, and encode images. Thin facade over `package:image`.
///
/// ```dart
/// final avatar = await Http.get(avatarUrl).image().crop(0, 0, 256, 256);
/// await (avatar.encode(ImageFormat.png) > Fs.file('avatar.png'));
/// await (avatar.resize(width: 64).encode(ImageFormat.png) > Fs.file('icon.png'));
/// ```
///
/// Public surface is exactly: [Image], [ImageFormat], [RegionPicture].
/// - `Image.decode()` decodes bytes, `Reader.image()` reads a stream.
/// - [Image] supports `width` `height` `resize` `crop` `encode`.
/// - `region.picture(image)` draws it in a `Tui` (here, so `tui` doesn't
///   load the codecs).
/// Small images convert inline. Above [_isolatePixels] (decode is proxied by
/// [_isolateBytes] of input, since the pixel count is only known after
/// decoding) the work goes through [Isolate.run] — whose result comes back
/// through [Isolate.exit] without a copy — so a large photo never freezes
/// the event loop under a `Console` spinner or a `Tui` frame.
/// CPU-bound batches go through Pool.computeAll (see pool.dart).
/// Everything else is private.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'core.dart';
import 'src/tui.dart' show Region, drawPicture;
export 'core.dart';

/// Above this many pixels, decode/resize/encode run on a worker isolate via
/// [Isolate.run] instead of blocking the event loop.
const _isolatePixels = 1000000;

/// Above this many input bytes, decoding goes through [Isolate.run]: the
/// pixel count is only known after decoding, so the byte size is the proxy.
const _isolateBytes = 1 << 20;

/// Encodable image formats. WebP decodes but the engine cannot encode it,
/// so it is not listed.
enum ImageFormat { png, jpg, gif, bmp, tiff, ico }

/// An image value.
final class Image {
  Image._(this._inner);

  final img.Image _inner;

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
      decoded = img.decodeImage(raw, frame: 0);
    } catch (e) {
      throw FormatException('unknown image format: $e');
    }
    if (decoded == null) {
      throw const FormatException('unknown image format');
    }
    return Image._(img.bakeOrientation(decoded));
  }

  /// Width in pixels, as displayed.
  int width() => _inner.width;

  /// Height in pixels, as displayed.
  int height() => _inner.height;

  /// A resized copy. Keeps the aspect ratio when only one side is given,
  /// sets the exact size when both are. Neither, or a non-positive size,
  /// is an [ArgumentError]. Shrinking averages the source area (nearest
  /// neighbour aliases); enlarging uses cubic interpolation.
  ///
  /// Inline, on this isolate: batch resizes go through Pool.computeAll
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

/// Decode on a worker isolate when the input looks like a large image.
Future<Image> _decodeAsync(Uint8List bytes) {
  if (bytes.lengthInBytes <= _isolateBytes) {
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

/// Draws an [Image] in a `Tui` region.
extension RegionPicture on Region {
  /// The rest of the region as half-block cells (`▀`), scaled down to fit
  /// with the aspect kept. Returns the receiver.
  Region picture(Image image) {
    final inner = image._inner;
    return drawPicture(this, inner.width, inner.height, (x, y) {
      final p = inner.getPixel(x, y);
      return (
        (p.rNormalized * 255).round().clamp(0, 255),
        (p.gNormalized * 255).round().clamp(0, 255),
        (p.bNormalized * 255).round().clamp(0, 255),
      );
    });
  }
}

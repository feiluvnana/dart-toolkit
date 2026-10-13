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
/// CPU-bound batches go through [Pool]. Everything else is private.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'core.dart';
import 'src/tui.dart' show Region, drawPicture;
export 'core.dart';

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
  static Image decode(List<int> bytes) {
    img.Image? decoded;
    try {
      // frame: 0 keeps GIF to its first frame (an animated GIF otherwise
      // decodes every frame and re-encodes as animated).
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
  /// is an [ArgumentError].
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
    return Image._(
      img.copyResize(_inner, width: width, height: height),
    );
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

  /// A [Reader] of the encoded image, encoded when read. Store it with
  /// `> Fs.file(…)`, hash it, or upload it with `body:`. [quality] applies
  /// to JPEG (1–100, else [ArgumentError]).
  Reader encode(ImageFormat format, {int quality = 90}) {
    if (quality < 1 || quality > 100) {
      throw ArgumentError.value(quality, 'quality', 'must be 1..100');
    }
    return _Encoded(this, format, quality: quality);
  }
}

/// Bytes → a value.
extension ReaderImage on Reader {
  Future<Image> image() async => Image.decode(await bytes());
}

/// Same, from an async reader.
extension ReaderFutureImage on Future<Reader> {
  Future<Image> image() async => (await this).image();
}

/// Future mirrors (rule 6). The extension name is import-only; never reference it.
extension ImageFuture on Future<Image> {
  Future<int> width() async => (await this).width();
  Future<int> height() async => (await this).height();
  Future<Image> resize({int? width, int? height}) async =>
      (await this).resize(width: width, height: height);
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
    yield _encode(_image, _format, quality);
  }
}

final class _FutureEncoded with Reader {
  _FutureEncoded(this._future, this._format, {required this.quality});

  final Future<Image> _future;
  final ImageFormat _format;
  final int quality;

  @override
  Stream<List<int>> stream() async* {
    yield _encode(await _future, _format, quality);
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
      return (p.r.toInt(), p.g.toInt(), p.b.toInt());
    });
  }
}

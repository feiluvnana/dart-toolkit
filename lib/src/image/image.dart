import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/native.dart' as l2native;
import '../core/pipe.dart';
import '../core/traits.dart';
import '../fs/io.dart' as fs;

export '../core/errors.dart';
export '../core/pipe.dart';
export '../core/traits.dart';

/// An immutable in-memory 8-bit RGBA raster with one-word transforms ([crop],
/// [fit], [resize], [grayscale], [blur], [draw]) and codec load/save.
///
/// Codecs run natively (`tk_image_*`); without the library decode and encode
/// are an [UnsupportedError] (rule 42), except QOI encode, which is the Dart codec
/// (the engine has no QOI writer).
///
/// ```dart
/// final img = Image.empty(100, 50);
/// final cut = img.crop(10, 10, 30, 20);
/// final thumb = img.fit(150, 150);
/// await thumb.save(File('thumb.png'));
/// ```
final class Image {
  final int w;
  final int h;
  final Uint8List rgba;

  Image._(this.w, this.h, this.rgba);

  /// A blank [w]x[h] image filled with [color] (`0xAARRGGBB`).
  factory Image.empty(int w, int h, {int color = 0x00000000}) {
    final img = Image._(w, h, Uint8List(w * h * 4));
    return color == 0 ? img : img.fill(color);
  }

  /// Wraps [rgba] (`w*h*4` bytes) as an image.
  factory Image.fromRgba(Uint8List rgba, int w, int h) {
    if (rgba.length != w * h * 4) {
      throw ArgumentError.value(rgba, 'rgba', 'Must hold w*h*4 bytes, holds ${rgba.length}');
    }
    return Image._(w, h, rgba);
  }

  /// Decodes the image in [data] (format detected from magic bytes) through
  /// the native engine. Unknown bytes are a [FormatException]; without the
  /// library it is an [UnsupportedError].
  static Future<Image> decode(List<int> data) async {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    if (formatOf(bytes) == null) throw const FormatException('Not an image: unknown format');
    return _nativeDecode(bytes);
  }

  /// The format of [data] from its magic bytes (`png`, `jpeg`, `gif`,
  /// `webp`, `bmp`, `qoi`, `tiff`), or `null` when it is none of them.
  static String? formatOf(List<int> data) {
    if (_isPng(data)) return 'png';
    if (_isJpeg(data)) return 'jpeg';
    if (_isGif(data)) return 'gif';
    if (_isWebp(data)) return 'webp';
    if (_isBmp(data)) return 'bmp';
    if (_isQoi(data)) return 'qoi';
    if (_isTiff(data)) return 'tiff';
    return null;
  }

  /// The pixel at ([x], [y]) as `0xAARRGGBB`.
  int pixel(int x, int y) {
    final i = (y * w + x) * 4;
    return (rgba[i + 3] << 24) | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
  }

  /// A copy filled with [color] (`0xAARRGGBB`); the receiver is unchanged.
  Image fill(int color) {
    final a = (color >>> 24) & 0xFF, r = (color >>> 16) & 0xFF, g = (color >>> 8) & 0xFF, b = color & 0xFF;
    final out = Uint8List(rgba.length);
    for (var i = 0; i < out.length; i += 4) {
      out[i] = r;
      out[i + 1] = g;
      out[i + 2] = b;
      out[i + 3] = a;
    }
    return Image._(w, h, out);
  }

  /// A [w]x[h] region anchored at ([x], [y]).
  Image crop(int x, int y, int w, int h) {
    final out = Uint8List(w * h * 4);
    for (var row = 0; row < h; row++) {
      final sy = y + row;
      if (sy < 0 || sy >= this.h) continue;
      for (var col = 0; col < w; col++) {
        final sx = x + col;
        if (sx < 0 || sx >= this.w) continue;
        final src = (sy * this.w + sx) * 4;
        final dst = (row * w + col) * 4;
        out[dst] = rgba[src];
        out[dst + 1] = rgba[src + 1];
        out[dst + 2] = rgba[src + 2];
        out[dst + 3] = rgba[src + 3];
      }
    }
    return Image._(w, h, out);
  }

  /// Scales to the largest size fitting inside [maxW]x[maxH], preserving aspect ratio.
  Image fit(int maxW, int maxH) {
    final scale = math.min(maxW / w, maxH / h);
    final nw = math.max(1, (w * scale).round());
    final nh = math.max(1, (h * scale).round());
    return resize(nw, nh);
  }

  /// Scales to exactly [nw]x[nh] (nearest neighbour).
  Image resize(int nw, int nh) {
    final out = Uint8List(nw * nh * 4);
    for (var y = 0; y < nh; y++) {
      final sy = (y * h / nh).floor().clamp(0, h - 1);
      for (var x = 0; x < nw; x++) {
        final sx = (x * w / nw).floor().clamp(0, w - 1);
        final src = (sy * w + sx) * 4;
        final dst = (y * nw + x) * 4;
        out[dst] = rgba[src];
        out[dst + 1] = rgba[src + 1];
        out[dst + 2] = rgba[src + 2];
        out[dst + 3] = rgba[src + 3];
      }
    }
    return Image._(nw, nh, out);
  }

  /// A greyscale copy using luma weights.
  Image grayscale() {
    final out = Uint8List.fromList(rgba);
    for (var i = 0; i < out.length; i += 4) {
      final v = (0.299 * out[i] + 0.587 * out[i + 1] + 0.114 * out[i + 2]).round().clamp(0, 255);
      out[i] = v;
      out[i + 1] = v;
      out[i + 2] = v;
    }
    return Image._(w, h, out);
  }

  /// A blurred copy (separable box blur, [radius] pixels each way; `0` is a
  /// copy). A solid image stays solid.
  Image blur(int radius) {
    if (radius < 0) throw ArgumentError.value(radius, 'radius', 'Must be non-negative');
    if (radius == 0) return Image._(w, h, Uint8List.fromList(rgba));
    final tmp = Uint8List(w * h * 4);
    final out = Uint8List(w * h * 4);
    final window = 2 * radius + 1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        for (var c = 0; c < 4; c++) {
          var sum = 0;
          for (var k = -radius; k <= radius; k++) {
            sum += rgba[((y * w + (x + k).clamp(0, w - 1)) * 4) + c];
          }
          tmp[((y * w + x) * 4) + c] = sum ~/ window;
        }
      }
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        for (var c = 0; c < 4; c++) {
          var sum = 0;
          for (var k = -radius; k <= radius; k++) {
            sum += tmp[((((y + k).clamp(0, h - 1)) * w + x) * 4) + c];
          }
          out[((y * w + x) * 4) + c] = sum ~/ window;
        }
      }
    }
    return Image._(w, h, out);
  }

  /// A copy with [src] composited over it at ([x], [y]) under [opacity]
  /// (source-over, clipped to the bounds): watermarks and overlays.
  Image draw(Image src, {int x = 0, int y = 0, double opacity = 1.0}) {
    if (opacity < 0 || opacity > 1 || !opacity.isFinite) {
      throw ArgumentError.value(opacity, 'opacity', 'Must be 0 to 1');
    }
    final out = Uint8List.fromList(rgba);
    for (var sy = 0; sy < src.h; sy++) {
      final dy = y + sy;
      if (dy < 0 || dy >= h) continue;
      for (var sx = 0; sx < src.w; sx++) {
        final dx = x + sx;
        if (dx < 0 || dx >= w) continue;
        final s = (sy * src.w + sx) * 4;
        final d = (dy * w + dx) * 4;
        final a = src.rgba[s + 3] / 255 * opacity;
        for (var c = 0; c < 3; c++) {
          out[d + c] = (src.rgba[s + c] * a + out[d + c] * (1 - a)).round().clamp(0, 255);
        }
        out[d + 3] = (255 * (a + (out[d + 3] / 255) * (1 - a))).round().clamp(0, 255);
      }
    }
    return Image._(w, h, out);
  }

  /// Encodes this image (`png`, `jpeg`, `webp`, `gif`, `qoi`, `bmp`, `tiff`)
  /// through the native engine. [quality] (0–100) applies to JPEG/WebP only;
  /// PNG ignores it. QOI encodes in Dart (the engine has no QOI writer).
  Uint8List encode({String format = 'png', int? quality}) {
    switch (format.toLowerCase()) {
      case 'png':
        return _encodeNative(this, 2, 0, format);
      case 'qoi':
        return _encodeQoi(this);
      case 'jpeg' || 'jpg':
        return _encodeNative(this, 1, _checkedQuality(quality, 80), format);
      case 'webp':
        return _encodeNative(this, 3, _checkedQuality(quality, 80), format);
      case 'gif':
        return _encodeNative(this, 4, 0, format);
      case 'bmp':
        return _encodeNative(this, 5, 0, format);
      case 'tiff' || 'tif':
        return _encodeNative(this, 6, 0, format);
      default:
        throw ArgumentError.value(format, 'format', 'Unknown image format');
    }
  }

  /// Writes this image to [to] (the extension picks the format; `png`
  /// default). [quality] (0–100) applies to JPEG/WebP only; PNG ignores it.
  /// The write is atomic: the encoding pipes through a temporary sibling.
  Future<void> save(fs.File to, {int? quality}) async {
    await encode(format: _formatFor(to.path), quality: quality).pipe(to);
  }

  /// Composes a `w x h` [Image] of the raw pixel buffer length check.
  @override
  String toString() => 'Image(${w}x$h)';

  /// Reads the image file at [path] through the native engine.
  static Future<Image> _nativeLoadPath(String path) async => decode(await File(path).readAsBytes());
}

/// `File('photo.jpg').image()`, `Http.get(u).image()`.
extension SourceImage on Source {
  /// Decodes this source as an image: a file loads by path, anything else
  /// decodes its bytes.
  Future<Image> image() async =>
      this is fs.File ? Image._nativeLoadPath((this as fs.File).path) : Image.decode(await bytes());
}

/// Chained transforms on a future image: `File('a.png').image().fit(8, 8)`.
extension FutureImage on Future<Image> {
  Future<Image> fit(int w, int h) async => (await this).fit(w, h);
  Future<Image> resize(int w, int h) async => (await this).resize(w, h);
  Future<Image> crop(int x, int y, int w, int h) async => (await this).crop(x, y, w, h);
  Future<Image> blur(int radius) async => (await this).blur(radius);
  Future<Image> grayscale() async => (await this).grayscale();
  Future<Image> fill(int color) async => (await this).fill(color);
  Future<Image> draw(Image src, {int x = 0, int y = 0, double opacity = 1.0}) async =>
      (await this).draw(src, x: x, y: y, opacity: opacity);
  Future<Uint8List> encode({String format = 'png', int? quality}) async =>
      (await this).encode(format: format, quality: quality);
  Future<void> save(fs.File to, {int? quality}) async => (await this).save(to, quality: quality);
}

bool _isPng(List<int> b) =>
    b.length >= 8 &&
    b[0] == 137 &&
    b[1] == 80 &&
    b[2] == 78 &&
    b[3] == 71 &&
    b[4] == 13 &&
    b[5] == 10 &&
    b[6] == 26 &&
    b[7] == 10;

bool _isJpeg(List<int> b) => b.length >= 2 && b[0] == 0xFF && b[1] == 0xD8;

bool _isGif(List<int> b) =>
    b.length >= 6 &&
    b[0] == 0x47 &&
    b[1] == 0x49 &&
    b[2] == 0x46 &&
    b[3] == 0x38 &&
    (b[4] == 0x37 || b[4] == 0x39) &&
    b[5] == 0x61;

bool _isWebp(List<int> b) =>
    b.length >= 12 &&
    b[0] == 0x52 &&
    b[1] == 0x49 &&
    b[2] == 0x46 &&
    b[3] == 0x46 &&
    b[8] == 0x57 &&
    b[9] == 0x45 &&
    b[10] == 0x42 &&
    b[11] == 0x50;

bool _isBmp(List<int> b) => b.length >= 2 && b[0] == 0x42 && b[1] == 0x4D;

bool _isQoi(List<int> b) => b.length >= 14 && b[0] == 0x71 && b[1] == 0x6F && b[2] == 0x69 && b[3] == 0x66;

bool _isTiff(List<int> b) =>
    b.length >= 4 &&
    ((b[0] == 0x49 && b[1] == 0x49 && b[2] == 42 && b[3] == 0) ||
        (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0 && b[3] == 42));

/// [quality] defaulted and range-checked (0–100) for JPEG/WebP.
int _checkedQuality(int? quality, int or) {
  final q = quality ?? or;
  if (q < 0 || q > 100) throw ArgumentError.value(quality, 'quality', 'Must be 0 to 100');
  return q;
}

/// The encode format for a [path]'s extension.
String _formatFor(String path) {
  final p = path.toLowerCase();
  if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'jpeg';
  if (p.endsWith('.webp')) return 'webp';
  if (p.endsWith('.gif')) return 'gif';
  if (p.endsWith('.bmp')) return 'bmp';
  if (p.endsWith('.qoi')) return 'qoi';
  return 'png';
}

/// The native image calls behind decode/encode (cutover: the engine owns every
/// codec; RGBA crosses through `from_rgba`/`to_rgba`, so no finalizer is needed).
abstract final class _ImageNative {
  static ffi.DynamicLibrary get _lib => l2native.require();

  static final loadMemory = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr, ffi.Uint32, ffi.Uint32),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>, int, int, int)
      >('tk_image_load_memory');

  static final encodeMemory = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
          ffi.Uint8,
          ffi.Bool,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          int,
          int,
          bool,
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
          ffi.Pointer<ffi.IntPtr>,
        )
      >('tk_image_encode_memory');

  static final free = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>), void Function(ffi.Pointer<ffi.Void>)>('tk_image_free');

  static final fromRgba = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr, ffi.Uint32, ffi.Uint32),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>, int, int, int)
      >('tk_image_from_rgba');

  static final toRgba = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int)
      >('tk_image_to_rgba');

  static final dimensions = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint32>),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint32>)
      >('tk_image_dimensions');
}

/// Decodes [data] through the native library into RGBA. Corrupt data is a
/// [FormatException] naming what the library said; without the library it is
/// an [UnsupportedError] (rule 42: no Dart fallback at cutover).
Image _nativeDecode(Uint8List data) {
  return l2native.withBytes(data, (p, n) {
    final h = _ImageNative.loadMemory(p, n, 0, 0);
    if (h == ffi.nullptr) throw FormatException('Invalid image: ${l2native.lastError()}');
    try {
      final dims = l2native.alloc(8).cast<ffi.Uint32>();
      try {
        if (_ImageNative.dimensions(h, dims, dims + 1) < 0) {
          throw l2native.NativeException('decode image', l2native.lastError());
        }
        final (w, hh) = (dims[0], dims[1]);
        final size = w * hh * 4;
        final buf = l2native.alloc(size);
        try {
          final got = _ImageNative.toRgba(h, buf, size);
          if (got < 0) throw l2native.NativeException('decode image', l2native.lastError());
          return Image._(w, hh, Uint8List.fromList(buf.asTypedList(got)));
        } finally {
          l2native.free(buf, size);
        }
      } finally {
        l2native.free(dims.cast(), 8);
      }
    } finally {
      _ImageNative.free(h);
    }
  });
}

/// Encodes [img] as [formatCode] at [quality] through the native library, via
/// a RGBA handle. Without the library it is an [UnsupportedError] (rule 42).
Uint8List _encodeNative(Image img, int formatCode, int quality, String format) {
  return l2native.withBytes(img.rgba, (p, n) {
    final h = _ImageNative.fromRgba(p, n, img.w, img.h);
    if (h == ffi.nullptr) throw l2native.NativeException('encode $format', l2native.lastError());
    try {
      return l2native.take(
        'encode $format',
        (out, len) => _ImageNative.encodeMemory(h, formatCode, quality, false, out, len),
      );
    } finally {
      _ImageNative.free(h);
    }
  });
}

// ---------------------------------------------------------------------------
// QOI codec (pure Dart; the "Quite OK Image" format)
// ---------------------------------------------------------------------------

int _qoiHash(int r, int g, int b, int a) => (r * 3 + g * 5 + b * 7 + a * 11) % 64;

Uint8List _be32(int v) => Uint8List.fromList([(v >>> 24) & 0xFF, (v >>> 16) & 0xFF, (v >>> 8) & 0xFF, v & 0xFF]);

Uint8List _encodeQoi(Image img) {
  final out = BytesBuilder(copy: true)
    ..add([0x71, 0x6F, 0x69, 0x66])
    ..add(_be32(img.w))
    ..add(_be32(img.h))
    ..addByte(4)
    ..addByte(0);
  final index = List<int>.filled(64 * 4, 0);
  var pr = 0, pg = 0, pb = 0, pa = 255;
  var run = 0;
  void flushRun() {
    if (run > 0) {
      out.addByte(0xC0 | (run - 1));
      run = 0;
    }
  }

  for (var i = 0; i < img.rgba.length; i += 4) {
    final r = img.rgba[i], g = img.rgba[i + 1], b = img.rgba[i + 2], a = img.rgba[i + 3];
    if (r == pr && g == pg && b == pb && a == pa) {
      if (++run == 62) flushRun();
      continue;
    }
    flushRun();
    final h = _qoiHash(r, g, b, a);
    if (index[h * 4] == r && index[h * 4 + 1] == g && index[h * 4 + 2] == b && index[h * 4 + 3] == a) {
      out.addByte(h);
    } else {
      index[h * 4] = r;
      index[h * 4 + 1] = g;
      index[h * 4 + 2] = b;
      index[h * 4 + 3] = a;
      if (a != pa) {
        out.addByte(0xFF);
        out.addByte(r);
        out.addByte(g);
        out.addByte(b);
        out.addByte(a);
      } else {
        final dr = r - pr, dg = g - pg, db = b - pb;
        if (dr > -3 && dr < 2 && dg > -3 && dg < 2 && db > -3 && db < 2) {
          out.addByte(0x40 | ((dr + 2) << 4) | ((dg + 2) << 2) | (db + 2));
        } else {
          final dg2 = dg, drDg = dr - dg, dbDg = db - dg;
          if (dg2 > -33 && dg2 < 32 && drDg > -9 && drDg < 8 && dbDg > -9 && dbDg < 8) {
            out.addByte(0x80 | (dg2 + 32));
            out.addByte(((drDg + 8) << 4) | (dbDg + 8));
          } else {
            out.addByte(0xFE);
            out.addByte(r);
            out.addByte(g);
            out.addByte(b);
          }
        }
      }
    }
    pr = r;
    pg = g;
    pb = b;
    pa = a;
  }
  flushRun();
  out.add([0, 0, 0, 0, 0, 0, 0, 1]);
  return out.takeBytes();
}

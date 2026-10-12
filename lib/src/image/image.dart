import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/jobs.dart';
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
final class Image implements Frame {
  @override
  final int w;
  @override
  final int h;
  final Uint8List _px;

  /// The pixels, `w*h*4` RGBA bytes, read-only: an [Image] never changes.
  @override
  Uint8List get rgba => _px.asUnmodifiableView();

  Image._(this.w, this.h, this._px);

  /// A blank [w]x[h] image filled with [color] (`0xAARRGGBB`).
  factory Image.empty(int w, int h, {int color = 0x00000000}) {
    final img = Image._(w, h, Uint8List(w * h * 4));
    return color == 0 ? img : img.fill(color);
  }

  /// An image of a copy of [rgba] (`w*h*4` bytes): changing [rgba] afterwards changes
  /// nothing here.
  factory Image.fromRgba(Uint8List rgba, int w, int h) {
    if (rgba.length != w * h * 4) {
      throw ArgumentError.value(rgba, 'rgba', 'Must hold w*h*4 bytes, holds ${rgba.length}');
    }
    return Image._(w, h, Uint8List.fromList(rgba));
  }

  /// Decodes the image in [data] (format detected from magic bytes) through
  /// the native engine. Unknown bytes are a [FormatException]; without the
  /// library it is an [UnsupportedError].
  static Image decode(List<int> data) {
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

  /// The pixel at ([x], [y]) as `0xAARRGGBB`; outside the image is a [RangeError].
  int pixel(int x, int y) {
    RangeError.checkValueInInterval(x, 0, w - 1, 'x');
    RangeError.checkValueInInterval(y, 0, h - 1, 'y');
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

  /// A [w]x[h] region anchored at ([x], [y]), clipped to the bounds
  /// (outside pixels stay transparent).
  Image crop(int x, int y, int w, int h) {
    if (w < 0 || h < 0) throw ArgumentError.value((w, h), 'crop', 'Must be non-negative');
    final out = Uint8List(w * h * 4);
    final x0 = x.clamp(0, this.w).toInt(), y0 = y.clamp(0, this.h).toInt();
    final x1 = (x + w).clamp(0, this.w).toInt(), y1 = (y + h).clamp(0, this.h).toInt();
    final cw = x1 - x0, ch = y1 - y0;
    if (cw > 0 && ch > 0) {
      final cut = _nativeCrop(x0, y0, cw, ch);
      final dx = x0 - x, dy = y0 - y;
      for (var row = 0; row < ch; row++) {
        out.setRange((dy + row) * w * 4 + dx * 4, (dy + row) * w * 4 + (dx + cw) * 4, cut, row * cw * 4);
      }
    }
    return Image._(w, h, out);
  }

  /// Shrinks to the largest size fitting inside [maxW]x[maxH], preserving aspect ratio. An
  /// image that already fits is returned as it is: `fit` never enlarges ([resize] does).
  Image fit(int maxW, int maxH) {
    final scale = math.min(1.0, math.min(maxW / w, maxH / h));
    if (scale == 1.0) return this;
    final nw = math.max(1, (w * scale).round());
    final nh = math.max(1, (h * scale).round());
    return _nativeResize(nw, nh);
  }

  /// Scales to exactly [nw]x[nh] (Lanczos3).
  Image resize(int nw, int nh) {
    if (nw <= 0 || nh <= 0) throw ArgumentError.value((nw, nh), 'resize', 'Must be positive');
    return _nativeResize(nw, nh);
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

  /// A blurred copy (gaussian, [radius] as sigma; `0` is a copy). A solid
  /// image stays solid.
  Image blur(int radius) {
    if (radius < 0) throw ArgumentError.value(radius, 'radius', 'Must be non-negative');
    if (radius == 0) return Image._(w, h, Uint8List.fromList(rgba));
    return _throughHandle('blur', (h) => _ImageNative.blur(h, radius.toDouble()));
  }

  /// Scales to exactly [nw]x[nh] through the native Lanczos3 resampler.
  Image _nativeResize(int nw, int nh) => _throughHandle('resize', (h) => _ImageNative.resize(h, nw, nh, 2, 0));

  /// Cuts an in-bounds [cw]x[ch] region at ([x0], [y0]) through the native
  /// crop, answering its bytes.
  Uint8List _nativeCrop(int x0, int y0, int cw, int ch) {
    final out = _throughHandle('crop', (h) => _ImageNative.crop(h, x0, y0, cw, ch));
    return out.rgba;
  }

  /// Runs [call] on this image's RGBA through a native handle and answers the
  /// resulting image. Without the library it is an [UnsupportedError] (rule 42).
  Image _throughHandle(String op, ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>) call) {
    return l2native.withBytes(rgba, (p, n) {
      final handle = _ImageNative.fromRgba(p, n, w, h);
      if (handle == ffi.nullptr) throw l2native.NativeException(op, l2native.lastError());
      try {
        final result = call(handle);
        if (result == ffi.nullptr) throw l2native.NativeException(op, l2native.lastError());
        try {
          return _takeRgba(op, result);
        } finally {
          _ImageNative.free(result);
        }
      } finally {
        _ImageNative.free(handle);
      }
    });
  }

  /// Reads a native handle's pixels and dimensions back into an [Image].
  static Image _takeRgba(String op, ffi.Pointer<ffi.Void> h) {
    final dims = l2native.alloc(8).cast<ffi.Uint32>();
    try {
      if (_ImageNative.dimensions(h, dims, dims + 1) < 0) {
        throw l2native.NativeException(op, l2native.lastError());
      }
      final (nw, nh) = (dims[0], dims[1]);
      final size = nw * nh * 4;
      final buf = l2native.alloc(size);
      try {
        final got = _ImageNative.toRgba(h, buf, size);
        if (got < 0) throw l2native.NativeException(op, l2native.lastError());
        return Image._(nw, nh, Uint8List.fromList(buf.asTypedList(got)));
      } finally {
        l2native.free(buf, size);
      }
    } finally {
      l2native.free(dims.cast(), 8);
    }
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
  /// PNG ignores it. JPEG and BMP have no alpha: translucent pixels are flattened.
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
  ///
  /// Encoding runs on a native thread, so a large image never blocks the event loop.
  Future<void> save(fs.File to, {int? quality}) async {
    final format = _formatFor(to.path);
    final bytes = format == 'qoi' ? _encodeQoi(this) : await _encodeJob(this, format, quality);
    await bytes.pipe(to);
  }

  /// Composes a `w x h` [Image] of the raw pixel buffer length check.
  @override
  String toString() => 'Image(${w}x$h)';

  /// Reads the image file at [path] and decodes it on a native thread.
  static Future<Image> _nativeLoadPath(String path) async => _decodeJob(await File(path).readAsBytes());
}

/// `File('photo.jpg').image()`, `Http.get(u).image()`.
extension SourceImage on Source {
  /// Decodes this source as an image: a file loads by path, anything else
  /// decodes its bytes.
  Future<Image> image() async =>
      this is fs.File ? Image._nativeLoadPath((this as fs.File).path) : _decodeJob(await bytes());
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
  if (p.endsWith('.tif') || p.endsWith('.tiff')) return 'tiff';
  if (p.endsWith('.png')) return 'png';
  throw ArgumentError.value(path, 'to', 'Unknown image extension (png, jpg, webp, gif, bmp, qoi, tiff)');
}

/// The native image calls behind decode/encode (cutover: the engine owns every
/// codec; RGBA crosses through `from_rgba`/`to_rgba`, so no finalizer is needed).
abstract final class _ImageNative {
  static ffi.DynamicLibrary get _lib => l2native.require();

  static final loadAsync = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_image_load_memory_async');

  static final encodeAsync = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Uint32,
          ffi.Uint32,
          ffi.Uint32,
          ffi.Uint8,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          ffi.Int64,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          int,
          int,
          int,
          int,
          ffi.Pointer<ffi.NativeFunction<DoneFn>>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.NativeFunction<ProgressFn>>,
          int,
        )
      >('tk_image_encode_rgba_async');

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

  static final resize = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, int, int, int)
      >('tk_image_resize');

  static final crop = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, int, int, int)
      >('tk_image_crop');

  static final blur = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Float),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, double)
      >('tk_image_blur');
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

/// Decodes [data] on a native thread: the answer is `[w:u32le][h:u32le][rgba]`.
Future<Image> _decodeJob(Uint8List data) async {
  if (Image.formatOf(data) == null) throw const FormatException('Not an image: unknown format');
  final Uint8List out;
  try {
    out = await nativeJob(
      'decode image',
      l2native.engineJobs,
      (done, stop, progress, id) =>
          l2native.withBytes(data, (p, n) => _ImageNative.loadAsync(p, n, done, stop, progress, id)),
    );
  } on l2native.NativeException catch (e) {
    throw FormatException('Invalid image: ${e.message}');
  }
  final dims = ByteData.sublistView(out, 0, 8);
  return Image._(dims.getUint32(0, Endian.little), dims.getUint32(4, Endian.little), Uint8List.sublistView(out, 8));
}

/// Encodes [img] as [format] on a native thread.
Future<Uint8List> _encodeJob(Image img, String format, int? quality) {
  final (code, q) = switch (format) {
    'jpeg' => (1, _checkedQuality(quality, 80)),
    'png' => (2, 0),
    'webp' => (3, _checkedQuality(quality, 80)),
    'gif' => (4, 0),
    'bmp' => (5, 0),
    'tiff' => (6, 0),
    _ => throw ArgumentError.value(format, 'format', 'Unknown image format'),
  };
  return nativeJob(
    'encode $format',
    l2native.engineJobs,
    (done, stop, progress, id) => l2native.withBytes(
      img._px,
      (p, n) => _ImageNative.encodeAsync(p, n, img.w, img.h, code, q, done, stop, progress, id),
    ),
  );
}

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

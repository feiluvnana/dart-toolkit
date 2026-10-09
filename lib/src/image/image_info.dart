part of '../../image.dart';

/// The image formats this library reads and writes.
///
/// {@category Image}
enum ImageFormat {
  jpeg(1, ['jpg', 'jpeg']),
  png(2, ['png']),
  webp(3, ['webp']),
  gif(4, ['gif']),
  bmp(5, ['bmp']),
  tiff(6, ['tif', 'tiff']);

  const ImageFormat(this._code, this.extensions);

  /// How the native library names it: append values, never reorder them.
  final int _code;

  /// The file extensions it goes by, the one written first: `['jpg', 'jpeg']`.
  final List<String> extensions;

  /// Whether a lossy quality ([Quality.visual], [Quality.fixed], [Quality.under]) applies.
  bool get _lossy => this == jpeg || this == webp;

  /// The format [path]'s extension names; one no format has is the caller's mistake.
  static ImageFormat _byName(String path) {
    final ext = FileBridge.extension(path);
    for (final format in values) {
      if (format.extensions.contains(ext)) return format;
    }
    final known = [for (final f in values) ...f.extensions].join(', ');
    throw ArgumentError.value(
      path,
      'to',
      'Invalid image extension "${ext.isEmpty ? '' : '.$ext'}", expected one of $known',
    );
  }

  /// The format [head] (a file's first bytes) starts as, by its signature; `null` for none.
  static ImageFormat? _sniff(List<int> head) {
    bool at(int offset, List<int> sig) {
      if (head.length < offset + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (head[offset + i] != sig[i]) return false;
      }
      return true;
    }

    if (at(0, const [0xFF, 0xD8, 0xFF])) return jpeg;
    if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return png;
    if (at(0, const [0x52, 0x49, 0x46, 0x46]) && at(8, const [0x57, 0x45, 0x42, 0x50])) return webp;
    if (at(0, const [0x47, 0x49, 0x46, 0x38])) return gif;
    if (at(0, const [0x42, 0x4D])) return bmp;
    if (at(0, const [0x49, 0x49, 0x2A, 0x00]) || at(0, const [0x4D, 0x4D, 0x00, 0x2A])) return tiff;
    return null;
  }
}

// ImageFit, ImageFilter and BlendMode cross FFI as their index (hash kinds: 0 phash, 1 dhash,
// 2 ahash): append values, never reorder them.

/// How [Image.resize] fits a box given by both sides.
///
/// {@category Image}
enum ImageFit {
  /// Fills the box, cropping the overflow from the centre.
  cover,

  /// Fits inside the box, keeping the aspect ratio.
  contain,

  /// Stretches to the box exactly.
  fill,

  /// Fits inside the box, never enlarging.
  inside,
}

/// The resampling filter of [Image.resize].
///
/// {@category Image}
enum ImageFilter {
  /// Lanczos3: the sharpest for downsampling.
  lanczos,

  /// Bilinear: balanced.
  bilinear,

  /// Nearest neighbour: the fastest, blocky.
  nearest,
}

/// How [Image.composite] and [Image.watermark] blend pixels.
///
/// {@category Image}
enum BlendMode { srcOver, multiply, screen, overlay, darken, lighten }

/// Where in a box, from (-1, -1) top left to (1, 1) bottom right.
///
/// {@category Image}
final class Anchor {
  final double x;
  final double y;

  const Anchor(this.x, this.y);

  static const topLeft = Anchor(-1.0, -1.0);
  static const topCenter = Anchor(0.0, -1.0);
  static const topRight = Anchor(1.0, -1.0);
  static const centerLeft = Anchor(-1.0, 0.0);
  static const center = Anchor(0.0, 0.0);
  static const centerRight = Anchor(1.0, 0.0);
  static const bottomLeft = Anchor(-1.0, 1.0);
  static const bottomCenter = Anchor(0.0, 1.0);
  static const bottomRight = Anchor(1.0, 1.0);

  /// [x] mapped to 0..1, as native code takes it.
  double get _nx => ((x + 1.0) / 2.0).clamp(0.0, 1.0);

  /// [y] mapped to 0..1, as native code takes it.
  double get _ny => ((y + 1.0) / 2.0).clamp(0.0, 1.0);

  @override
  String toString() => 'Anchor($x, $y)';

  @override
  bool operator ==(Object other) => other is Anchor && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// An 8-bit RGBA colour.
///
/// {@category Image}
final class Rgba {
  final int r;
  final int g;
  final int b;
  final int a;

  /// Each channel 0..255; another value is an [ArgumentError].
  Rgba(this.r, this.g, this.b, [this.a = 255]) {
    for (final (name, v) in [('r', r), ('g', g), ('b', b), ('a', a)]) {
      if (v < 0 || v > 255) throw ArgumentError.value(v, name, 'Invalid channel, expected 0 to 255');
    }
  }

  const Rgba._(this.r, this.g, this.b, this.a);

  static const transparent = Rgba._(0, 0, 0, 0);
  static const black = Rgba._(0, 0, 0, 255);
  static const white = Rgba._(255, 255, 255, 255);
  static const red = Rgba._(255, 0, 0, 255);
  static const green = Rgba._(0, 255, 0, 255);
  static const blue = Rgba._(0, 0, 255, 255);

  /// `(r << 24) | (g << 16) | (b << 8) | a`, as native code takes it.
  int get _rgba => (r << 24) | (g << 16) | (b << 8) | a;

  /// `#rrggbb`, or `#rrggbbaa` when it is not opaque.
  String get hex {
    final rgb = (_rgba >>> 8).toRadixString(16).padLeft(6, '0');
    return a == 255 ? '#$rgb' : '#$rgb${a.toRadixString(16).padLeft(2, '0')}';
  }

  @override
  String toString() => 'Rgba($r, $g, $b, $a)';

  @override
  bool operator ==(Object other) => other is Rgba && other.r == r && other.g == g && other.b == b && other.a == a;

  @override
  int get hashCode => Object.hash(r, g, b, a);
}

/// A 64-bit perceptual fingerprint of an image: [Image.phash], [Image.dhash], [Image.ahash].
///
/// {@category Image}
final class PerceptualHash {
  final int value;

  const PerceptualHash(this.value);

  /// How many of the 64 bits differ: 0 looks the same, up to about 6 a re-encode or resize,
  /// over 10 another picture.
  int distance(PerceptualHash other) {
    // A constant-time popcount, in wrapping 64-bit arithmetic.
    var v = value ^ other.value;
    v -= (v >>> 1) & 0x5555555555555555;
    v = (v & 0x3333333333333333) + ((v >>> 2) & 0x3333333333333333);
    v = (v + (v >>> 4)) & 0x0F0F0F0F0F0F0F0F;
    return (v * 0x0101010101010101) >>> 56;
  }

  /// The 64 bits as 16 hex digits, the top bit too.
  String get hex =>
      (value >>> 32).toRadixString(16).padLeft(8, '0') + (value & 0xffffffff).toRadixString(16).padLeft(8, '0');

  @override
  String toString() => hex;

  @override
  bool operator ==(Object other) => other is PerceptualHash && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// What an image file's header says, read without decoding a pixel: [ImageInfo.read].
///
/// {@category Image}
final class ImageInfo {
  /// The size as the picture is seen, its EXIF [orientation] applied: what [Image.read] gives.
  final int width;
  final int height;
  final ImageFormat format;

  /// When the photo was taken (EXIF `DateTimeOriginal`, else `DateTime`), as local time.
  final DateTime? taken;

  /// The EXIF orientation tag, 1–8.
  final int? orientation;

  /// The camera, `Make` with `Model`.
  final String? camera;

  /// The JPEG quality (1–100) the file was saved at, estimated from its luminance table as
  /// libjpeg's `-quality` would set it; `null` for other formats or a table past the first 64 KiB.
  final int? quality;

  const ImageInfo({
    required this.width,
    required this.height,
    required this.format,
    this.taken,
    this.orientation,
    this.camera,
    this.quality,
  });

  /// The header of the image file at [path]: size, format and, for a JPEG, its EXIF and quality.
  /// A missing file is a [PathNotFoundException], a format this library does not read a
  /// [FormatException] naming the file.
  static Future<ImageInfo> read(String path) async {
    final head = await _head(path, _exifBytes);
    try {
      return _parse(head, path, whole: head.length < _exifBytes);
    } on _PastHead {
      // A frame header past the first 64 KiB: the native reader walks the file for it.
      final abs = File(path).absolute.path;
      final (w, h, _) = await Isolate.run(() => _probeFile(abs));
      return _parse(head, path, size: (w, h));
    }
  }

  /// The format the file at [path] holds, from its first bytes; `null` when it is none this
  /// library reads. A missing file is a [PathNotFoundException]. The twin of `Archive.detect`.
  static Future<ImageFormat?> detect(String path) async => ImageFormat._sniff(await _head(path, 16));

  /// How much of a file [read] reads: the largest APP1, so a JPEG's whole EXIF and, in
  /// practice, its frame header.
  static const _exifBytes = 64 * 1024;

  /// The first [n] bytes of the file at [path]: read in place, as small work is, since three
  /// asynchronous calls for at most 64 KiB cost more than the read.
  static Future<Uint8List> _head(String path, int n) async {
    final file = File(path).openSync();
    try {
      return file.readSync(n);
    } finally {
      file.closeSync();
    }
  }

  /// The info in [head], the start of the file at [path] (`null` for bytes in memory), sized
  /// [size] when the header walk found it already.
  /// [whole] says [head] is the whole file, so a header it cannot read is no [_PastHead].
  static ImageInfo _parse(Uint8List head, String? path, {(int, int)? size, bool whole = false}) {
    final format =
        ImageFormat._sniff(head) ?? (throw FormatException(_invalid(path, 'not a format this library reads')));
    final (w, h) = size ?? _probeMemory(head, path, past: !whole);
    final exif = format == ImageFormat.jpeg ? _exif(head) : null;
    final turned = (exif?.orientation ?? 1) >= 5;
    return ImageInfo(
      width: turned ? h : w,
      height: turned ? w : h,
      format: format,
      taken: exif?.taken,
      orientation: exif?.orientation,
      camera: exif?.camera,
      quality: format == ImageFormat.jpeg ? _jpegQuality(head) : null,
    );
  }

  @override
  String toString() => 'ImageInfo($width×$height ${format.name})';
}

/// `Invalid image in <path>: <why>`, or `Invalid image: <why>` for bytes in memory.
String _invalid(String? path, String why) => path == null ? 'Invalid image: $why' : 'Invalid image in $path: $why';

/// The header ended before the size: the file must be walked.
final class _PastHead implements Exception {
  const _PastHead();
}

/// The width and height the native header reader finds in [bytes]; with [past], a header it
/// cannot read in a file's first bytes is [_PastHead].
(int, int) _probeMemory(Uint8List bytes, String? path, {bool past = false}) {
  final out = NativeBridge.main.alloc(sizeOf<IntPtr>() * 3).cast<IntPtr>();
  try {
    final ok = NativeBridge.main.withBytes(bytes, (p, n) => _ImageNative.probeMemory(p, n, out, out + 1, out + 2));
    if (ok < 0) {
      final why = NativeBridge.main.lastError();
      if (past && bytes.length >= ImageInfo._exifBytes) throw const _PastHead();
      throw FormatException(_invalid(path, why));
    }
    return (out[0], out[1]);
  } finally {
    NativeBridge.main.free(out.cast(), sizeOf<IntPtr>() * 3);
  }
}

/// The width, height and format code the native reader finds walking the file at [abs].
(int, int, int) _probeFile(String abs) {
  final out = NativeBridge.main.alloc(sizeOf<IntPtr>() * 3).cast<IntPtr>();
  try {
    final ok = NativeBridge.main.withText(abs, (p, n) => _ImageNative.probeFile(p, n, out, out + 1, out + 2));
    if (ok < 0) throw NativeBridge.fileError(NativeBridge.main.lastError(), abs, 'Invalid image in $abs');
    return (out[0], out[1], out[2]);
  } finally {
    NativeBridge.main.free(out.cast(), sizeOf<IntPtr>() * 3);
  }
}

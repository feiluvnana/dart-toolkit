part of '../../image.dart';

/// A decoded image, held natively and upright (its EXIF orientation applied): what you see is
/// what you get. A resource: [close] gives its memory back, and a garbage-collected image is
/// freed on its own.
///
/// Transforms are pure: each returns a new [Image] at once, leaving this one as it was, and an
/// argument out of range is an [ArgumentError]. Reading, [encode] and [save] are asynchronous;
/// above 4 MiB of pixels they run on a worker.
///
/// ```dart
/// final img = await Image.read('photo.jpg', maxSide: 2048);
/// final out = img.resize(width: 800).cropAspect(16 / 9).sharpen().adjust(contrast: 1.1);
/// await out.save('out.webp', quality: Quality.visual(90));
/// await img.close();
/// ```
///
/// {@category Image}
final class Image implements Finalizable, Saveable {
  _Handle _ptr;

  /// Width and height in pixels.
  final int width;
  final int height;

  bool _closed = false;

  /// Encodes and saves under way, which [close] waits for.
  int _busy = 0;
  Completer<void>? _idle;

  Image._(this._ptr, this.width, this.height) {
    // Sized, so the GC weighs the pixels a dropped intermediate holds and frees it in time.
    _ImageNative.finalizer.attach(this, _ptr, detach: this, externalSize: width * height * 4);
  }

  /// The image behind [h], a handle native code made, or a [NativeException] saying why [op]
  /// made none.
  factory Image._made(_Handle h, String op) {
    if (h == nullptr) throw NativeException(op, NativeBridge.main.lastError());
    final dims = NativeBridge.main.alloc(8).cast<Uint32>();
    try {
      if (_ImageNative.dimensions(h, dims, dims + 1) < 0) {
        _ImageNative.free(h);
        throw NativeException(op, NativeBridge.main.lastError());
      }
      return Image._(h, dims[0], dims[1]);
    } finally {
      NativeBridge.main.free(dims.cast(), 8);
    }
  }

  /// Decoding and encoding run on the caller up to this many bytes of pixels and on a worker
  /// above, so a large image never stalls the event loop and several decode at once.
  static const _inline = 4 << 20;

  static Future<T> _work<T>(int bytes, T Function() call) => bytes <= _inline ? Future.sync(call) : Isolate.run(call);

  /// The native handle; a closed image is a [StateError].
  _Handle get _live => _closed ? throw StateError('Cannot use a closed Image') : _ptr;

  // ---- making one

  /// The image file at [path], decoded by its content (JPEG, PNG, WebP, GIF, BMP, TIFF) and
  /// turned upright. A missing file is a [PathNotFoundException], one it cannot decode a
  /// [FormatException] naming it.
  ///
  /// [maxSide] decodes no side longer than that: a JPEG is decoded already scaled down (by
  /// eighths), so its whole size is never in memory.
  static Future<Image> read(String path, {int? maxSide}) async {
    final side = _side(maxSide);
    final abs = File(path).absolute.path;
    final size = (await FileStat.stat(abs)).size;
    if (size < 0) throw PathNotFoundException(path, const OSError('No such file or directory', 2), 'Cannot read image');
    final h = await _work(_pixelBytes(await ImageInfo._head(abs, _headBytes), size), () => _loadFile(abs, side));
    return Image._made(Pointer.fromAddress(h), 'read image $path');
  }

  /// [bytes] decoded, as [read] decodes a file; bytes it cannot decode are a [FormatException].
  static Future<Image> decode(List<int> bytes, {int? maxSide}) async {
    final side = _side(maxSide);
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final head = data.length <= _headBytes ? data : Uint8List.sublistView(data, 0, _headBytes);
    final h = await _work(_pixelBytes(head, data.length), () => _loadMemory(data, side));
    return Image._made(Pointer.fromAddress(h), 'decode image');
  }

  /// A [width] × [height] canvas of [color].
  static Image blank({required int width, required int height, Rgba color = Rgba.transparent}) {
    _atLeast(width, 1, 'width');
    _atLeast(height, 1, 'height');
    return Image._made(_ImageNative.createBlank(width, height, color.r, color.g, color.b, color.a), 'create image');
  }

  /// A contact sheet of [images]: each fitted into a [cell]-px square and centred, [columns] to a
  /// row, [gap] px apart and around, on [background].
  static Image grid(List<Image> images, {int columns = 4, int cell = 400, int gap = 8, Rgba background = Rgba.white}) {
    if (images.isEmpty) throw ArgumentError.value(images, 'images', 'Invalid grid: no image');
    _atLeast(columns, 1, 'columns');
    _atLeast(cell, 1, 'cell');
    _atLeast(gap, 0, 'gap');
    final size = sizeOf<Pointer<Void>>() * images.length;
    final handles = NativeBridge.main.alloc(size).cast<_Handle>();
    try {
      for (var i = 0; i < images.length; i++) {
        handles[i] = images[i]._live;
      }
      return Image._made(
        _ImageNative.grid(handles, images.length, columns, cell, gap, background._rgba),
        'lay out a grid',
      );
    } finally {
      NativeBridge.main.free(handles.cast(), size);
    }
  }

  // ---- geometry

  /// This image at [width] by [height] pixels. Given one side, the other keeps the aspect
  /// ratio; given both, [fit] says how it fills that box ([ImageFit.cover] when omitted).
  Image resize({int? width, int? height, ImageFit? fit, ImageFilter filter = ImageFilter.lanczos}) {
    if (width == null && height == null) throw ArgumentError('Cannot resize: give width:, height: or both');
    if (width != null) _atLeast(width, 1, 'width');
    if (height != null) _atLeast(height, 1, 'height');
    if (fit != null && (width == null || height == null)) {
      throw ArgumentError.value(fit, 'fit', 'Invalid fit with one side: the other keeps the aspect ratio');
    }
    final (w, h) = (width ?? (this.width * height! / this.height).round().clamp(1, 1 << 30), height ?? 0);
    return Image._made(_ImageNative.resize(_live, w, h, (fit ?? ImageFit.cover).index, filter.index), 'resize image');
  }

  /// The [width] × [height] region whose top-left corner is ([x], [y]); it must lie inside.
  Image crop({required int x, required int y, required int width, required int height}) {
    _atLeast(x, 0, 'x');
    _atLeast(y, 0, 'y');
    _atLeast(width, 1, 'width');
    _atLeast(height, 1, 'height');
    if (x + width > this.width || y + height > this.height) {
      throw ArgumentError('Invalid crop: $width×$height at ($x, $y) passes the ${this.width}×${this.height} image');
    }
    return Image._made(_ImageNative.crop(_live, x, y, width, height), 'crop image');
  }

  /// The largest region of aspect [ratio] (width over height: `16 / 9`, `1`), placed at
  /// [anchor].
  Image cropAspect(double ratio, {Anchor anchor = Anchor.center}) =>
      Image._made(_ImageNative.cropAspect(_live, _ratio(ratio), anchor._nx, anchor._ny), 'crop image');

  /// The region of aspect [ratio] that keeps the most detail and skin tone, with a mild pull
  /// to the centre: the cover or thumbnail crop that keeps faces. Slower than [cropAspect].
  Image cropSmart(double ratio) => Image._made(_ImageNative.cropSmart(_live, _ratio(ratio)), 'crop image');

  /// Turned clockwise by [degrees], a multiple of 90.
  Image rotate(int degrees) {
    if (degrees % 90 != 0) throw ArgumentError.value(degrees, 'degrees', 'Invalid rotation, expected a multiple of 90');
    return Image._made(_ImageNative.rotate(_live, degrees), 'rotate image');
  }

  /// Mirrored left to right with [horizontal], top to bottom with [vertical]; at least one.
  Image flip({bool horizontal = false, bool vertical = false}) {
    if (!horizontal && !vertical) throw ArgumentError('Cannot flip: give horizontal:, vertical: or both');
    return Image._made(_ImageNative.flip(_live, horizontal, vertical), 'flip image');
  }

  /// A border of [color] around it, each side in pixels.
  Image pad({int top = 0, int right = 0, int bottom = 0, int left = 0, Rgba color = Rgba.transparent}) {
    for (final (name, v) in [('top', top), ('right', right), ('bottom', bottom), ('left', left)]) {
      _atLeast(v, 0, name);
    }
    return Image._made(
      _ImageNative.pad(_live, top, right, bottom, left, color.r, color.g, color.b, color.a),
      'pad image',
    );
  }

  /// Without the border of the top-left pixel's colour, to within [threshold] (0–255) a
  /// channel: the margins of a scan.
  Image trim({int threshold = 10}) {
    _within(threshold, 0, 255, 'threshold');
    return Image._made(_ImageNative.trim(_live, threshold), 'trim image');
  }

  // ---- colour and filters

  /// The tones adjusted: [brightness] -1 (black) to 1 (white); [contrast] and [saturation] 0
  /// (flat, grey) to 2, 1 as it is; [gamma] over 0; white balance [temperature] -1 (cool) to 1
  /// (warm) and [tint] -1 (green) to 1 (magenta).
  Image adjust({
    double brightness = 0.0,
    double contrast = 1.0,
    double saturation = 1.0,
    double gamma = 1.0,
    double temperature = 0.0,
    double tint = 0.0,
  }) {
    _within(brightness, -1, 1, 'brightness');
    _within(contrast, 0, 2, 'contrast');
    _within(saturation, 0, 2, 'saturation');
    if (!(gamma > 0 && gamma.isFinite)) throw ArgumentError.value(gamma, 'gamma', 'Invalid gamma, expected over 0');
    _within(temperature, -1, 1, 'temperature');
    _within(tint, -1, 1, 'tint');
    return Image._made(
      _ImageNative.adjust(_live, brightness, contrast, saturation, gamma, temperature, tint),
      'adjust image',
    );
  }

  /// In shades of grey.
  Image grayscale() => Image._made(_ImageNative.grayscale(_live), 'grayscale image');

  /// The negative.
  Image invert() => Image._made(_ImageNative.invert(_live), 'invert image');

  /// A warm sepia tone.
  Image sepia() => Image._made(_ImageNative.sepia(_live), 'tone image');

  /// A Gaussian blur of [sigma] pixels.
  Image blur({double sigma = 2.0}) {
    _over(sigma, 'sigma');
    return Image._made(_ImageNative.blur(_live, sigma), 'blur image');
  }

  /// An unsharp mask: [amount] of the detail at [sigma] pixels added back.
  Image sharpen({double amount = 1.5, double sigma = 1.0}) {
    _within(amount, 0, 10, 'amount');
    _over(sigma, 'sigma');
    return Image._made(_ImageNative.sharpen(_live, amount, sigma), 'sharpen image');
  }

  /// Sensor noise smoothed over [radius] pixels.
  Image denoise({int radius = 2}) {
    _atLeast(radius, 1, 'radius');
    return Image._made(_ImageNative.denoise(_live, radius), 'denoise image');
  }

  /// The 8×8 block seams a JPEG encoder leaves smoothed, sparing real edges. [strength] scales
  /// how large a step across a seam still counts as an artifact; 0 leaves it as it is.
  Image deblock({double strength = 1}) {
    _within(strength, 0, 10, 'strength');
    return Image._made(_ImageNative.deblock(_live, strength), 'deblock image');
  }

  /// The levels stretched so the darkest and brightest [clip] (0–0.5) of the pixels reach black
  /// and white. With [whiteBalance] each channel stretches on its own and drifts toward grey by
  /// at most 10 %; without it the channels stretch together and keep their cast.
  Image autoLevels({double clip = 0.005, bool whiteBalance = true}) {
    _within(clip, 0, 0.5, 'clip');
    return Image._made(_ImageNative.autoLevels(_live, clip, whiteBalance), 'level image');
  }

  /// The one-call fix for a photo re-encoded on its way (a download, a messenger copy):
  /// [deblock], a light [sharpen], then [autoLevels].
  Image enhance() {
    final smooth = deblock();
    final crisp = smooth.sharpen(amount: 0.5, sigma: 1.0);
    smooth._free();
    final out = crisp.autoLevels();
    crisp._free();
    return out;
  }

  /// The corners darkened by [amount], 0 to 1.
  Image vignette({double amount = 0.5}) {
    _within(amount, 0, 1, 'amount');
    return Image._made(_ImageNative.vignette(_live, amount), 'vignette image');
  }

  // ---- compositing

  /// [mark] stamped at [anchor], [margin] px from the edges, at [opacity] (0–1); [size] scales
  /// it to that fraction of this image's width (`0.2` is a fifth).
  Image watermark(
    Image mark, {
    Anchor anchor = Anchor.bottomRight,
    double opacity = 0.8,
    double? size,
    int margin = 20,
    BlendMode blend = BlendMode.srcOver,
  }) {
    _within(opacity, 0, 1, 'opacity');
    if (size != null && !(size > 0 && size <= 1)) {
      throw ArgumentError.value(size, 'size', 'Invalid size, expected over 0 to 1');
    }
    _atLeast(margin, 0, 'margin');
    return Image._made(
      _ImageNative.watermark(_live, mark._live, anchor._nx, anchor._ny, opacity, size ?? 0.0, margin, blend.index),
      'watermark image',
    );
  }

  /// [overlay] drawn with its top-left corner at ([x], [y]), at [opacity] (0–1).
  Image composite(
    Image overlay, {
    required int x,
    required int y,
    double opacity = 1.0,
    BlendMode blend = BlendMode.srcOver,
  }) {
    _within(opacity, 0, 1, 'opacity');
    return Image._made(_ImageNative.composite(_live, overlay._live, x, y, opacity, blend.index), 'composite image');
  }

  /// Its alpha replaced by the luminance of [alpha], stretched to this size.
  Image mask(Image alpha) => Image._made(_ImageNative.mask(_live, alpha._live), 'mask image');

  /// [text] drawn with its top-left corner at ([x], [y]), [fontSize] px high, in [color], with
  /// a one-pixel [shadow] when given.
  Image drawText(
    String text, {
    required int x,
    required int y,
    int fontSize = 24,
    Rgba color = Rgba.white,
    Rgba? shadow,
  }) {
    _atLeast(fontSize, 1, 'fontSize');
    final h = _live;
    return Image._made(
      NativeBridge.main.withText(
        text,
        (p, len) => _ImageNative.drawText(h, p, len, x, y, fontSize, color._rgba, shadow?._rgba ?? 0, shadow != null),
      ),
      'draw text',
    );
  }

  // ---- analysis

  /// The DCT perceptual hash: robust to resizing and re-encoding.
  PerceptualHash get phash => PerceptualHash(_ImageNative.hash(_live, 0));

  /// The gradient difference hash: fast, sensitive to structure.
  PerceptualHash get dhash => PerceptualHash(_ImageNative.hash(_live, 1));

  /// The average luminance hash.
  PerceptualHash get ahash => PerceptualHash(_ImageNative.hash(_live, 2));

  /// How alike [other] looks, by SSIMULACRA2: 100 is identical, 90 very high, 85 visually
  /// lossless at a normal viewing distance, 70 medium. Both are one size, at least 8×8. For
  /// pictures of different sizes, compare [phash]es.
  double similarity(Image other) {
    if (other.width != width || other.height != height || width < 8 || height < 8) {
      throw ArgumentError.value(
        '${other.width}×${other.height}',
        'other',
        'Invalid size, expected $width×$height (at least 8×8)',
      );
    }
    final out = NativeBridge.main.alloc(sizeOf<Double>()).cast<Double>();
    try {
      if (_ImageNative.similarity(_live, other._live, out) < 0) {
        throw NativeException('compare images', NativeBridge.main.lastError());
      }
      return out.value;
    } finally {
      NativeBridge.main.free(out.cast(), sizeOf<Double>());
    }
  }

  /// How sharp it is: the variance of its Laplacian, on a copy at most 1024 px on its long side
  /// so sizes compare. Higher is sharper; flat artwork scores low while sharp, so compare shots
  /// of one kind: one under a quarter of their median is visibly soft.
  double get sharpness {
    final s = _ImageNative.sharpness(_live);
    if (s < 0) throw NativeException('measure sharpness', NativeBridge.main.lastError());
    return s;
  }

  /// The average colour of its opaque pixels.
  Rgba get dominantColor {
    final c = _ImageNative.dominantColor(_live);
    return Rgba._((c >> 24) & 0xff, (c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff);
  }

  // ---- output

  /// This image as the bytes of a [format] file, at [quality]: [Quality.fixed] 85 for JPEG and
  /// WebP when omitted; PNG is lossless, and GIF, BMP and TIFF take none. Encoders write pixels
  /// only. A quality not for [format] is an [ArgumentError], and so is JPEG for an image with
  /// transparency.
  Future<Uint8List> encode(ImageFormat format, {Quality? quality}) {
    final plan = _plan(format, quality, fallback: _Fixed(85));
    final h = _live.address;
    final release = _hold();
    return _encodeOff(width * height * 4, h, plan).whenComplete(release);
  }

  /// This image written to [to], in the format its extension names, as [encode] encodes it:
  /// atomically (a failure leaves the old file), never making a folder (a missing one is a
  /// [PathNotFoundException]). [conflict] is as `Saveable.save` says. An unknown extension is
  /// an [ArgumentError]. [close] waits for it.
  @override
  Task<Path> save(String to, {Conflict conflict = Conflict.overwrite, Quality? quality}) {
    final plan = _plan(ImageFormat._byName(to), quality, fallback: _Fixed(85));
    if (conflict == Conflict.newer) {
      throw ArgumentError.value(conflict, 'conflict', 'Invalid conflict: a value in memory has no time to compare');
    }
    final h = _live.address;
    final release = _hold();
    return TaskInternals.start(Path(to), FileBridge.label(to), (work) async {
      try {
        return await FileBridge.save(to, conflict, 'image', () async {
          final folder = File(to).absolute.parent;
          if (!await folder.exists()) {
            throw PathNotFoundException(
              folder.path,
              const OSError('No such file or directory', 2),
              'Cannot save image to $to',
            );
          }
          return _encodeOff(width * height * 4, h, plan);
        });
      } finally {
        release();
      }
    });
  }

  /// Marks work on the handle under way; the answer ends it.
  void Function() _hold() {
    _busy++;
    var done = false;
    return () {
      if (done) return;
      done = true;
      if (--_busy == 0) _idle?.complete();
      if (_busy == 0) _idle = null;
    };
  }

  /// Gives the native memory back, once every [encode] and [save] under way is done. Using it
  /// afterwards is a [StateError]; closing twice does nothing.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    while (_busy > 0) {
      await (_idle ??= Completer()).future;
    }
    _free();
  }

  /// Frees the handle now: for an intermediate nothing else holds.
  void _free() {
    _closed = true;
    _ImageNative.finalizer.detach(this);
    _ImageNative.free(_ptr);
    _ptr = nullptr;
  }

  @override
  String toString() => _closed ? 'Image(closed)' : 'Image($width×$height)';
}

// The native calls behind reading. Each may run on a worker, so it takes plain values, reads
// the thread-local native error where it ran, and hands back a handle's address for the
// caller to own.

/// The image at handle [h] encoded by [plan], on a worker for more than [pixels] bytes. Top
/// level, so the worker is sent only these.
Future<Uint8List> _encodeOff(int pixels, int h, _Plan plan) async =>
    (await Image._work(pixels, () => _encodeWith(h, plan))).bytes;

/// [maxSide] 0 decodes the whole image.
int _loadFile(String abs, int maxSide) {
  final h = NativeBridge.main.withText(abs, (p, len) => _ImageNative.loadFile(p, len, maxSide));
  if (h == nullptr) throw NativeBridge.fileError(NativeBridge.main.lastError(), abs, 'Invalid image in $abs');
  return h.address;
}

int _loadMemory(Uint8List bytes, int maxSide) {
  final h = NativeBridge.main.withBytes(bytes, (p, len) => _ImageNative.loadMemory(p, len, 0, maxSide));
  if (h == nullptr) throw FormatException('Invalid image: ${NativeBridge.main.lastError()}');
  return h.address;
}

/// How much of a file the header gives its size in: the first 16 KiB, for every format written.
const _headBytes = 16 << 10;

/// The bytes of pixels the image whose file starts with [head] decodes to, from its header: a
/// small file can hold a huge picture. [fileSize] times 8 when the header does not say.
int _pixelBytes(Uint8List head, int fileSize) {
  try {
    final (w, h) = _probeMemory(head, null);
    return w * h * 4;
  } on FormatException {
    return fileSize * 8; // no size in the head: the decode says what is wrong
  }
}

/// [maxSide] as the native decoder takes it: 0 for none.
int _side(int? maxSide) => maxSide == null ? 0 : _atLeast(maxSide, 1, 'maxSide');

int _atLeast(int value, int min, String name) {
  if (value < min) throw ArgumentError.value(value, name, 'Invalid $name, expected at least $min');
  return value;
}

void _within(num value, num lo, num hi, String name) {
  if (!(value >= lo && value <= hi)) throw ArgumentError.value(value, name, 'Invalid $name, expected $lo to $hi');
}

void _over(double value, String name) {
  if (!(value > 0 && value.isFinite)) throw ArgumentError.value(value, name, 'Invalid $name, expected over 0');
}

double _ratio(double ratio) {
  if (!(ratio > 0 && ratio.isFinite)) {
    throw ArgumentError.value(ratio, 'ratio', 'Invalid aspect ratio, expected over 0');
  }
  return ratio;
}

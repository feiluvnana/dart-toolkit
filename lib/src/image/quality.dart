part of '../../image.dart';

/// How faithful an encoding is: one setting for [Image.save], [Image.encode] and
/// `path.compress`, with no combinations to get wrong.
///
/// | `Quality` | Means | For |
/// |---|---|---|
/// | `Quality.visual([85])` | the smallest file whose SSIMULACRA2 score reaches the number | JPEG, WebP |
/// | `Quality.fixed(80)` | the encoder setting, no search | JPEG, WebP |
/// | `Quality.under(bytes, {visual})` | the best quality that fits; may shrink the pixels | JPEG, WebP |
/// | `Quality.lossless` | every pixel kept | PNG, WebP |
///
/// A number out of range is an [ArgumentError] when it is made, and so is a quality given for
/// a format it is not for, at the call.
///
/// {@category Image}
sealed class Quality {
  const Quality._();

  /// The smallest encoding whose SSIMULACRA2 score against the image reaches [score]: 90 is
  /// very high, 85 visually lossless at a normal viewing distance, 70 medium. A score no quality
  /// reaches gives the highest. Costs a search of up to seven encodes.
  factory Quality.visual([double score = 85]) => _Visual(_score(score, 'score'));

  /// The encoder's own setting, 1–100, without measuring anything.
  factory Quality.fixed(int quality) {
    if (quality < 1 || quality > 100) {
      throw ArgumentError.value(quality, 'quality', 'Invalid quality, expected 1 to 100');
    }
    return _Fixed(quality);
  }

  /// The best quality whose file is at most [bytes], found by size alone, the highest tried
  /// first; with [visual], the smallest that reaches that score within the budget. When even the lowest quality is over, the picture shrinks a
  /// tenth at a time, five times at most, and `Compressed.width`/`height` say so.
  factory Quality.under(int bytes, {double? visual}) {
    if (bytes < 1) throw ArgumentError.value(bytes, 'bytes', 'Invalid budget, expected at least 1 byte');
    return _Under(bytes, visual == null ? null : _score(visual, 'visual'));
  }

  /// Every pixel kept: PNG, or WebP's lossless mode.
  static const Quality lossless = _Lossless();

  static double _score(double score, String name) {
    if (!(score > 0 && score <= 100)) throw ArgumentError.value(score, name, 'Invalid score, expected over 0 to 100');
    return score;
  }

  /// This quality for [format], checked: an [ArgumentError] when it is not for that format.
  Quality _for(ImageFormat format) {
    final ok = switch (this) {
      _Lossless() => format == ImageFormat.png || format == ImageFormat.webp,
      _ => format._lossy,
    };
    if (!ok) {
      throw ArgumentError.value(this, 'quality', 'Invalid quality for ${format.name}: ${_validFor(format)}');
    }
    return this;
  }

  static String _validFor(ImageFormat format) => switch (format) {
    ImageFormat.jpeg || ImageFormat.webp => 'JPEG is lossy: give visual, fixed or under',
    ImageFormat.png => 'PNG is lossless only',
    _ => '${format.name.toUpperCase()} has no quality setting',
  };
}

final class _Visual extends Quality {
  final double score;
  const _Visual(this.score) : super._();

  @override
  String toString() => 'Quality.visual($score)';
}

final class _Fixed extends Quality {
  final int quality;
  const _Fixed(this.quality) : super._();

  @override
  String toString() => 'Quality.fixed($quality)';
}

final class _Under extends Quality {
  final int bytes;
  final double? visual;
  const _Under(this.bytes, this.visual) : super._();

  @override
  String toString() => 'Quality.under($bytes${visual == null ? '' : ', visual: $visual'})';
}

final class _Lossless extends Quality {
  const _Lossless() : super._();

  @override
  String toString() => 'Quality.lossless';
}

/// What `path.compress` or `path.optimize` did to one file: where it is now, its size [before]
/// and [after], the picture's size and [format], and the encoder [quality] and SSIMULACRA2
/// [score] when they were measured (`null` for a lossless or an unchanged file; the score also
/// at a fixed quality and under a budget with no `visual:`, where nothing is scored). A file left as it was has `after == before` and is a `Done(fresh:
/// false)`; why is a step or a note of its task.
///
/// {@category Image}
final class Compressed {
  final Path path;
  final int before;
  final int after;
  final int width;
  final int height;
  final ImageFormat format;
  final int? quality;
  final double? score;

  const Compressed({
    required this.path,
    required this.before,
    required this.after,
    required this.width,
    required this.height,
    required this.format,
    this.quality,
    this.score,
  });

  @override
  String toString() =>
      'Compressed($path, ${before.humanBytes} → ${after.humanBytes}, $width×$height ${format.name}'
      '${quality == null ? '' : ', q$quality'}${score == null ? '' : ', score ${score!.toStringAsFixed(1)}'})';
}

/// An encoding as the native call takes it: [format], how ([mode]: 0 the format's own encoder,
/// 1 the search with [quality] fixed above 0, [target] and [budget]; 2 PNG through oxipng; 3
/// WebP lossless). Plain values, so it crosses to a worker.
typedef _Plan = ({int format, int mode, int quality, double target, int budget});

/// How [format] is encoded at [quality] (`null`: the format's default, [fallback] for a lossy
/// one); an [ArgumentError] when they do not go together.
_Plan _plan(ImageFormat format, Quality? quality, {required Quality fallback}) {
  final q = quality?._for(format) ?? (format._lossy ? fallback : null);
  final code = format._code;
  return switch (q) {
    _Fixed(:final quality) => (format: code, mode: 1, quality: quality, target: 0, budget: 0),
    _Visual(:final score) => (format: code, mode: 1, quality: 0, target: score, budget: 0),
    // No score asked: an unreachable one, so the search keeps the highest quality that fits.
    _Under(:final bytes, :final visual) => (format: code, mode: 1, quality: 0, target: visual ?? 1000, budget: bytes),
    _Lossless() when format == ImageFormat.webp => (format: code, mode: 3, quality: 100, target: 0, budget: 0),
    _Lossless() || null => (format: code, mode: 0, quality: 0, target: 0, budget: 0),
  };
}

/// What [_encodeWith] made: the bytes, and the quality and score when it measured them.
typedef _Encoded = ({Uint8List bytes, int? quality, double? score});

/// The image at handle [h] encoded by [plan]: [_encodeOr] for an image with transparency as a
/// JPEG, which is the caller's mistake here.
_Encoded _encodeWith(int h, _Plan plan) {
  try {
    return _encodeOr(h, plan);
  } on _Translucent {
    throw ArgumentError.value('jpeg', 'format', 'Invalid format for an image with transparency, expected png or webp');
  }
}

/// JPEG cannot hold the transparency the image has.
final class _Translucent implements Exception {
  const _Translucent();
}

/// The image at handle [h] encoded by [plan], a lossless PNG through oxipng with [oxipng]. An
/// image with transparency as a JPEG is a [_Translucent]; a budget nothing fits a
/// [NativeException].
_Encoded _encodeOr(int h, _Plan plan, {bool oxipng = false}) {
  final handle = Pointer<Void>.fromAddress(h);
  if (plan.mode == 0 && plan.format == ImageFormat.png._code && oxipng) {
    return (bytes: _search(handle, plan).bytes, quality: null, score: null);
  }
  return switch (plan.mode) {
    0 || 3 => (
      bytes: NativeBridge.main.take(
        'encode image',
        (out, len) => _ImageNative.encodeMemory(handle, plan.format, plan.quality, plan.mode == 3, out, len),
      ),
      quality: null,
      score: null,
    ),
    _ => _search(handle, plan),
  };
}

/// [plan] through the native search: JPEG and WebP (mode 1), or PNG through oxipng.
_Encoded _search(Pointer<Void> handle, _Plan plan) {
  final meta = NativeBridge.main.alloc(16);
  try {
    var result = 0;
    final bytes = NativeBridge.main.take(
      'encode image',
      (out, len) => result = _ImageNative.compress(
        handle,
        plan.format,
        plan.quality,
        plan.target,
        plan.budget,
        out,
        len,
        meta.cast<Uint32>(),
        (meta + 8).cast<Double>(),
      ),
    );
    if (result == 2) throw const _Translucent();
    if (result == 1) {
      throw NativeException(
        'encode image under ${plan.budget.humanBytes}',
        'not at quality 40, nor a tenth smaller five times',
      );
    }
    if (plan.format == ImageFormat.png._code) return (bytes: bytes, quality: null, score: null);
    final score = (meta + 8).cast<Double>().value;
    return (bytes: bytes, quality: meta.cast<Uint32>().value, score: score.isNaN ? null : score);
  } finally {
    NativeBridge.main.free(meta, 16);
  }
}

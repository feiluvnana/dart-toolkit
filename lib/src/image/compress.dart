part of '../../image.dart';

/// Making image files smaller: [compress] re-encodes, [optimize] keeps every pixel.
///
/// {@category Image}
extension PathImageExtensions on Path {
  /// This image file made smaller: decoded upright, shrunk to fit [maxSide] when larger, and
  /// encoded at [quality] in [format] (its own when omitted). [quality] defaults to
  /// `Quality.visual(85)` for JPEG and WebP and [Quality.lossless] for PNG; a quality not for
  /// the format is an [ArgumentError]. EXIF, XMP, IPTC and the colour profile of a JPEG go
  /// along to a JPEG (EXIF also to a WebP), the orientation reset since the pixels are upright.
  ///
  /// The file is replaced only by something smaller, atomically: the result is renamed over it
  /// first, and only then does the original go as [original] says (the trash by default;
  /// [Original.keep] needs a new [format]). A new format gets its extension (`a.jpg` →
  /// `a.webp`); a file already there is a [PathExistsException].
  ///
  /// Nothing smaller, or a file a redraw would change beyond the encoding (an animation, a
  /// multi-page TIFF, a CMYK JPEG, a colour profile the output cannot carry, transparency for a
  /// JPEG, a GIF, BMP or TIFF kept in its format), is left as it is: a `Done(fresh: false)`
  /// whose [Compressed.after] is its size, the reason a note (`Warned`) or, for "not smaller",
  /// a step. One file spreads over every core. A [Quality.visual] score compares the picture at
  /// 2048 px at most and holds about 600 MB, so the process scores one file at a time while
  /// the others encode.
  ///
  /// ```dart
  /// await photos.parallelize((p) => p.compress(maxSide: 2560)).show('Compressing');
  /// ```
  Task<Compressed> compress({Quality? quality, ImageFormat? format, int? maxSide, Original original = Original.trash}) {
    if (format != null) quality?._for(format);
    final side = _side(maxSide);
    if (original == Original.keep && format == null) {
      throw ArgumentError.value(
        original,
        'original',
        'Invalid original: the result replaces the file; give format: to keep it',
      );
    }
    final abs = File(this).absolute.path;
    return TaskInternals.start(this, FileBridge.label(this), (work) async {
      work.step('compressing');
      final outcome = await NativeBridge.main.run(work, _squeezeCall(abs, this, format, quality, side, original));
      return _settle(work, this, outcome, original);
    });
  }

  /// This image file made smaller with every pixel kept, in place: a JPEG loses the segments
  /// that hold no pixels (EXIF, XMP, IPTC, comments; the EXIF stays on a photo that is turned,
  /// since its orientation lives there), a PNG is recompressed by oxipng without the chunks
  /// that do not show. Other formats are left as they are, with a note. The original goes as
  /// [original] says ([Original.keep] is an [ArgumentError]: the result replaces it).
  Task<Compressed> optimize({Original original = Original.trash}) {
    if (original == Original.keep) {
      throw ArgumentError.value(original, 'original', 'Invalid original: the result replaces the file');
    }
    final abs = File(this).absolute.path;
    return TaskInternals.start(this, FileBridge.label(this), (work) async {
      work.step('optimizing');
      final outcome = await NativeBridge.main.run(work, _optimizeCall(abs, this));
      return _settle(work, this, outcome, original);
    });
  }
}

/// What compressing one file came to, worked out on a worker: a file [_Left] as it was, or one
/// [_Made]. [before] is the file's size; [width], [height] and [format] the picture's.
sealed class _Outcome {
  final int before;
  final int width;
  final int height;
  final ImageFormat format;

  const _Outcome(this.before, this.width, this.height, this.format);
}

/// Left as it was, for [why]: a note when [warn], else a step.
final class _Left extends _Outcome {
  final String why;
  final bool warn;

  const _Left(super.before, super.width, super.height, super.format, this.why, {this.warn = true});
}

/// Encoded as [bytes], in the file's own format when [own].
final class _Made extends _Outcome {
  final Uint8List bytes;
  final bool own;
  final int? quality;
  final double? score;

  const _Made(
    super.before,
    super.width,
    super.height,
    super.format,
    this.bytes, {
    this.own = true,
    this.quality,
    this.score,
  });
}

/// The worker's call for [PathImageExtensions.compress]: top level, so it is sent only these.
_Outcome Function(NativeProgress, Pointer<Uint8>) _squeezeCall(
  String abs,
  String path,
  ImageFormat? format,
  Quality? quality,
  int maxSide,
  Original original,
) =>
    (_, _) => _squeeze(abs, path, format, quality, maxSide, original);

/// The worker's call for [PathImageExtensions.optimize].
_Outcome Function(NativeProgress, Pointer<Uint8>) _optimizeCall(String abs, String path) =>
    (_, _) => _optimize(abs, path);

_Outcome _squeeze(String abs, String path, ImageFormat? format, Quality? quality, int maxSide, Original original) {
  final source = File(abs).readAsBytesSync();
  final info = ImageInfo._parse(source, path, whole: true);
  final from = info.format, out = format ?? from;
  _Left left(String why, {bool warn = true}) => _Left(source.length, info.width, info.height, from, why, warn: warn);
  if (out == from && original == Original.keep) {
    throw ArgumentError.value(
      original,
      'original',
      'Invalid original for $path: it stays ${from.name}, so the result replaces it',
    );
  }
  final q = quality?._for(out) ?? (out._lossy ? _Visual(85) : (out == ImageFormat.png ? Quality.lossless : null));
  if (q == null) return left('${from.name.toUpperCase()} has no smaller encoding here: give format: png or webp');
  final resized = maxSide > 0 && (info.width > maxSide || info.height > maxSide);
  if (from == ImageFormat.png && out == ImageFormat.png && !resized) {
    // As it is: every pixel, bit depth, palette, chunk and APNG frame kept.
    return _Made(source.length, info.width, info.height, out, _png(source, strip: false));
  }
  if (_lost(source, from, out) case final why?) return left(why);
  final h = _loadMemory(source, maxSide);
  try {
    final _Encoded encoded;
    try {
      encoded = _encodeOr(h, _plan(out, q, fallback: q), oxipng: true);
    } on _Translucent {
      return left('transparency, which JPEG cannot hold');
    }
    final (w, ht) = _probeMemory(encoded.bytes, path);
    var bytes = encoded.bytes;
    if (from == ImageFormat.jpeg && out == ImageFormat.jpeg) {
      bytes = _withSegments(bytes, _carried(source));
    } else if (from == ImageFormat.jpeg && out == ImageFormat.webp) {
      if (_exifBlock(source) case final exif?) bytes = _webpWithExif(bytes, exif, w, ht);
    }
    return _Made(source.length, w, ht, out, bytes, own: out == from, quality: encoded.quality, score: encoded.score);
  } finally {
    _ImageNative.free(Pointer.fromAddress(h));
  }
}

_Outcome _optimize(String abs, String path) {
  final source = File(abs).readAsBytesSync();
  final info = ImageInfo._parse(source, path, whole: true);
  final (w, h, from) = (info.width, info.height, info.format);
  return switch (from) {
    ImageFormat.jpeg => _Made(source.length, w, h, from, _stripJpeg(source)),
    ImageFormat.png => _Made(source.length, w, h, from, _png(source, strip: true)),
    _ => _Left(source.length, w, h, from, 'nothing to optimize losslessly in a ${from.name.toUpperCase()}'),
  };
}

/// The PNG file [bytes] recompressed by oxipng; [strip] drops the chunks that do not show.
Uint8List _png(Uint8List bytes, {required bool strip}) => NativeBridge.main.withBytes(
  bytes,
  (p, n) => NativeBridge.main.take('recompress png', (o, l) => _ImageNative.png(p, n, strip, o, l)),
);

/// The file [source] after its [outcome]: replaced as [original] says when the
/// outcome is smaller, else left as it was and not fresh.
Future<Compressed> _settle(Work work, Path source, _Outcome outcome, Original original) async {
  Compressed unchanged() {
    TaskInternals.stale(work);
    return Compressed(
      path: source,
      before: outcome.before,
      after: outcome.before,
      width: outcome.width,
      height: outcome.height,
      format: outcome.format,
    );
  }

  switch (outcome) {
    case _Left(:final why, :final warn):
      warn ? work.warn(why) : work.step(why);
      return unchanged();
    case _Made(:final bytes) when bytes.length >= outcome.before:
      work.step('not smaller');
      return unchanged();
    case _Made(:final bytes, :final own, :final quality, :final score, :final format):
      // A stop asked for while the worker ran: the file stays as it was.
      Cancel.check();
      work.step('saving');
      final dest = own ? source : source.withExt(format.extensions.first);
      await _replace(source, dest, bytes, original);
      return Compressed(
        path: dest,
        before: outcome.before,
        after: bytes.length,
        width: outcome.width,
        height: outcome.height,
        format: format,
        quality: quality,
        score: score,
      );
  }
}

/// [bytes] in place of [source] at [dest]: renamed over it first, and only then does the
/// original go as [original] says. A failure leaves [source] as it was and no result.
Future<void> _replace(Path source, Path dest, Uint8List bytes, Original original) async {
  if (dest != source) {
    if (await FileSystemEntity.type(dest, followLinks: false) != FileSystemEntityType.notFound) {
      throw PathExistsException(dest, const OSError(), 'Cannot compress $source: $dest exists');
    }
    await FileBridge.write(dest, bytes);
    try {
      switch (original) {
        case Original.trash:
          await source.trash();
        case Original.delete:
          await File(source).delete();
        case Original.keep:
      }
    } catch (_) {
      await File(dest).delete();
      rethrow;
    }
    return;
  }
  switch (original) {
    case Original.delete:
      await FileBridge.write(source, bytes);
    case Original.trash:
      await _replaceTrashing(source, bytes);
    case Original.keep:
      throw ArgumentError.value(original, 'original', 'Invalid original: the result replaces $source');
  }
}

/// [bytes] in place of [source], the original sent to the trash: it is held aside in its
/// folder under its own name, the result renamed into place, and only then the held one
/// trashed, so the original is never gone before the result is there. A trash that refuses
/// puts the original back.
Future<void> _replaceTrashing(Path source, Uint8List bytes) async {
  final token = FileBridge.token();
  final tmp = File(source.parent / '.${source.name}.$token.tmp');
  final hold = Directory(source.parent / '.compressing-$token');
  try {
    await tmp.writeAsBytes(bytes, flush: true);
    await hold.create();
    final held = Path(hold.path) / source.name;
    await FileBridge.rename(File(source), held);
    try {
      await FileBridge.rename(tmp, source);
    } catch (_) {
      await FileBridge.rename(File(held), source);
      rethrow;
    }
    try {
      await held.trash();
    } catch (_) {
      await FileBridge.rename(File(source), tmp.path);
      await FileBridge.rename(File(held), source);
      rethrow;
    }
  } finally {
    if (await tmp.exists()) await tmp.delete();
    if (await hold.exists()) await hold.delete();
  }
}

/// Why redrawing the file [b] (in [from]) as [to] would change it beyond the encoding, or
/// `null`: a decode keeps one frame of an animation and one page of a TIFF, reads a CMYK
/// JPEG's ink as screen colour, and drops a colour profile, which only a JPEG written from a
/// JPEG carries over.
String? _lost(Uint8List b, ImageFormat from, ImageFormat to) {
  final why = switch (from) {
    ImageFormat.gif when _gifFrames(b) > 1 => 'an animation: a redraw keeps one frame',
    ImageFormat.png when _pngHas(b, 'acTL') => 'an animation: a redraw keeps one frame',
    ImageFormat.webp when _webpFlags(b) & 0x02 != 0 => 'an animation: a redraw keeps one frame',
    ImageFormat.tiff when _tiffPages(b) > 1 => 'a multi-page TIFF: a redraw keeps one page',
    ImageFormat.jpeg when _jpegComponents(b) == 4 => 'a CMYK JPEG: a redraw changes its colours',
    _ => null,
  };
  if (why != null || (from == ImageFormat.jpeg && to == ImageFormat.jpeg)) return why;
  final profile = switch (from) {
    ImageFormat.jpeg => _segments(b).any((s) => s.$1 == 0xE2 && _tagged(b, s.$2 + 4, 'ICC_PROFILE')),
    ImageFormat.png => _pngHas(b, 'iCCP'),
    ImageFormat.webp => _webpFlags(b) & 0x20 != 0,
    _ => false,
  };
  return profile ? 'a colour profile ${to.name.toUpperCase()} cannot carry here' : null;
}

/// [jpeg] without the segments that hold no pixels: EXIF and XMP (APP1), IPTC (APP13),
/// comments, and the other application segments. JFIF (APP0), the ICC profile (APP2) and
/// Adobe's colour transform (APP14) stay, since they change how the pixels decode, and so does
/// the EXIF of a photo that is turned, since its orientation lives there. A file this cannot
/// walk comes back as it is.
Uint8List _stripJpeg(Uint8List jpeg) {
  final turned = (_exif(jpeg).orientation ?? 1) != 1;
  final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
  var rest = 2;
  for (final (marker, at, end) in _segments(jpeg)) {
    if (end > jpeg.length) return jpeg;
    final keep = switch (marker) {
      0xE0 || 0xEE => true,
      0xE1 => turned && _isExif(jpeg, marker, at),
      0xE2 => _tagged(jpeg, at + 4, 'ICC_PROFILE'),
      >= 0xE3 && <= 0xEF || 0xFE => false,
      _ => true, // tables, frame and restart headers
    };
    if (keep) out.add(Uint8List.sublistView(jpeg, at, end));
    rest = end;
  }
  if (rest == 2) return jpeg;
  out.add(Uint8List.sublistView(jpeg, rest));
  return out.takeBytes();
}

/// The frames of the GIF [b], counted up to two.
int _gifFrames(Uint8List b) {
  if (b.length < 13) return 0;
  int blocks(int at) {
    while (at < b.length && b[at] != 0) {
      at += b[at] + 1;
    }
    return at + 1;
  }

  var at = 13 + (b[10] & 0x80 != 0 ? 3 << ((b[10] & 7) + 1) : 0);
  var frames = 0;
  while (at < b.length && frames < 2) {
    switch (b[at]) {
      case 0x21: // an extension: label, then sub-blocks
        at = blocks(at + 2);
      case 0x2C: // an image: descriptor, local colour table, LZW size, then sub-blocks
        if (at + 10 > b.length) return frames;
        final flags = b[at + 9];
        at = blocks(at + 11 + (flags & 0x80 != 0 ? 3 << ((flags & 7) + 1) : 0));
        frames++;
      default:
        return frames;
    }
  }
  return frames;
}

/// Whether the PNG [b] has a chunk of [type] before its pixels.
bool _pngHas(Uint8List b, String type) {
  var at = 8;
  while (at + 8 <= b.length) {
    final t = String.fromCharCodes(b, at + 4, at + 8);
    if (t == type) return true;
    if (t == 'IDAT') return false;
    at += 12 + (b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3]);
  }
  return false;
}

/// The flags of an extended WebP's VP8X chunk: 0x20 a colour profile, 0x02 an animation.
int _webpFlags(Uint8List b) => b.length > 20 && _tagged(b, 12, 'VP8X') ? b[20] : 0;

/// The pages of the TIFF [b], counted up to two.
int _tiffPages(Uint8List b) {
  if (b.length < 8) return 0;
  final d = ByteData.sublistView(b);
  final e = b[0] == 0x49 ? Endian.little : Endian.big;
  final first = d.getUint32(4, e);
  if (first == 0 || first + 2 > b.length) return 0;
  final next = first + 2 + 12 * d.getUint16(first, e);
  return next + 4 <= b.length && d.getUint32(next, e) != 0 ? 2 : 1;
}

/// The colour channels of the JPEG [b]: 1 grey, 3 colour, 4 CMYK; 0 when unread.
int _jpegComponents(Uint8List b) {
  for (final (m, at, end) in _segments(b)) {
    if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC && at + 9 < end && at + 9 < b.length) {
      return b[at + 9];
    }
  }
  return 0;
}

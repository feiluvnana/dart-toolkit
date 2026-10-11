import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../hash/hash.dart';

/// An in-memory 8-bit RGBA raster with one-word transforms ([crop], [fit], [resize],
/// [grayscale]) and PNG load/save. All pure Dart.
///
/// ```dart
/// final img = Image.blank(width: 100, height: 50);
/// final cut = img.crop(x: 10, y: 10, width: 30, height: 20);
/// final thumb = img.fit(150, 150);
/// await thumb.save('thumb.png');
/// ```
final class Image {
  final int w;
  final int h;
  final Uint8List bytes;

  Image._(this.w, this.h, this.bytes);

  /// A blank [w]x[h] image filled with [color] (`0xAARRGGBB`).
  factory Image.blank({required int width, required int height, int color = 0x00000000}) {
    final img = Image._(width, height, Uint8List(width * height * 4));
    if (color != 0) img.fill(color);
    return img;
  }

  /// Wraps [bytes] (RGBA, `w*h*4`) as an image.
  factory Image.fromBytes(Uint8List bytes, {required int width, required int height}) => Image._(width, height, bytes);

  /// Loads a PNG from a path, `File` or raw bytes.
  static Future<Image> load(Object src) async {
    final Uint8List data;
    if (src is Uint8List) {
      data = src;
    } else if (src is List<int>) {
      data = Uint8List.fromList(src);
    } else {
      data = await File(src is File ? src.path : src.toString()).readAsBytes();
    }
    return _decodePng(data);
  }

  /// Width.
  int get width => w;

  /// Height.
  int get height => h;

  /// The pixel at ([x], [y]) as `0xAARRGGBB`.
  int pixel(int x, int y) {
    final i = (y * w + x) * 4;
    return (bytes[i + 3] << 24) | (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
  }

  /// Fills every pixel with [color] (`0xAARRGGBB`), in place.
  Image fill(int color) {
    final a = (color >>> 24) & 0xFF, r = (color >>> 16) & 0xFF, g = (color >>> 8) & 0xFF, b = color & 0xFF;
    for (var i = 0; i < bytes.length; i += 4) {
      bytes[i] = r;
      bytes[i + 1] = g;
      bytes[i + 2] = b;
      bytes[i + 3] = a;
    }
    return this;
  }

  /// A [width]x[height] region anchored at ([x], [y]).
  Image crop({int x = 0, int y = 0, int? width, int? height}) {
    final cw = width ?? w - x;
    final ch = height ?? h - y;
    final out = Uint8List(cw * ch * 4);
    for (var row = 0; row < ch; row++) {
      final sy = y + row;
      if (sy < 0 || sy >= h) continue;
      for (var col = 0; col < cw; col++) {
        final sx = x + col;
        if (sx < 0 || sx >= w) continue;
        final src = (sy * w + sx) * 4;
        final dst = (row * cw + col) * 4;
        out[dst] = bytes[src];
        out[dst + 1] = bytes[src + 1];
        out[dst + 2] = bytes[src + 2];
        out[dst + 3] = bytes[src + 3];
      }
    }
    return Image._(cw, ch, out);
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
        out[dst] = bytes[src];
        out[dst + 1] = bytes[src + 1];
        out[dst + 2] = bytes[src + 2];
        out[dst + 3] = bytes[src + 3];
      }
    }
    return Image._(nw, nh, out);
  }

  /// A greyscale copy using luma weights.
  Image grayscale() {
    final out = Uint8List.fromList(bytes);
    for (var i = 0; i < out.length; i += 4) {
      final v = (0.299 * out[i] + 0.587 * out[i + 1] + 0.114 * out[i + 2]).round().clamp(0, 255);
      out[i] = v;
      out[i + 1] = v;
      out[i + 2] = v;
    }
    return Image._(w, h, out);
  }

  /// A copy scaled so its longest side is at most [max].
  Image thumbnail(int max) => w >= h ? fit(max, (max * h / w).round()) : fit((max * w / h).round(), max);

  /// Encodes this image as PNG bytes.
  Uint8List toBytes() => _encodePng(this);

  /// Writes this image as PNG to [dst].
  Future<void> save(Object dst, {int? quality}) async {
    final path = dst is File ? dst.path : dst.toString();
    await File(path).writeAsBytes(_encodePng(this));
  }

  /// Composes a `w x h` [Image] of the raw pixel buffer length check.
  @override
  String toString() => 'Image(${w}x$h)';
}

// ---------------------------------------------------------------------------
// PNG codec
// ---------------------------------------------------------------------------

const List<int> _pngSig = [137, 80, 78, 71, 13, 10, 26, 10];

Image _decodePng(Uint8List data) {
  for (var i = 0; i < 8; i++) {
    if (data[i] != _pngSig[i]) throw const FormatException('Not a PNG file');
  }
  var off = 8;
  int width = 0, height = 0, bitDepth = 8, colorType = 6, interlace = 0;
  final idat = BytesBuilder(copy: true);
  List<int>? palette;
  List<int>? trns;
  while (off < data.length) {
    final len = _readBE32(data, off);
    final type = String.fromCharCodes(data.sublist(off + 4, off + 8));
    final body = data.sublist(off + 8, off + 8 + len);
    switch (type) {
      case 'IHDR':
        width = _readBE32(body, 0);
        height = _readBE32(body, 4);
        bitDepth = body[8];
        colorType = body[9];
        interlace = body[12];
      case 'PLTE':
        palette = body;
      case 'tRNS':
        trns = body;
      case 'IDAT':
        idat.add(body);
      case 'IEND':
        off = data.length;
        continue;
    }
    off += 12 + len;
  }
  if (interlace != 0) throw UnsupportedError('Interlaced PNG is not supported');
  final channels = switch (colorType) {
    0 => 1,
    2 => 3,
    3 => 1,
    4 => 2,
    6 => 4,
    _ => throw FormatException('Unsupported PNG colour type $colorType'),
  };
  final raw = ZLibCodec().decode(idat.takeBytes());
  final sampleBytes = (bitDepth + 7) ~/ 8;
  final stride = ((width * channels * bitDepth + 7) ~/ 8);
  final out = Uint8List(width * height * 4);
  final prev = Uint8List(stride);
  final row = Uint8List(stride);
  var pos = 0;
  for (var y = 0; y < height; y++) {
    final filter = raw[pos++];
    row.setRange(0, stride, raw, pos);
    pos += stride;
    _unfilter(filter, row, prev, channels * sampleBytes);
    _rowToRgba(row, out, y * width * 4, width, colorType, bitDepth, channels, palette, trns);
    prev.setRange(0, stride, row);
  }
  return Image._(width, height, out);
}

void _unfilter(int filter, Uint8List row, Uint8List prev, int bpp) {
  final n = row.length;
  for (var i = 0; i < n; i++) {
    final a = i >= bpp ? row[i - bpp] : 0;
    final b = prev[i];
    final c = i >= bpp ? prev[i - bpp] : 0;
    switch (filter) {
      case 0:
        break;
      case 1:
        row[i] = (row[i] + a) & 0xFF;
      case 2:
        row[i] = (row[i] + b) & 0xFF;
      case 3:
        row[i] = (row[i] + ((a + b) >> 1)) & 0xFF;
      case 4:
        row[i] = (row[i] + _paeth(a, b, c)) & 0xFF;
      default:
        throw FormatException('Bad PNG filter $filter');
    }
  }
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

void _rowToRgba(
  Uint8List row,
  Uint8List out,
  int base,
  int width,
  int colorType,
  int bitDepth,
  int channels,
  List<int>? palette,
  List<int>? trns,
) {
  final step = (bitDepth + 7) ~/ 8;
  for (var x = 0; x < width; x++) {
    final i = base + x * 4;
    final s = x * channels * step;
    switch (colorType) {
      case 0:
        final g = row[s];
        out[i] = g;
        out[i + 1] = g;
        out[i + 2] = g;
        out[i + 3] = 255;
      case 2:
        out[i] = row[s];
        out[i + 1] = row[s + step];
        out[i + 2] = row[s + 2 * step];
        out[i + 3] = 255;
      case 3:
        final idx = row[s];
        if (palette == null || idx * 3 + 2 >= palette.length) continue;
        out[i] = palette[idx * 3];
        out[i + 1] = palette[idx * 3 + 1];
        out[i + 2] = palette[idx * 3 + 2];
        out[i + 3] = trns != null && idx < trns.length ? trns[idx] : 255;
      case 4:
        final g = row[s];
        out[i] = g;
        out[i + 1] = g;
        out[i + 2] = g;
        out[i + 3] = row[s + step];
      case 6:
        out[i] = row[s];
        out[i + 1] = row[s + step];
        out[i + 2] = row[s + 2 * step];
        out[i + 3] = row[s + 3 * step];
    }
  }
}

Uint8List _encodePng(Image img) {
  final raw = Uint8List(img.h * (1 + img.w * 4));
  var p = 0;
  for (var y = 0; y < img.h; y++) {
    raw[p++] = 0;
    final rowStart = y * img.w * 4;
    raw.setRange(p, p + img.w * 4, img.bytes, rowStart);
    p += img.w * 4;
  }
  final compressed = ZLibCodec(level: 6).encode(raw);
  final out = BytesBuilder(copy: true)..add(_pngSig);
  final ihdr = BytesBuilder(copy: true)
    ..add(_be32(img.w))
    ..add(_be32(img.h))
    ..addByte(8)
    ..addByte(6)
    ..addByte(0)
    ..addByte(0)
    ..addByte(0);
  _chunk(out, 'IHDR', ihdr.takeBytes());
  _chunk(out, 'IDAT', compressed);
  _chunk(out, 'IEND', Uint8List(0));
  return out.takeBytes();
}

void _chunk(BytesBuilder out, String type, List<int> data) {
  out.add(_be32(data.length));
  final typeBytes = type.codeUnits;
  out.add(typeBytes);
  out.add(data);
  out.add(Hash.crc32([...typeBytes, ...data]));
}

Uint8List _be32(int v) => Uint8List.fromList([(v >>> 24) & 0xFF, (v >>> 16) & 0xFF, (v >>> 8) & 0xFF, v & 0xFF]);

int _readBE32(List<int> b, int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

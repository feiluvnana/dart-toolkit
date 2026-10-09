part of '../../image.dart';

// The JPEG metadata this library reads and carries: one segment walker for all of it.

typedef _Exif = ({DateTime? taken, int? orientation, String? camera});

final _exifStamp = RegExp(r'^(\d{4}):(\d\d):(\d\d) (\d\d):(\d\d):(\d\d)');

/// Each segment of the JPEG [b] before its pixels, as `(marker, start, end)`: [start] is the
/// segment's `0xFF`, [end] where its length says it ends, which may pass the end of [b] when
/// [b] is a file's first bytes. Fill bytes before a marker are skipped.
Iterable<(int, int, int)> _segments(Uint8List b) sync* {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return;
  var at = 2;
  while (at + 4 <= b.length && b[at] == 0xFF) {
    final marker = b[at + 1];
    if (marker == 0xFF) {
      at++; // a fill byte before a marker
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) return; // pixels start: nothing of ours after them
    final end = at + 2 + (b[at + 2] << 8 | b[at + 3]);
    yield (marker, at, end);
    at = end;
  }
}

/// Whether [bytes] at [at] start with the ASCII [tag].
bool _tagged(Uint8List bytes, int at, String tag) {
  if (at + tag.length > bytes.length) return false;
  for (var i = 0; i < tag.length; i++) {
    if (bytes[at + i] != tag.codeUnitAt(i)) return false;
  }
  return true;
}

/// Whether the segment at [at] is the EXIF APP1: `Exif\0\0` and a TIFF header.
bool _isExif(Uint8List b, int marker, int at) =>
    marker == 0xE1 && _tagged(b, at + 4, 'Exif') && at + 10 <= b.length && b[at + 8] == 0 && b[at + 9] == 0;

/// The EXIF a JPEG [head] carries before its pixels: DateTimeOriginal (else DateTime) as local
/// time, Orientation (1–8), and Make with Model; each `null` when absent or unreadable.
_Exif _exif(Uint8List head) {
  for (final (marker, at, end) in _segments(head)) {
    if (_isExif(head, marker, at)) return _tiff(ByteData.sublistView(head, at + 10, end.clamp(at + 10, head.length)));
  }
  return (taken: null, orientation: null, camera: null);
}

/// The luminance table of JPEG Annex K, which libjpeg scales by `-quality`.
const _annexK = [
  16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, //
  14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
  49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
];

/// The libjpeg quality whose scaled Annex K table is nearest the JPEG [head]'s luminance table
/// (table 0); `null` when the head has none. Entry order does not matter: the sorted tables are
/// compared, so zigzag and natural order read alike.
int? _jpegQuality(Uint8List head) {
  for (final (marker, start, end) in _segments(head)) {
    if (marker != 0xDB) continue;
    final stop = end < head.length ? end : head.length;
    for (var at = start + 4; at < stop;) {
      final wide = head[at] >> 4 == 1, id = head[at] & 0x0F;
      final size = wide ? 128 : 64;
      if (at + 1 + size > stop) return null;
      if (id == 0) {
        final table = [
          for (var i = 0; i < 64; i++) wide ? head[at + 1 + 2 * i] << 8 | head[at + 2 + 2 * i] : head[at + 1 + i],
        ]..sort();
        return _nearestQuality(table);
      }
      at += 1 + size;
    }
  }
  return null;
}

int _nearestQuality(List<int> sorted) {
  final reference = [..._annexK]..sort();
  var (best, bestError) = (50, 1 << 62);
  for (var q = 1; q <= 100; q++) {
    final scale = q < 50 ? 5000 ~/ q : 200 - 2 * q;
    var error = 0;
    for (var i = 0; i < 64; i++) {
      final v = ((reference[i] * scale + 50) ~/ 100).clamp(1, 255);
      error += (v - sorted[i]).abs();
    }
    if (error < bestError) (best, bestError) = (q, error);
  }
  return best;
}

/// The byte order of the TIFF block [t], or `null` when it is not one.
Endian? _order(ByteData t) {
  if (t.lengthInBytes < 8) return null;
  final order = switch (t.getUint16(0)) {
    0x4949 => Endian.little,
    0x4D4D => Endian.big,
    _ => null,
  };
  return order != null && t.getUint16(2, order) == 42 ? order : null;
}

_Exif _tiff(ByteData t) {
  const none = (taken: null, orientation: null, camera: null);
  final order = _order(t);
  if (order == null) return none;
  int? u16(int o) => o + 2 <= t.lengthInBytes ? t.getUint16(o, order) : null;
  int? u32(int o) => o + 4 <= t.lengthInBytes ? t.getUint32(o, order) : null;
  // Tag -> (type, count, value-or-offset field position) for one IFD.
  Map<int, (int, int, int)> ifd(int? at) {
    final n = at == null ? null : u16(at);
    if (n == null) return const {};
    return {
      for (var i = 0, e = at! + 2; i < n && e + 12 <= t.lengthInBytes; i++, e += 12)
        t.getUint16(e, order): (t.getUint16(e + 2, order), t.getUint32(e + 4, order), e + 8),
    };
  }

  String? ascii(Map<int, (int, int, int)> d, int tag) {
    final (type, count, field) = d[tag] ?? (0, 0, 0);
    if (type != 2 || count == 0) return null;
    final start = count <= 4 ? field : u32(field);
    if (start == null || start + count > t.lengthInBytes) return null;
    final s = latin1.decode(Uint8List.sublistView(t, start, start + count)).replaceAll('\x00', '').trim();
    return s.isEmpty ? null : s;
  }

  final ifd0 = ifd(u32(4));
  final sub = switch (ifd0[0x8769]) {
    (_, _, final f) => ifd(u32(f)),
    null => const <int, (int, int, int)>{},
  };
  final orientation = switch (ifd0[0x0112]) {
    (3, _, final f) => u16(f),
    _ => null,
  };
  final make = ascii(ifd0, 0x010F), model = ascii(ifd0, 0x0110);
  final camera = model == null ? make : (make == null || model.startsWith(make) ? model : '$make $model');
  final stamp = ascii(sub, 0x9003) ?? ascii(ifd0, 0x0132);
  final m = stamp == null ? null : _exifStamp.firstMatch(stamp);
  final taken = m == null
      ? null
      : DateTime(
          int.parse(m[1]!),
          int.parse(m[2]!),
          int.parse(m[3]!),
          int.parse(m[4]!),
          int.parse(m[5]!),
          int.parse(m[6]!),
        );
  return (taken: taken, orientation: orientation, camera: camera);
}

/// [tiff], an EXIF TIFF block, with its Orientation set to 1: a copy, for pixels already
/// turned upright.
Uint8List _upright(Uint8List tiff) {
  final out = Uint8List.fromList(tiff);
  final t = ByteData.sublistView(out);
  final order = _order(t);
  if (order == null) return out;
  final at = t.getUint32(4, order);
  if (at + 2 > out.length) return out;
  final n = t.getUint16(at, order);
  for (var i = 0, e = at + 2; i < n && e + 12 <= out.length; i++, e += 12) {
    if (t.getUint16(e, order) == 0x0112 && t.getUint16(e + 2, order) == 3) t.setUint16(e + 8, 1, order);
  }
  return out;
}

/// The segments of the JPEG [source] a re-encode carries over: EXIF (its orientation reset,
/// since the pixels are upright now), XMP, the ICC profile and IPTC.
List<Uint8List> _carried(Uint8List source) => [
  for (final (m, at, end) in _segments(source))
    if (end <= source.length)
      if (_isExif(source, m, at))
        Uint8List.fromList([
          ...Uint8List.sublistView(source, at, at + 10),
          ..._upright(Uint8List.sublistView(source, at + 10, end)),
        ])
      else if (m == 0xE1 || m == 0xE2 && _tagged(source, at + 4, 'ICC_PROFILE') || m == 0xED)
        Uint8List.sublistView(source, at, end),
];

/// The EXIF TIFF block of the JPEG [source], its orientation reset; `null` when it has none.
Uint8List? _exifBlock(Uint8List source) {
  for (final (m, at, end) in _segments(source)) {
    if (end <= source.length && _isExif(source, m, at)) return _upright(Uint8List.sublistView(source, at + 10, end));
  }
  return null;
}

/// The JPEG [b] with [segments] after its JFIF header.
Uint8List _withSegments(Uint8List b, List<Uint8List> segments) {
  if (segments.isEmpty) return b;
  final at = _segments(b).where((s) => s.$1 == 0xE0).map((s) => s.$3).firstOrNull ?? 2;
  return (BytesBuilder(copy: false)
        ..add(Uint8List.sublistView(b, 0, at))
        ..add([for (final s in segments) ...s])
        ..add(Uint8List.sublistView(b, at)))
      .takeBytes();
}

/// The WebP [webp] with the EXIF block [exif]: an extended file (VP8X) with an `EXIF` chunk. A
/// file this cannot read comes back as it is.
Uint8List _webpWithExif(Uint8List webp, Uint8List exif, int width, int height) {
  if (webp.length < 20 || !_tagged(webp, 0, 'RIFF') || !_tagged(webp, 8, 'WEBP')) return webp;
  List<int> le32(int v) => [v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF];
  List<int> chunk(String tag, List<int> body) => [
    ...tag.codeUnits,
    ...le32(body.length),
    ...body,
    if (body.length.isOdd) 0,
  ];
  final chunks = BytesBuilder(copy: false);
  if (_tagged(webp, 12, 'VP8X')) {
    // Extended already (alpha): set the EXIF flag and add the chunk at the end.
    final body = Uint8List.fromList(webp.sublist(12));
    body[8] |= 0x08;
    chunks.add(body);
  } else {
    final w = width - 1, h = height - 1;
    chunks
      ..add(
        chunk('VP8X', [
          0x08,
          0,
          0,
          0,
          w & 0xFF,
          w >> 8 & 0xFF,
          w >> 16 & 0xFF,
          h & 0xFF,
          h >> 8 & 0xFF,
          h >> 16 & 0xFF,
        ]),
      )
      ..add(Uint8List.sublistView(webp, 12));
  }
  chunks.add(chunk('EXIF', exif));
  final body = chunks.takeBytes();
  return Uint8List.fromList([...'RIFF'.codeUnits, ...le32(body.length + 4), ...'WEBP'.codeUnits, ...body]);
}

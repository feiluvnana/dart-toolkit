/// The engine behind `image` and `video`: ffprobe/ffmpeg runs through
/// `shell` (so Ctrl-C ends them), one shared limit on concurrent encodes,
/// readers spooled to a temp file once, and the header facts Dart reads
/// without a spawn (image size, EXIF orientation, animation).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../pool.dart' show Pool;
import '../shell.dart';
import 'cache.dart' as cache;
import 'posix.dart' as posix;
import 'quiet.dart';
import 'tool.dart';

// ── running ───────────────────────────────────────────────────────────────

/// Encodes at once: each ffmpeg already uses several cores, so eight
/// download lanes compressing together queue here instead of thrashing.
final _encodes = Pool(limit: math.max(1, io.Platform.numberOfProcessors ~/ 2));

/// Run [job] in one of the shared encode lanes.
Future<T> encode<T>(Future<T> Function() job) => _encodes.run(job);

/// Run ffmpeg with [args] (inputs and outputs included) under the shared
/// limit. [needs] are the encoders used. [total] (microseconds of output)
/// turns `-progress` lines into [onProgress] calls; progress goes to
/// stdout, so a call with [onProgress] writes its output to a file. A failure is a
/// [ContentException] carrying ffmpeg's last error lines.
Future<List<int>> ffmpeg(
  List<String> args, {
  Set<String> needs = const {},
  int? total,
  void Function(int done, int? total)? onProgress,
}) async {
  final exe = await tool(Tool.ffmpeg, needs: needs);
  final command = [exe, '-hide_banner', '-nostdin', '-loglevel', 'error'];
  return encode(() async {
    if (onProgress == null) {
      final out = await Shell.run([...command, ...args]);
      if (!out.ok()) throw failure('ffmpeg failed', out.err());
      return out.bytes();
    }
    // Progress lines on stdout as ffmpeg writes them; its stderr is kept
    // for the error, never shown.
    final read = Shell.read([...command, '-progress', 'pipe:1', '-stats_period', '0.25', ...args]);
    quiet[read] = true;
    try {
      await for (final line in read.lines()) {
        if (line.startsWith('out_time_us=')) {
          final us = int.tryParse(line.substring(12));
          if (us != null && us >= 0) onProgress(total == null ? us : math.min(us, total), total);
        } else if (line == 'progress=end' && total != null) {
          onProgress(total, total);
        }
      }
    } on ExitException catch (e) {
      throw failure('ffmpeg failed', e.message.replaceFirst(RegExp(r'^exit -?\d+: '), ''));
    }
    return const <int>[];
  });
}

/// Why ffmpeg or ffprobe failed, from its [stderr]: a network failure
/// reading a URL is a [io.SocketException] (transient: `pool` retries it),
/// anything else a [ContentException].
Exception failure(String what, String stderr) {
  final message = '$what: ${toolTail(stderr)}';
  return _network.hasMatch(stderr) ? io.SocketException(message) : ContentException(message);
}

final _network = RegExp(
  r'Connection (refused|reset|timed out)|Failed to resolve hostname|Network is unreachable|No route to host|'
  r'Operation timed out|Server returned (5XX|429)|Broken pipe',
);

/// ffprobe's JSON for [input] (a path or URL). Unreadable input is a
/// [ContentException].
Future<Map<String, Object?>> ffprobe(String input) async {
  final exe = await tool(Tool.ffprobe);
  final out = await Shell.run([
    exe,
    '-v',
    'error',
    '-show_format',
    '-show_streams',
    '-show_stream_groups',
    '-of',
    'json',
    input,
  ]);
  if (!out.ok()) throw failure('not a readable media file', out.err());
  try {
    return (jsonDecode(await out.text()) as Map).cast<String, Object?>();
  } on FormatException catch (e) {
    throw ContentException('ffprobe gave no JSON', null, null, e);
  }
}


// ── sources ───────────────────────────────────────────────────────────────

/// Where spooled readers go: in the user cache, owner-only (never a shared
/// temp folder another user can read or plant names in). Files older than
/// a day are swept on the next spool (a script that ends normally cannot
/// delete its own).
final _spoolDir = p.join(cache.userCacheDir(), 'dart_toolkit', 'media');
var _swept = false;

/// The spool folder, made owner-only once per process.
Future<io.Directory> _spool() => _made ??= () async {
  final dir = await io.Directory(_spoolDir).create(recursive: true);
  if (!io.Platform.isWindows) await posix.chmod(dir.path, 0x1c0); // 0700
  return dir;
}();
Future<io.Directory>? _made;

/// A spooled temp file, deleted once nothing holds this token (an
/// [Image]/Video and every value derived from it keep it), or after a day
/// by the sweep when the VM exits first.
final class Temp {
  Temp(this.path) {
    _gone.attach(this, path);
  }

  final String path;

  static final _gone = Finalizer<String>((path) {
    try {
      io.File(path).deleteSync();
    } catch (_) {}
  });
}

/// Write [chunks] to a fresh temp file and return its path.
Future<String> spool(Stream<List<int>> chunks, {String ext = 'bin'}) async {
  final dir = await _spool();
  if (!_swept) {
    _swept = true;
    unawaited(_sweep(dir));
  }
  final file = io.File(p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}-${io.pid}-${_n++}.$ext'));
  await posix.writeAll(file, chunks);
  return file.path;
}

var _n = 0;

Future<void> _sweep(io.Directory dir) async {
  final old = DateTime.now().subtract(const Duration(days: 1));
  try {
    await for (final e in dir.list()) {
      if (e is io.File && (await e.stat()).modified.isBefore(old)) await e.delete().catchError((_) => e);
    }
  } catch (_) {}
}

/// A temp output path next to the spool, for encodes that need a seekable
/// output (mp4 `faststart`, image muxers).
Future<String> tempOut(String ext) async {
  await _spool();
  return p.join(_spoolDir, '${DateTime.now().microsecondsSinceEpoch}-${io.pid}-${_n++}.out.$ext');
}

/// Stream [path] and delete it after.
Stream<List<int>> readAndDelete(String path) async* {
  try {
    yield* io.File(path).openRead();
  } finally {
    await io.File(path).delete().catchError((_) => io.File(path));
  }
}

/// What `Image.compress` and `Video.compress` did to a file; [text] says
/// it in words.
sealed class Compression {
  const Compression();

  /// In words: `1.6 MB (compressed from 2.7 MB, -39%)`, or `kept: re-encoding
  /// would not make it smaller`.
  String text();
}

/// The file was replaced by its re-encode: [before] and [after] bytes.
final class Compressed extends Compression {
  const Compressed(this.before, this.after);
  final int before, after;

  @override
  String text() => '${after.size()} (compressed from ${before.size()}, -${((before - after) * 100 / before).round()}%)';
}

/// The file was left as it was, for [reason].
final class Kept extends Compression {
  const Kept(this.reason);
  final KeptReason reason;

  @override
  String text() => 'kept: ${reason.text()}';
}

/// Why a file was [Kept]; [text] says it in words.
enum KeptReason {
  /// Not an image (or a video) this can read.
  unknown('not a supported image or video'),

  /// Re-encoding would lose something: animation, CMYK, a format with no
  /// encoder (HEIC, AVI), a file with no picture.
  lossy('re-encoding would lose something'),

  /// The re-encode was not at least 5% smaller.
  notSmaller('re-encoding would not make it smaller');

  const KeptReason(this._text);
  final String _text;

  /// The reason in words.
  String text() => _text;
}

/// Replace [path] with [newer] when it is [by] (a fraction) smaller,
/// else delete [newer].
Future<Compression> replaceIfSmaller(String path, String newer, {double by = 0}) async {
  final before = await io.File(path).length();
  final after = await io.File(newer).length();
  if (after >= before || after > before * (1 - by)) {
    await io.File(newer).delete().catchError((_) => io.File(newer));
    return const Kept(KeptReason.notSmaller);
  }
  await io.File(newer).rename(path);
  return Compressed(before, after);
}

// ── header facts ──────────────────────────────────────────────────────────

/// `'avif'` or `'heic'` when a `ftyp` box names a HEIF image (photos share
/// the box with MP4/MOV video), else null.
String? heif(List<int> bytes) {
  if (bytes.length < 12) return null;
  String brand(int i) => String.fromCharCodes(bytes.sublist(i, math.min(i + 4, bytes.length)));
  final major = brand(8);
  if (const {'avif', 'avis'}.contains(major)) return 'avif';
  if (const {'heic', 'heix', 'heim', 'heis', 'hevc', 'hevx'}.contains(major)) return 'heic';
  if (major == 'mif1' || major == 'msf1') {
    final size = bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3];
    for (var i = 16; i + 4 <= math.min(size, bytes.length); i += 4) {
      if (brand(i) == 'avif') return 'avif';
    }
    return 'heic';
  }
  return null;
}

// ── header facts (cont.) ──────────────────────────────────────────────────────────

/// What Dart reads from an image header without decoding: the stored
/// size, the EXIF orientation (1 when none), animation, and JPEG colour
/// components (4 = CMYK).
typedef Header = ({int width, int height, int orientation, bool animated, int components});

/// The header of a JPEG, PNG, GIF, WebP or BMP; null for anything else or a
/// header cut short (ffprobe then decides).
Header? header(Uint8List b) {
  try {
    if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8) return _jpeg(b);
    if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50) return _png(b);
    if (b.length > 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return _gif(b);
    if (b.length > 30 && _at(b, 0, 'RIFF') && _at(b, 8, 'WEBP')) return _webp(b);
    if (b.length > 26 && b[0] == 0x42 && b[1] == 0x4D) {
      return (
        width: _le32(b, 18),
        height: _le32(b, 22).toSigned(32).abs(),
        orientation: 1,
        animated: false,
        components: 3,
      );
    }
  } on RangeError {
    return null;
  }
  return null;
}

bool _at(Uint8List b, int i, String s) {
  if (b.length < i + s.length) return false;
  for (var k = 0; k < s.length; k++) {
    if (b[i + k] != s.codeUnitAt(k)) return false;
  }
  return true;
}

int _be16(Uint8List b, int i) => b[i] << 8 | b[i + 1];
int _be32(Uint8List b, int i) => b[i] << 24 | b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3];
int _le16(Uint8List b, int i) => b[i] | b[i + 1] << 8;
int _le24(Uint8List b, int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16;
int _le32(Uint8List b, int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;

Header? _jpeg(Uint8List b) {
  var orientation = 1;
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return null;
    final m = b[i + 1];
    if (m == 0xFF) {
      i++;
      continue;
    }
    final len = _be16(b, i + 2);
    if (m == 0xE1 && _at(b, i + 4, 'Exif\x00\x00')) orientation = _orientation(b, i + 10, i + 2 + len) ?? 1;
    final sof = m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC;
    if (sof) {
      return (
        width: _be16(b, i + 7),
        height: _be16(b, i + 5),
        orientation: orientation,
        animated: false,
        components: b[i + 9],
      );
    }
    if (m == 0xDA) return null;
    i += 2 + len;
  }
  return null;
}

/// The EXIF Orientation tag in a TIFF block at [start]..[end].
int? _orientation(Uint8List b, int start, int end) {
  final tag = _orientationAt(b, start, end);
  if (tag == null) return null;
  final (at, little) = tag;
  final v = little ? _le16(b, at) : _be16(b, at);
  return v >= 1 && v <= 8 ? v : null;
}

/// Offset of the Orientation value (and the byte order) in a TIFF block.
(int, bool)? _orientationAt(Uint8List b, int start, int end) {
  if (end > b.length || start + 8 > end) return null;
  final little = b[start] == 0x49;
  int u16(int i) => little ? _le16(b, i) : _be16(b, i);
  int u32(int i) => little ? _le32(b, i) : _be32(b, i);
  final ifd = start + u32(start + 4);
  if (ifd + 2 > end) return null;
  final count = u16(ifd);
  for (var k = 0; k < count; k++) {
    final e = ifd + 2 + k * 12;
    if (e + 12 > end) return null;
    if (u16(e) == 0x0112) return (e + 8, little);
  }
  return null;
}

Header _png(Uint8List b) {
  var animated = false;
  var i = 8;
  while (i + 8 <= b.length) {
    final len = _be32(b, i);
    if (_at(b, i + 4, 'acTL')) animated = true;
    if (_at(b, i + 4, 'IDAT')) break;
    i += 12 + len;
  }
  return (width: _be32(b, 16), height: _be32(b, 20), orientation: 1, animated: animated, components: 3);
}

Header _gif(Uint8List b) {
  // Count image descriptors: a second one means an animation.
  var frames = 0;
  var i = 13;
  if (b[10] & 0x80 != 0) i += 3 * (1 << ((b[10] & 7) + 1));
  while (i < b.length && frames < 2) {
    final t = b[i];
    if (t == 0x3B) break;
    if (t == 0x21) {
      i += 2;
      while (i < b.length && b[i] != 0) {
        i += b[i] + 1;
      }
      i++;
    } else if (t == 0x2C) {
      frames++;
      final flags = b[i + 9];
      i += 10;
      if (flags & 0x80 != 0) i += 3 * (1 << ((flags & 7) + 1));
      i++; // LZW minimum code size
      while (i < b.length && b[i] != 0) {
        i += b[i] + 1;
      }
      i++;
    } else {
      break;
    }
  }
  return (width: _le16(b, 6), height: _le16(b, 8), orientation: 1, animated: frames > 1, components: 3);
}

Header? _webp(Uint8List b) {
  if (_at(b, 12, 'VP8X')) {
    return (
      width: 1 + _le24(b, 24),
      height: 1 + _le24(b, 27),
      orientation: 1,
      animated: b[20] & 0x02 != 0,
      components: 3,
    );
  }
  if (_at(b, 12, 'VP8 ')) {
    return (
      width: _le16(b, 26) & 0x3FFF,
      height: _le16(b, 28) & 0x3FFF,
      orientation: 1,
      animated: false,
      components: 3,
    );
  }
  if (_at(b, 12, 'VP8L')) {
    final v = _le32(b, 21);
    return (width: (v & 0x3FFF) + 1, height: ((v >> 14) & 0x3FFF) + 1, orientation: 1, animated: false, components: 3);
  }
  return null;
}

/// [out] (a JPEG ffmpeg wrote) with [src]'s EXIF and ICC segments, the
/// orientation reset to 1 (the pixels are already turned): a re-encode
/// keeps the date taken, the camera and the colour profile.
Uint8List withMetadata(Uint8List out, Uint8List src) {
  final keep = BytesBuilder(copy: false);
  var i = 2;
  while (i + 4 <= src.length && src[i] == 0xFF) {
    final m = src[i + 1];
    if (m == 0xDA || (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC)) break;
    final len = _be16(src, i + 2);
    final end = i + 2 + len;
    if (end > src.length) break;
    final exif = m == 0xE1 && _at(src, i + 4, 'Exif\x00\x00');
    final icc = m == 0xE2 && _at(src, i + 4, 'ICC_PROFILE\x00');
    if (exif || icc) {
      final seg = Uint8List.fromList(src.sublist(i, end));
      if (exif) {
        final at = _orientationAt(seg, 10, seg.length);
        if (at != null) {
          final (o, little) = at;
          seg[o] = little ? 1 : 0;
          seg[o + 1] = little ? 0 : 1;
        }
      }
      keep.add(seg);
    }
    i = end;
  }
  if (keep.isEmpty) return out;
  // After SOI and a JFIF APP0, where readers look for them.
  var at = 2;
  if (out.length > 6 && out[2] == 0xFF && out[3] == 0xE0) at = 4 + _be16(out, 4);
  return (BytesBuilder(copy: false)
        ..add(Uint8List.sublistView(out, 0, at))
        ..add(keep.takeBytes())
        ..add(Uint8List.sublistView(out, at)))
      .takeBytes();
}

/// A `quality:` is 1–100, else an [ArgumentError].
void checkQuality(int quality) {
  if (quality < 1 || quality > 100) throw ArgumentError.value(quality, 'quality', 'must be 1..100');
}

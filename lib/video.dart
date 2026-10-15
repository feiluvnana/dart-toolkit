/// Decode and compress videos. Thin facade over FFmpeg.
///
/// ```dart
/// final clip = await http.get(videoUrl).video();
/// await (clip.encode(VideoFormat.mp4, quality: 75) > Fs.file('compressed.mp4'));
/// ```
///
/// Public surface is exactly: [Video], [VideoFormat].
/// - `Video.decode()` decodes bytes, `Reader.video()` reads a stream.
/// - `Video.sniff()` names the format from the header bytes.
/// - [Video] supports `width` `height` `duration` `fps` `encode`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'archive.dart';
import 'http.dart';
import 'shell.dart';
import 'src/cache.dart' as cache;
import 'src/posix.dart' as posix;

export 'core.dart';

/// Video formats: [Video.sniff] names one, [Video.encode] writes all supported formats.
/// `.name` is the usual file extension.
enum VideoFormat { mp4, webm, mkv, mov, avi }

/// A video value.
final class Video {
  Video._(
    this._bytes,
    this._width,
    this._height,
    this._duration,
    this._fps,
  );

  final Uint8List _bytes;
  final int _width;
  final int _height;
  final Duration _duration;
  final double _fps;

  /// The format named by the magic bytes, or null when they are not a supported video.
  /// Reads the header only, no decode:
  /// `'clip.${(Video.sniff(data) ?? .mp4).name}'` names a downloaded file.
  static VideoFormat? sniff(List<int> bytes) {
    if (bytes.length < 12) return null;

    bool at(int i, List<int> magic) {
      if (bytes.length < i + magic.length) return false;
      for (var k = 0; k < magic.length; k++) {
        if (bytes[i + k] != magic[k]) return false;
      }
      return true;
    }

    // MP4 / MOV: check ftyp atom at offset 4
    if (at(4, [0x66, 0x74, 0x79, 0x70])) {
      // Major brand at offset 8: 'qt  ' is QuickTime MOV
      if (at(8, [0x71, 0x74, 0x20, 0x20])) return VideoFormat.mov;
      return VideoFormat.mp4;
    }
    // moov or mdat at offset 4 (legacy or raw MP4)
    if (at(4, [0x6D, 0x6F, 0x6F, 0x76]) || at(4, [0x6D, 0x64, 0x61, 0x74])) {
      return VideoFormat.mp4;
    }

    // Matroska / WebM EBML header (1A 45 DF A3)
    if (at(0, [0x1A, 0x45, 0xDF, 0xA3])) {
      // Check for 'webm' doctype string in the first 64 bytes
      final limit = bytes.length < 64 ? bytes.length : 64;
      for (var i = 4; i <= limit - 4; i++) {
        if (bytes[i] == 0x77 && bytes[i + 1] == 0x65 && bytes[i + 2] == 0x62 && bytes[i + 3] == 0x6D) {
          return VideoFormat.webm;
        }
      }
      return VideoFormat.mkv;
    }

    // AVI: starts with RIFF, bytes 8..11 are 'AVI '
    if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x41, 0x56, 0x49, 0x20])) {
      return VideoFormat.avi;
    }

    return null;
  }

  /// Decode [bytes] (MP4, WebM, MKV, MOV, AVI).
  /// Probes video metadata (dimensions, duration, framerate).
  /// An unknown or broken format is a [ContentException].
  static Future<Video> decode(List<int> bytes) async {
    if (bytes.length < 8) {
      throw const ContentException('unknown video format: input too short');
    }

    final raw = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final ffmpeg = await _ffmpegExecutable();

    final tempDir = await io.Directory.systemTemp.createTemp('dart_toolkit_video_probe_');
    try {
      final ext = (sniff(raw) ?? VideoFormat.mp4).name;
      final inPath = p.join(tempDir.path, 'input.$ext');
      await io.File(inPath).writeAsBytes(raw);

      // Run ffmpeg with null sink to inspect streams
      final result = await io.Process.run(ffmpeg, [
        '-hide_banner',
        '-i',
        inPath,
        '-t',
        '0.001',
        '-f',
        'null',
        '-',
      ]);

      final stderrText = result.stderr.toString();
      final info = _parseVideoInfo(stderrText);
      if (info == null) {
        throw ContentException('unknown video format or no video stream found: $stderrText');
      }

      return Video._(raw, info.width, info.height, info.duration, info.fps);
    } on FormatException {
      rethrow;
    } on Exception catch (e) {
      throw ContentException('failed to probe video: $e');
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Width in pixels.
  int width() => _width;

  /// Height in pixels.
  int height() => _height;

  /// Duration of the video.
  Duration duration() => _duration;

  /// Video frame rate (frames per second).
  double fps() => _fps;

  /// A [Reader] of the encoded / compressed video, compressed when read (lazily:
  /// nothing runs until the reader is read or stored).
  /// Store it with `> Fs.file(…)`, hash it, or upload it.
  ///
  /// [quality] (1–100, default: 80) controls the compression level, mapped to CRF
  /// (higher quality produces higher bitrate / larger file size; lower quality compresses more aggressively).
  /// Optional [width] and [height] can scale the resolution while preserving aspect ratio.
  /// A bad quality or non-positive size throws [ArgumentError] here, not when the reader is read.
  Reader encode(VideoFormat format, {int quality = 80, int? width, int? height}) {
    _checkEncode(format, quality, width: width, height: height);
    return _Encoded(this, format, quality: quality, width: width, height: height);
  }
}

/// Bytes → a video value.
extension ReaderVideo on Reader {
  /// Decode the video stream.
  Future<Video> video() async => Video.decode(await bytes());
}

/// Same, from an async reader.
extension ReaderFutureVideo on Future<Reader> {
  /// Decode the video stream.
  Future<Video> video() async => (await this).video();
}

/// Future mirrors (rule 4). The extension name is import-only; never reference it.
extension VideoFuture on Future<Video> {
  Future<int> width() async => (await this).width();
  Future<int> height() async => (await this).height();
  Future<Duration> duration() async => (await this).duration();
  Future<double> fps() async => (await this).fps();

  /// Mirror of [Video.encode].
  Reader encode(VideoFormat format, {int quality = 80, int? width, int? height}) {
    _checkEncode(format, quality, width: width, height: height);
    return _FutureEncoded(this, format, quality: quality, width: width, height: height);
  }
}

void _checkEncode(VideoFormat format, int quality, {int? width, int? height}) {
  if (quality < 1 || quality > 100) {
    throw ArgumentError.value(quality, 'quality', 'must be 1..100');
  }
  if ((width != null && width < 1) || (height != null && height < 1)) {
    throw ArgumentError.value(width ?? height, width != null ? 'width' : 'height', 'must be >= 1');
  }
}

final class _Encoded with Reader {
  _Encoded(this._video, this._format, {required this.quality, this.width, this.height});

  final Video _video;
  final VideoFormat _format;
  final int quality;
  final int? width;
  final int? height;

  @override
  Stream<List<int>> stream() =>
      _compressStream(_video._bytes, _format, quality: quality, width: width, height: height);
}

final class _FutureEncoded with Reader {
  _FutureEncoded(this._future, this._format, {required this.quality, this.width, this.height});

  final Future<Video> _future;
  final VideoFormat _format;
  final int quality;
  final int? width;
  final int? height;

  @override
  Stream<List<int>> stream() async* {
    final video = await _future;
    yield* _compressStream(video._bytes, _format, quality: quality, width: width, height: height);
  }
}

class _VideoInfo {
  _VideoInfo({
    required this.width,
    required this.height,
    required this.duration,
    required this.fps,
  });

  final int width;
  final int height;
  final Duration duration;
  final double fps;
}

_VideoInfo? _parseVideoInfo(String stderr) {
  final streamMatch = RegExp(r'Stream #\d+:\d+.*?: Video:.*').firstMatch(stderr);
  if (streamMatch == null) return null;
  final streamLine = streamMatch.group(0)!;

  final dimMatch = RegExp(r'\b(\d{2,5})x(\d{2,5})\b').firstMatch(streamLine);
  if (dimMatch == null) return null;
  final width = int.parse(dimMatch.group(1)!);
  final height = int.parse(dimMatch.group(2)!);

  final fpsMatch =
      RegExp(r'(\d+(?:\.\d+)?)\s*fps').firstMatch(streamLine) ?? RegExp(r'(\d+(?:\.\d+)?)\s*tbr').firstMatch(streamLine);
  final fps = fpsMatch != null ? double.parse(fpsMatch.group(1)!) : 30.0;

  final durationMatch = RegExp(r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)').firstMatch(stderr);
  Duration duration = Duration.zero;
  if (durationMatch != null) {
    final h = int.parse(durationMatch.group(1)!);
    final m = int.parse(durationMatch.group(2)!);
    final s = double.parse(durationMatch.group(3)!);
    final micros = (s * 1000000).round();
    duration = Duration(hours: h, minutes: m, microseconds: micros);
  }

  return _VideoInfo(
    width: width,
    height: height,
    duration: duration,
    fps: fps,
  );
}

Stream<List<int>> _compressStream(
  Uint8List inputBytes,
  VideoFormat format, {
  required int quality,
  int? width,
  int? height,
}) async* {
  final ffmpeg = await _ffmpegExecutable();
  final tempDir = await io.Directory.systemTemp.createTemp('dart_toolkit_video_enc_');
  try {
    final inExt = (Video.sniff(inputBytes) ?? VideoFormat.mp4).name;
    final inPath = p.join(tempDir.path, 'input.$inExt');
    final outPath = p.join(tempDir.path, 'output.${format.name}');

    await io.File(inPath).writeAsBytes(inputBytes);

    final args = <String>[
      '-hide_banner',
      '-y',
      '-i',
      inPath,
    ];

    if (width != null || height != null) {
      if (width != null && height != null) {
        final w = (width ~/ 2) * 2;
        final h = (height ~/ 2) * 2;
        args.addAll(['-vf', 'scale=$w:$h']);
      } else if (width != null) {
        final w = (width ~/ 2) * 2;
        args.addAll(['-vf', 'scale=$w:-2']);
      } else {
        final h = (height! ~/ 2) * 2;
        args.addAll(['-vf', 'scale=-2:$h']);
      }
    }

    switch (format) {
      case VideoFormat.mp4:
      case VideoFormat.mov:
      case VideoFormat.mkv:
        // quality 1..100 -> CRF 51..18
        final crf = (51 - ((quality - 1) * 33 / 99)).round();
        args.addAll([
          '-c:v',
          'libx264',
          '-crf',
          '$crf',
          '-preset',
          'medium',
          '-c:a',
          'aac',
          '-b:a',
          '128k',
        ]);
        if (format == VideoFormat.mp4 || format == VideoFormat.mov) {
          args.addAll(['-movflags', '+faststart']);
        }
        break;

      case VideoFormat.webm:
        // quality 1..100 -> CRF 63..15
        final crf = (63 - ((quality - 1) * 48 / 99)).round();
        args.addAll([
          '-c:v',
          'libvpx-vp9',
          '-crf',
          '$crf',
          '-b:v',
          '0',
          '-c:a',
          'libopus',
          '-b:a',
          '128k',
        ]);
        break;

      case VideoFormat.avi:
        // quality 1..100 -> qscale 31..1
        final qscale = (31 - ((quality - 1) * 30 / 99)).round();
        args.addAll([
          '-c:v',
          'mpeg4',
          '-qscale:v',
          '$qscale',
          '-c:a',
          'libmp3lame',
          '-b:a',
          '128k',
        ]);
        break;
    }

    args.add(outPath);

    final proc = await io.Process.run(ffmpeg, args);
    if (proc.exitCode != 0) {
      throw ContentException('video encoding failed (exit ${proc.exitCode}): ${proc.stderr}');
    }

    final outFile = io.File(outPath);
    if (!await outFile.exists()) {
      throw const ContentException('video encoding failed: output file not created');
    }

    await for (final chunk in outFile.openRead()) {
      yield chunk;
    }
  } finally {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}

String? _cachedFfmpegPath;

Future<String> _ffmpegExecutable() async {
  if (_cachedFfmpegPath != null && io.File(_cachedFfmpegPath!).existsSync()) {
    return _cachedFfmpegPath!;
  }

  // 1. Check system PATH via Shell.which
  final onPath = await Shell.which('ffmpeg');
  if (onPath != null) {
    _cachedFfmpegPath = onPath;
    return onPath;
  }

  // 2. Check user cache directory
  final cacheDir = p.join(cache.userCacheDir(), 'dart_toolkit', 'ffmpeg');
  final exeName = io.Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
  final cachedExe = p.join(cacheDir, exeName);
  if (await io.File(cachedExe).exists()) {
    _cachedFfmpegPath = cachedExe;
    return cachedExe;
  }

  // 3. Download portable binary into user cache
  await _downloadFfmpeg(cacheDir, cachedExe);
  _cachedFfmpegPath = cachedExe;
  return cachedExe;
}

Future<void> _downloadFfmpeg(String cacheDir, String targetExe) async {
  final url = _platformFfmpegUrl();
  if (url == null) {
    throw StateError(
      'No prebuilt FFmpeg available for this platform (${io.Platform.operatingSystem} ${io.Platform.version}). '
      'Please install ffmpeg on PATH.',
    );
  }

  await io.Directory(cacheDir).create(recursive: true);
  final http = Http.client();
  try {
    await (http.get(url) > Archive.unarchive(cacheDir));
  } finally {
    http.close();
  }

  if (!io.Platform.isWindows) {
    try {
      await posix.chmod(targetExe, 0x1ed);
    } catch (_) {
      try {
        await io.Process.run('chmod', ['+x', targetExe]);
      } catch (_) {}
    }
  }

  if (!await io.File(targetExe).exists()) {
    throw ContentException('Failed to extract FFmpeg executable to $targetExe');
  }
}

String? _platformFfmpegUrl() {
  if (io.Platform.isWindows) {
    return 'https://github.com/ffbinaries/ffbinaries-prebuilt/releases/download/v6.1/ffmpeg-6.1-win-64.zip';
  } else if (io.Platform.isMacOS) {
    return 'https://github.com/ffbinaries/ffbinaries-prebuilt/releases/download/v6.1/ffmpeg-6.1-macos-64.zip';
  } else if (io.Platform.isLinux) {
    final isArm = io.Platform.version.contains('arm');
    if (isArm) {
      return 'https://github.com/ffbinaries/ffbinaries-prebuilt/releases/download/v6.1/ffmpeg-6.1-linux-arm-64.zip';
    }
    return 'https://github.com/ffbinaries/ffbinaries-prebuilt/releases/download/v6.1/ffmpeg-6.1-linux-64.zip';
  }
  return null;
}

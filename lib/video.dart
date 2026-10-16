/// Probe, convert, trim, compress and grab frames from video and audio.
/// Facade over ffmpeg (downloaded once on first use when PATH has no
/// fitting copy).
///
/// ```dart
/// final clip = await Fs.file('in.mkv').video();                 // probes; the file is read in place
/// await (clip.encode(.mp4) > Fs.file('out.mp4'));                // remux: copies the streams, seconds
/// await (clip.encode(.mp4, quality: 70, height: 720, start: 10.seconds) & Console.bar('encode')
///     > Fs.file('small.mp4'));                                     // encode  1:12/4:30  3.4×
/// await (clip.frame(at: 5.seconds).encode(.jpg) > Fs.file('thumb.jpg'));
/// final saved = await (Video.compress('in.mp4', quality: 70) & Console.bar('compress'));  // Compressed or Kept
/// final live = await Video.open('https://…/master.m3u8');        // HLS/DASH, or split video + audio
/// ```
///
/// Public surface is exactly: [Video], [VideoFormat], [VideoCodec], and
/// `compress`'s [Compression] ([Compressed] or [Kept] with a [KeptReason]).
/// - `Reader.video()` reads any reader (a file in place, bytes or a stream
///   spooled once), `Video.open()` a URL (HLS/DASH manifests, a separate `audio:`).
/// - `Video.sniff()` names the format from the header bytes.
/// - `Video.compress()` re-encodes a file in its own container, replacing
///   it only when smaller (a [Task]: watch it with `&`).
/// - [Video] supports `width` `height` `duration` `fps` `format` `codec`
///   `audioCodec` `bitrate` `encode` (a reader that reports its encode to a
///   probe) `frame`.
/// Everything else is private.
library;

import 'dart:async';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

import 'image.dart';
import 'src/format.dart' show Unit;
import 'src/media.dart' as media;
import 'src/media_proxy.dart' as proxy;
import 'src/progress.dart' show Run, task, working;

export 'core.dart';
export 'src/media.dart' show Compression, Compressed, Kept, KeptReason;

/// Containers [Video.encode] writes and [Video.sniff] names; `.name` is the
/// extension. [m4a], [mp3] and [opus] keep the audio only. [avi] is read,
/// never written (its codecs lose to mp4 at every size).
enum VideoFormat { mp4, webm, mkv, mov, avi, m4a, mp3, opus }

/// Video codecs [Video.encode] writes: [h264] plays everywhere, [h265] and
/// [av1] are about half the size at the same quality, [vp9] is WebM's.
enum VideoCodec { h264, h265, av1, vp9 }

/// A video (or audio) source and what ffprobe says about it.
final class Video {
  Video._(this._inputs, this._headers, this._info, [this._temp]);

  /// Inputs in order: the source, then a separate audio source.
  final List<String> _inputs;

  /// HTTP headers for a URL source, added by [proxy.throughProxy] for its
  /// own origins only (never in argv).
  final Map<String, String>? _headers;

  final _Info _info;

  /// The spooled source, when this video owns one: held so it is deleted
  /// with the video, never before.
  // ignore: unused_field
  final media.Temp? _temp;

  /// The format named by the magic bytes, or null when they are not a
  /// supported video. HEIC/AVIF photos share MP4's box and are not video.
  static VideoFormat? sniff(List<int> bytes) {
    if (bytes.length < 12) return null;

    bool at(int i, List<int> magic) {
      if (bytes.length < i + magic.length) return false;
      for (var k = 0; k < magic.length; k++) {
        if (bytes[i + k] != magic[k]) return false;
      }
      return true;
    }

    if (at(4, [0x66, 0x74, 0x79, 0x70])) {
      if (media.heif(bytes) != null) return null;
      if (at(8, [0x71, 0x74, 0x20, 0x20])) return VideoFormat.mov; // 'qt  '
      if (at(8, [0x4D, 0x34, 0x41, 0x20])) return VideoFormat.m4a; // 'M4A '
      return VideoFormat.mp4;
    }
    if (at(4, [0x6D, 0x6F, 0x6F, 0x76]) || at(4, [0x6D, 0x64, 0x61, 0x74])) return VideoFormat.mp4; // moov / mdat
    if (at(0, [0x1A, 0x45, 0xDF, 0xA3])) {
      // EBML: the doctype string tells WebM from Matroska.
      final limit = bytes.length < 64 ? bytes.length : 64;
      for (var i = 4; i <= limit - 4; i++) {
        if (bytes[i] == 0x77 && bytes[i + 1] == 0x65 && bytes[i + 2] == 0x62 && bytes[i + 3] == 0x6D) {
          return VideoFormat.webm;
        }
      }
      return VideoFormat.mkv;
    }
    if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x41, 0x56, 0x49, 0x20])) return VideoFormat.avi;
    if (at(0, [0x49, 0x44, 0x33]) || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0)) return VideoFormat.mp3;
    if (at(0, [0x4F, 0x67, 0x67, 0x53])) return VideoFormat.opus; // Ogg
    return null;
  }

  /// Probe [source], an http(s) URL ffmpeg reads itself (`.m3u8`/`.mpd`
  /// manifests included, which have no bytes to read); a file is a reading:
  /// `Fs.file(path).video()`, and a path or any other scheme here is an
  /// [ArgumentError]. [audio] (an http(s) URL too) adds a separate audio
  /// source (DASH serves them apart), and [headers]
  /// (cookies, referer, a token) go with ffmpeg's requests to the source's
  /// own origins only, through a loopback proxy: never in the process
  /// list, never to a CDN or redirect on another host.
  static Future<Video> open(String source, {String? audio, Map<String, String>? headers}) {
    for (final url in [source, ?audio]) {
      if (!_url.hasMatch(url)) {
        throw ArgumentError.value(url, url == source ? 'source' : 'audio', 'an http(s) URL; read a file with Fs.file(path).video()');
      }
    }
    return _open(source, audio: audio, headers: headers);
  }

  static final _url = RegExp(r'^https?://', caseSensitive: false);

  /// [source] (an http(s) URL, else a local path) as ffmpeg reads it.
  static Future<Video> _open(String source, {String? audio, Map<String, String>? headers, media.Temp? temp}) async {
    final inputs = [for (final i in [source, ?audio]) _url.hasMatch(i) ? i : media.file(i)];
    final infos = await proxy.throughProxy(
      inputs,
      headers,
      (mapped) async => [for (final i in mapped) _Info.of(await media.ffprobe(i))],
    );
    var info = infos.length == 1 ? infos.first : infos.first.withAudio(infos.last);
    if (info.width == null && info.audio == null) throw const ContentException('no video or audio stream found');
    if (!_url.hasMatch(source)) info = info.withFormat(sniff(await _head(source)));
    return Video._(inputs, headers, info, temp);
  }

  /// Re-encode the video at [path] in its own container (h264 for MP4/MOV/
  /// MKV, VP9 for WebM; another codec is `encode(codec:)`) and replace it, atomically, only
  /// when at least 5% smaller. Audio is copied, not re-encoded. Returns
  /// [Compressed] with the sizes before and after, or [Kept] with the
  /// reason: not a video, AVI or audio only, or no smaller. A [Task]: a
  /// probe shows the encode in media time (`1:12/4:30  3.4×`).
  static Task<Compression> compress(String path, {int quality = 70}) {
    media.checkQuality(quality);
    return task((run) => _compress(path, quality, run));
  }

  static Future<Compression> _compress(String path, int quality, Run run) async {
    final head = await _head(path);
    final format = sniff(head);
    if (format == null) return const Kept(KeptReason.unknown);
    if (const {VideoFormat.avi, VideoFormat.m4a, VideoFormat.mp3, VideoFormat.opus}.contains(format)) {
      return const Kept(KeptReason.lossy);
    }
    final video = await _open(path);
    if (video._info.width == null) return const Kept(KeptReason.lossy);
    final tmp = p.join(p.dirname(path), '.${p.basename(path)}.compress');
    return media.deletedOnExit(tmp, () async {
      try {
        await video._encodeTo(tmp, format, quality: quality, onProgress: _reporter(run));
      } catch (_) {
        await io.File(tmp).delete().catchError((_) => io.File(tmp));
        rethrow;
      }
      return media.replaceIfSmaller(path, tmp, by: 0.05);
    });
  }

  /// Width in pixels as displayed (rotation applied); null for audio only.
  int? width() => _info.width;

  /// Height in pixels as displayed; null for audio only.
  int? height() => _info.height;

  /// Length; [Duration.zero] when unknown (a live stream).
  Duration duration() => _info.duration;

  /// Frames per second; 0 for audio only.
  double fps() => _info.fps;

  /// The video codec as ffprobe names it (`h264`, `hevc`, `av1`, `vp9`), or
  /// null for audio only.
  String? codec() => _info.codec;

  /// The audio codec (`aac`, `opus`, `mp3`), or null when there is no audio.
  String? audioCodec() => _info.audio;

  /// The container it was read as (a file's magic bytes, else ffprobe's
  /// name for a URL), or null when none of [VideoFormat] (a live HLS stream).
  VideoFormat? format() => _info.format;

  /// Overall bits per second, or null when unknown.
  int? bitrate() => _info.bitrate;

  /// A [Reader] of the converted video, made when read (lazily). Store it
  /// with `> Fs.file(…)`.
  ///
  /// With no [quality], [width], [height] or [codec] the streams are
  /// **copied** into the new container when it can hold them (seconds,
  /// not minutes, and no loss); [start]/[end] then cut at keyframes.
  /// Otherwise the video is encoded: [quality] 1–100 (default 80) maps to
  /// the codec's CRF, [width]/[height] scale keeping the aspect ratio when
  /// one is given, [codec] picks the encoder (default: h264, VP9 for WebM).
  /// Audio is copied when the container takes it, else AAC (Opus for WebM).
  /// A probe on the reader (`encode(…) & Console.bar('encode')`) shows the
  /// encode in media time, not the copy that follows it.
  ///
  /// A bad quality or size, or [VideoFormat.avi], is an [ArgumentError]
  /// here, not when the reader is read.
  Reader encode(
    VideoFormat format, {
    int? quality,
    int? width,
    int? height,
    VideoCodec? codec,
    Duration? start,
    Duration? end,
  }) {
    _checkEncode(format, quality, width, height, codec);
    return _Encoded(
      () async => this,
      format,
      quality: quality,
      width: width,
      height: height,
      codec: codec,
      start: start,
      end: end,
    );
  }

  /// The frame shown at [at] (default: the first) as an [Image].
  Future<Image> frame({Duration at = Duration.zero}) async {
    if (_info.width == null) throw StateError('audio only: no frames');
    final out = await media.tempOut('png');
    await proxy.throughProxy(
      _inputs,
      _headers,
      (inputs) => media.ffmpeg([
        if (at > Duration.zero) ...['-ss', _secs(at)],
        '-i',
        inputs.first,
        '-frames:v',
        '1',
        '-y',
        out,
      ]),
    );
    try {
      return await Reader.of(await io.File(out).readAsBytes()).image();
    } finally {
      await io.File(out).delete().catchError((_) => io.File(out));
    }
  }

  Future<void> _encodeTo(
    String out,
    VideoFormat format, {
    int? quality,
    int? width,
    int? height,
    VideoCodec? codec,
    Duration? start,
    Duration? end,
    void Function(int done, int? total)? onProgress,
  }) async {
    await proxy.throughProxy(
      _inputs,
      _headers,
      (inputs) => _encodeFrom(
        inputs,
        out,
        format,
        quality: quality,
        width: width,
        height: height,
        codec: codec,
        start: start,
        end: end,
        onProgress: onProgress,
      ),
    );
  }

  Future<void> _encodeFrom(
    List<String> inputs,
    String out,
    VideoFormat format, {
    int? quality,
    int? width,
    int? height,
    VideoCodec? codec,
    Duration? start,
    Duration? end,
    void Function(int done, int? total)? onProgress,
  }) async {
    final info = _info;
    final audioOnly = const {VideoFormat.m4a, VideoFormat.mp3, VideoFormat.opus}.contains(format);
    final encodeVideo = !audioOnly && (quality != null || width != null || height != null || codec != null);
    final vcodec = codec ?? (format == VideoFormat.webm ? VideoCodec.vp9 : VideoCodec.h264);
    final q = quality ?? 80;
    final args = <String>[
      for (final input in inputs) ...[
        if (start != null) ...['-ss', _secs(start)],
        '-i',
        input,
      ],
      if (end != null) ...['-t', _secs(end - (start ?? Duration.zero))],
      if (!audioOnly && info.width != null) ...['-map', '0:v:0'],
      if (info.audio != null) ...['-map', inputs.length > 1 ? '1:a:0' : '0:a:0?'],
      if (audioOnly) '-vn',
    ];
    final needs = <String>{};
    if (!audioOnly && info.width != null) {
      if (!encodeVideo && _fits(format, info.codec)) {
        args.addAll(['-c:v', 'copy']);
      } else {
        if (width != null || height != null) {
          args.addAll(['-vf', 'scale=${width == null ? -2 : width ~/ 2 * 2}:${height == null ? -2 : height ~/ 2 * 2}']);
        }
        final (name, crf) = switch (vcodec) {
          VideoCodec.h264 => ('libx264', 51 - (q - 1) * 33 / 99),
          VideoCodec.h265 => ('libx265', 51 - (q - 1) * 31 / 99),
          VideoCodec.av1 => ('libsvtav1', 63 - (q - 1) * 43 / 99),
          VideoCodec.vp9 => ('libvpx-vp9', 63 - (q - 1) * 48 / 99),
        };
        needs.add(name);
        args.addAll(['-c:v', name, '-crf', '${crf.round()}', '-pix_fmt', 'yuv420p']);
        if (vcodec == VideoCodec.h264 || vcodec == VideoCodec.h265) args.addAll(['-preset', 'medium']);
        if (vcodec == VideoCodec.h265 && format != VideoFormat.mkv) args.addAll(['-tag:v', 'hvc1']);
        if (vcodec == VideoCodec.av1) args.addAll(['-preset', '8']);
        if (vcodec == VideoCodec.vp9) args.addAll(['-b:v', '0', '-row-mt', '1']);
      }
    }
    if (info.audio != null) {
      if (_fitsAudio(format, info.audio)) {
        args.addAll(['-c:a', 'copy']);
      } else {
        final (name, rate) = switch (format) {
          VideoFormat.webm || VideoFormat.opus => ('libopus', '96k'),
          VideoFormat.mp3 => ('libmp3lame', '160k'),
          _ => ('aac', '128k'),
        };
        if (name != 'aac') needs.add(name);
        args.addAll(['-c:a', name, '-b:a', rate]);
      }
    }
    if (format == VideoFormat.mp4 || format == VideoFormat.mov || format == VideoFormat.m4a) {
      args.addAll(['-movflags', '+faststart']);
    }
    final total = info.duration > Duration.zero
        ? ((end ?? info.duration) - (start ?? Duration.zero)).inMicroseconds
        : null;
    await media.ffmpeg([...args, '-f', _muxer(format), '-y', out], needs: needs, total: total, onProgress: onProgress);
  }
}

String _secs(Duration d) => (d.inMicroseconds / 1e6).toStringAsFixed(3);

String _muxer(VideoFormat f) => switch (f) {
  VideoFormat.mp4 => 'mp4',
  VideoFormat.webm => 'webm',
  VideoFormat.mkv => 'matroska',
  VideoFormat.mov => 'mov',
  VideoFormat.m4a => 'ipod',
  VideoFormat.mp3 => 'mp3',
  VideoFormat.opus => 'opus',
  VideoFormat.avi => throw ArgumentError.value(f, 'format', 'avi is read, not written: use mp4'),
};

/// Whether [format] holds video in [codec] as is.
bool _fits(VideoFormat format, String? codec) => switch (format) {
  VideoFormat.mkv => true,
  VideoFormat.webm => const {'vp8', 'vp9', 'av1'}.contains(codec),
  VideoFormat.mp4 || VideoFormat.mov => const {'h264', 'hevc', 'av1', 'vp9', 'mpeg4'}.contains(codec),
  _ => false,
};

/// Whether [format] holds audio in [codec] as is.
bool _fitsAudio(VideoFormat format, String? codec) => switch (format) {
  VideoFormat.mkv => true,
  VideoFormat.webm ||
  VideoFormat.opus => const {'opus', 'vorbis'}.contains(codec) && (format == VideoFormat.webm || codec == 'opus'),
  VideoFormat.mp4 || VideoFormat.mov => const {'aac', 'mp3', 'alac', 'ac3', 'eac3', 'opus'}.contains(codec),
  VideoFormat.m4a => const {'aac', 'alac'}.contains(codec),
  VideoFormat.mp3 => codec == 'mp3',
  VideoFormat.avi => false,
};

/// The facts [Video] reports, from ffprobe's JSON.
final class _Info {
  _Info(this.width, this.height, this.duration, this.fps, this.codec, this.audio, this.bitrate, [this.format]);

  factory _Info.of(Map<String, Object?> json) {
    final streams = ((json['streams'] as List?) ?? const []).cast<Map<String, Object?>>();
    final format = (json['format'] as Map?) ?? const {};
    final v = streams
        .where((s) => s['codec_type'] == 'video' && (s['disposition'] as Map?)?['attached_pic'] != 1)
        .firstOrNull;
    final a = streams.where((s) => s['codec_type'] == 'audio').firstOrNull;
    int? w = v?['width'] as int?, h = v?['height'] as int?;
    final rotation = ((v?['side_data_list'] as List?) ?? const [])
        .cast<Map<String, Object?>>()
        .map((d) => d['rotation'])
        .whereType<num>()
        .firstOrNull;
    if (rotation != null && rotation.abs() % 180 == 90) (w, h) = (h, w);
    final secs = double.tryParse('${format['duration'] ?? v?['duration'] ?? a?['duration'] ?? ''}');
    return _Info(
      w,
      h,
      secs == null ? Duration.zero : Duration(microseconds: (secs * 1e6).round()),
      _rate('${v?['avg_frame_rate'] ?? ''}') ?? _rate('${v?['r_frame_rate'] ?? ''}') ?? 0,
      v?['codec_name'] as String?,
      a?['codec_name'] as String?,
      int.tryParse('${format['bit_rate'] ?? ''}'),
      _container('${format['format_name'] ?? ''}'),
    );
  }

  /// ffprobe's demuxer names → ours; a file's magic bytes refine this.
  static VideoFormat? _container(String name) {
    final names = name.split(',');
    if (names.contains('mp4')) return VideoFormat.mp4;
    if (names.contains('matroska')) return VideoFormat.mkv;
    if (names.contains('avi')) return VideoFormat.avi;
    if (names.contains('mp3')) return VideoFormat.mp3;
    if (names.contains('ogg')) return VideoFormat.opus;
    return null;
  }

  final int? width;
  final int? height;
  final Duration duration;
  final double fps;
  final String? codec;
  final String? audio;
  final int? bitrate;
  final VideoFormat? format;

  _Info withAudio(_Info other) => _Info(width, height, duration, fps, codec, other.audio, bitrate, format);

  _Info withFormat(VideoFormat? sniffed) =>
      _Info(width, height, duration, fps, codec, audio, bitrate, sniffed ?? format);

  static double? _rate(String s) {
    final parts = s.split('/');
    if (parts.length != 2) return double.tryParse(s);
    final n = double.tryParse(parts[0]), d = double.tryParse(parts[1]);
    return n == null || d == null || d == 0 ? null : n / d;
  }
}

Future<List<int>> _head(String path) async {
  final f = await io.File(path).open();
  try {
    return await f.read(64);
  } finally {
    await f.close();
  }
}


void _checkEncode(VideoFormat format, int? quality, int? width, int? height, VideoCodec? codec) {
  if (quality != null) media.checkQuality(quality);
  if ((width != null && width < 1) || (height != null && height < 1)) {
    throw ArgumentError.value(width ?? height, width != null ? 'width' : 'height', 'must be >= 1');
  }
  if (format == VideoFormat.avi) throw ArgumentError.value(format, 'format', 'avi is read, not written: use mp4');
  if (codec != null) {
    final ok = switch (format) {
      VideoFormat.webm => codec == VideoCodec.vp9 || codec == VideoCodec.av1,
      VideoFormat.mp4 || VideoFormat.mov || VideoFormat.mkv => true,
      _ => false,
    };
    if (!ok) throw ArgumentError.value(codec, 'codec', '${format.name} cannot hold ${codec.name}');
  }
}

/// Bytes → a video value.
extension ReaderVideo on Reader {
  /// Probe the video: a file is read in place, any other stream is written
  /// to a temp file once (never held in memory).
  Future<Video> video() async {
    final path = origin().path();
    if (path != null && await io.File(path).exists()) return Video._open(path);
    final first = <int>[];
    final spooled = await media.spool(
      stream().map((chunk) {
        if (first.length < 64) first.addAll(chunk.take(64 - first.length));
        return chunk;
      }),
    );
    final format = Video.sniff(first);
    if (format == null) {
      await io.File(spooled).delete().catchError((_) => io.File(spooled));
      throw const ContentException('unknown video format');
    }
    return Video._open(spooled, temp: media.Temp(spooled));
  }
}

/// Same, from an async reader.
extension ReaderFutureVideo on Future<Reader> {
  /// Probe the video (see [ReaderVideo.video]).
  Future<Video> video() async => (await this).video();
}

/// Future mirrors (rule 4). The extension name is import-only; never reference it.
extension VideoFuture on Future<Video> {
  Future<int?> width() async => (await this).width();
  Future<int?> height() async => (await this).height();
  Future<Duration> duration() async => (await this).duration();
  Future<double> fps() async => (await this).fps();
  Future<String?> codec() async => (await this).codec();
  Future<String?> audioCodec() async => (await this).audioCodec();
  Future<VideoFormat?> format() async => (await this).format();
  Future<int?> bitrate() async => (await this).bitrate();
  Future<Image> frame({Duration at = Duration.zero}) async => (await this).frame(at: at);

  /// Mirror of [Video.encode].
  Reader encode(
    VideoFormat format, {
    int? quality,
    int? width,
    int? height,
    VideoCodec? codec,
    Duration? start,
    Duration? end,
  }) {
    _checkEncode(format, quality, width, height, codec);
    return _Encoded(
      () => this,
      format,
      quality: quality,
      width: width,
      height: height,
      codec: codec,
      start: start,
      end: end,
    );
  }
}

final class _Encoded with Reader {
  _Encoded(
    this._video,
    this._format, {
    this.quality,
    this.width,
    this.height,
    this.codec,
    this.start,
    this.end,
  }) {
    working[this] = _watched;
  }

  final Future<Video> Function() _video;
  final VideoFormat _format;
  final int? quality;
  final int? width;
  final int? height;
  final VideoCodec? codec;
  final Duration? start;
  final Duration? end;

  @override
  Stream<List<int>> stream() => _stream(null);

  /// Watched: the probe hears the encode, in media time.
  Stream<List<int>> _watched(Run run) => _stream(_reporter(run));

  Stream<List<int>> _stream(void Function(int done, int? total)? onProgress) async* {
    final video = await _video();
    // mp4/mov need a seekable output (faststart), so encode to a temp file.
    final out = await media.tempOut(_format.name);
    try {
      await video._encodeTo(
        out,
        _format,
        quality: quality,
        width: width,
        height: height,
        codec: codec,
        start: start,
        end: end,
        onProgress: onProgress,
      );
    } catch (_) {
      await io.File(out).delete().catchError((_) => io.File(out));
      rethrow;
    }
    yield* media.readAndDelete(out);
  }
}

/// [run]'s report for an encode's `(microseconds written, total)`, or null
/// when nothing watches it (no `-progress` pass then).
void Function(int done, int? total)? _reporter(Run run) =>
    run.watched ? (done, total) => run.report(done, total, Unit.time) : null;

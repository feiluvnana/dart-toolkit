// ffmpeg runs (and may be downloaded) here, so `-P quick` skips it.
@Tags(['media'])
library;

import 'dart:io' as io;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/src/media.dart' as media;
import 'package:dart_toolkit/src/media_proxy.dart' as proxy;
import 'package:dart_toolkit/utils.dart';
import 'package:dart_toolkit/video.dart';
import 'package:test/test.dart';

import 'support/child.dart';
import 'support/io.dart';
import 'support/poll.dart';

late io.Directory tmp;

/// [bytes] as a video, the way a script reads bytes.
Future<Video> _video(List<int> bytes) => Reader.of(bytes).video();
late String clip; // 640x360, 2 s, 30 fps, h264 + aac

/// A file ffmpeg makes from lavfi sources.
Future<String> make(String name, List<String> args) async {
  final out = '${tmp.path}/$name';
  await media.ffmpeg([...args, '-y', out]);
  return out;
}

void main() {
  setUpAll(() async {
    tmp = await io.Directory.systemTemp.createTemp('video_test_');
    clip = await make('clip.mp4', [
      '-f', 'lavfi', '-i', 'testsrc2=s=640x360:d=2:r=30', //
      '-f', 'lavfi', '-i', 'sine=d=2',
      '-c:v', 'libx264', '-c:a', 'aac', '-shortest',
    ]);
  });
  tearDownAll(() => tmp.delete(recursive: true));

  group('Video.sniff', () {
    test('names containers from their magic bytes', () {
      List<int> ftyp(String brand) => [0, 0, 0, 20, ...'ftyp'.codeUnits, ...brand.codeUnits, 0, 0, 0, 0];
      expect(Video.sniff(ftyp('isom')), VideoFormat.mp4);
      expect(Video.sniff(ftyp('qt  ')), VideoFormat.mov);
      expect(Video.sniff(ftyp('M4A ')), VideoFormat.m4a);
      expect(Video.sniff([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'AVI '.codeUnits]), VideoFormat.avi);
      expect(Video.sniff([0x1A, 0x45, 0xDF, 0xA3, 0, 0, ...'webm'.codeUnits, 0, 0]), VideoFormat.webm);
      expect(Video.sniff([0x1A, 0x45, 0xDF, 0xA3, 0, 0, ...'matroska'.codeUnits]), VideoFormat.mkv);
      expect(Video.sniff([...'ID3'.codeUnits, 4, 0, 0, 0, 0, 0, 0, 0, 0]), VideoFormat.mp3);
      expect(Video.sniff([...'OggS'.codeUnits, 0, 0, 0, 0, 0, 0, 0, 0]), VideoFormat.opus);
    });

    test('V1: HEIC and AVIF photos are not video', () {
      expect(Video.sniff([0, 0, 0, 20, ...'ftypheic'.codeUnits, 0, 0, 0, 0, ...'mif1'.codeUnits]), isNull);
      expect(Video.sniff([0, 0, 0, 20, ...'ftypavif'.codeUnits, 0, 0, 0, 0, ...'mif1'.codeUnits]), isNull);
    });
  });

  group('S4: open(headers:)', () {
    late io.HttpServer server;
    late String home, other;
    final seen = <String>[]; // "host path cookie"
    setUpAll(() async {
      await io.Directory('${tmp.path}/hls').create();
      await media.ffmpeg([
        '-f', 'lavfi', '-i', 'testsrc2=s=160x90:d=2:r=10', //
        '-c:v', 'libx264', '-hls_time', '1', '-hls_list_size', '0',
        '-f', 'hls', '-y', '${tmp.path}/hls/x.m3u8',
      ]);
      server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
      home = 'http://127.0.0.1:${server.port}';
      other = 'http://localhost:${server.port}';
      server.listen((r) async {
        final cookie = r.headers.value('cookie');
        seen.add('${r.headers.host} ${r.uri.path} $cookie');
        if (r.uri.path == '/go') {
          r.response.redirect(Uri.parse('$other/hls/x.m3u8'));
          return;
        }
        final f = io.File('${tmp.path}${r.uri.path}');
        if (r.headers.host == '127.0.0.1' && cookie != 'c=1' || !f.existsSync()) {
          r.response.statusCode = 403;
        } else {
          if (r.uri.path.endsWith('.m3u8')) r.response.headers.contentType = io.ContentType('application', 'vnd.apple.mpegurl');
          await r.response.addStream(f.openRead());
        }
        await r.response.close();
      });
    });
    tearDownAll(() => server.close(force: true));

    test('the headers reach the source origin: the manifest and every segment', () async {
      seen.clear();
      final v = await Video.open('$home/hls/x.m3u8', headers: {'cookie': 'c=1'});
      expect(v.width(), 160);
      await (v.encode(.mp4) > Fs.file('${tmp.path}/hls.mp4'));
      expect(seen.where((l) => l.contains('.ts')), isNotEmpty);
      expect(seen.where((l) => l.startsWith('127.0.0.1') && !l.endsWith(' c=1')), isEmpty, reason: '$seen');
    });

    test('a redirect to another host gets no headers', () async {
      seen.clear();
      await Video.open('$home/go', headers: {'cookie': 'c=1'});
      final elsewhere = seen.where((l) => l.startsWith('localhost'));
      expect(elsewhere, isNotEmpty);
      expect(elsewhere.where((l) => !l.endsWith(' null')), isEmpty, reason: '$seen');
    });

    test('a failure names the URL with its token masked', () async {
      await expectLater(
        Video.open('$home/missing.m3u8?token=SECRET', headers: {'cookie': 'c=1'}),
        throwsA(isA<ContentException>().having((e) => e.message, 'message', isNot(contains('SECRET')))),
      );
    });
  });

  test('S2: the header proxy answers only GET/HEAD on its own path token for Host 127.0.0.1:port', () async {
    final reached = <String>[];
    final (_, base) = await serve((r) {
      reached.add('${r.method} ${r.uri.path} ${r.headers.value('authorization')}');
      r.response.close();
    });
    await proxy.throughProxy(['$base/v.mp4'], {'authorization': 'Bearer s3cret'}, (inputs) async {
      final mapped = Uri.parse(inputs.single);
      final client = io.HttpClient();
      addTearDown(() => client.close(force: true));
      Future<int> ask(String method, Uri url, {String? host}) async {
        final req = await client.openUrl(method, url);
        if (host != null) req.headers.host = host;
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      }

      final guessed = mapped.replace(path: '/0/v.mp4');
      expect(await ask('GET', mapped), 200);
      expect(await ask('HEAD', mapped), 200);
      expect(await ask('DELETE', mapped), isNot(200));
      expect(await ask('GET', mapped, host: 'evil.example'), isNot(200));
      expect(await ask('GET', guessed), isNot(200));
    });
    expect(reached, ['GET /v.mp4 Bearer s3cret', 'HEAD /v.mp4 Bearer s3cret']);
  });

  test('a network failure is an IOException (retried by pool), a bad file a ContentException (B13)', () async {
    final closed = await io.ServerSocket.bind(io.InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    await expectLater(Video.open('http://127.0.0.1:$port/x.mp4'), throwsA(isA<io.IOException>()));
    final (_, base) = await serve((r) => r.response
      ..statusCode = 503
      ..close());
    await expectLater(Video.open('$base/x.mp4'), throwsA(isA<io.IOException>()));
    final (_, junk) = await serve((r) => r.response
      ..write('not a video')
      ..close());
    await expectLater(Video.open('$junk/x.mp4'), throwsA(isA<ContentException>()));
  });

  test('with headers:, an upstream failure surfaces as itself, naming the source (B20)', () async {
    final closed = await io.ServerSocket.bind(io.InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    await expectLater(
      Video.open('http://127.0.0.1:$port/x.m3u8', headers: {'cookie': 'c=1'}),
      throwsA(isA<io.SocketException>().having((e) => e.message, 'message', contains('127.0.0.1:$port/x.m3u8'))),
    );
  });

  group('probe', () {
    test('a file is probed in place', () async {
      final v = await Fs.file(clip).video();
      expect((v.width(), v.height(), v.codec(), v.audioCodec()), (640, 360, 'h264', 'aac'));
      expect(v.format(), VideoFormat.mp4);
      expect(v.fps(), closeTo(30, 0.01));
      expect(v.duration()!.inMilliseconds, closeTo(2000, 100));
      expect(v.bitrate(), greaterThan(0));
    });

    test('bytes and streams go through a temp file', () async {
      final bytes = await io.File(clip).readAsBytes();
      expect((await _video(bytes)).width(), 640);
      expect((await Mem.bytes(bytes).video()).height(), 360);
      expect(await Future<Reader>.value(Mem.bytes(bytes)).video().width(), 640);
    });

    test('unknown bytes are a ContentException', () async {
      await expectLater(_video(List.filled(64, 7)), throwsA(isA<ContentException>()));
      await expectLater(Mem.bytes(List.filled(64, 7)).video(), throwsA(isA<ContentException>()));
    });

    test('E9: audio only has a null fps, as it has a null width', () async {
      final audio = await make('probe_only.m4a', ['-i', clip, '-vn', '-c', 'copy']);
      final v = await Fs.file(audio).video();
      expect((v.width(), v.fps()), (null, null));
      expect(v.duration()!.inMilliseconds, closeTo(2000, 150));
    });

    test('a rotated video reports its displayed size', () async {
      final turned = await make('turned.mp4', ['-display_rotation', '90', '-i', clip, '-c', 'copy']);
      final v = await Fs.file(turned).video();
      expect((v.width(), v.height()), (360, 640));
    });

    /// A loopback server for the files in tmp, by name.
    Future<String> files() async {
      final (_, base) = await serve((r) async {
        await r.response.addStream(io.File('${tmp.path}${r.uri.path}').openRead());
        await r.response.close();
      });
      return base;
    }

    test('open takes http(s) URLs; a path is a reading instead', () async {
      expect(() => Video.open(clip), throwsArgumentError);
      final v = await Video.open('${await files()}/${clip.split('/').last}');
      expect((v.width(), v.format()), (640, VideoFormat.mp4));
    });

    test('S7: open refuses every other scheme ffmpeg would read (local files, raw sockets)', () {
      for (final url in [Uri.file(clip).toString(), 'tcp://127.0.0.1:9/', 'ftp://127.0.0.1/x.mp4', 'concat:$clip|$clip']) {
        expect(() => Video.open(url), throwsArgumentError, reason: url);
        expect(() => Video.open('http://127.0.0.1:9/x.mp4', audio: url), throwsArgumentError, reason: url);
      }
    });

    test('open joins a separate audio source (DASH)', () async {
      final base = await files();
      await make('v.mp4', ['-i', clip, '-an', '-c', 'copy', '-movflags', '+faststart']); // no Range here
      await make('a.m4a', ['-i', clip, '-vn', '-c', 'copy']);
      final (video, audio) = ('$base/v.mp4', '$base/a.m4a');
      expect((await Video.open(video)).audioCodec(), isNull);
      final joined = await Video.open(video, audio: audio);
      expect(joined.audioCodec(), 'aac');
      final out = '${tmp.path}/joined.mp4';
      await (joined.encode(VideoFormat.mp4) > Fs.file(out));
      final back = await Fs.file(out).video();
      expect((back.codec(), back.audioCodec()), ('h264', 'aac'));
    });
  });

  group('encode', () {
    test('no quality: streams are copied into the new container', () async {
      final out = '${tmp.path}/copy.mkv';
      await (Fs.file(clip).video().encode(VideoFormat.mkv) > Fs.file(out));
      final v = await Fs.file(out).video();
      expect((v.codec(), v.audioCodec(), v.width()), ('h264', 'aac', 640));
    });

    test('quality, scale, trim, and a probe that hears the encode in media time', () async {
      final seen = <(int, int?)>[];
      final out = '${tmp.path}/small.webm';
      await (Fs.file(clip).video().encode(VideoFormat.webm, quality: 40, height: 180, start: 500.milliseconds) &
              _Heard(seen) >
          Fs.file(out));
      final v = await Fs.file(out).video();
      expect((v.width(), v.height(), v.codec(), v.audioCodec()), (320, 180, 'vp9', 'opus'));
      expect(v.duration()!.inMilliseconds, closeTo(1500, 150));
      expect(seen.where((s) => s.$2 == 1500000), isNotEmpty);
      expect(seen.last, (1500000, 1500000), reason: 'the copy after the encode adds nothing');
    });

    test('codec: h265 in mp4', () async {
      final out = '${tmp.path}/h265.mp4';
      await (Fs.file(clip).video().encode(VideoFormat.mp4, codec: VideoCodec.h265, quality: 50) > Fs.file(out));
      expect(await Fs.file(out).video().codec(), 'hevc');
    });

    test('audio-only formats drop the picture', () async {
      for (final f in [VideoFormat.m4a, VideoFormat.mp3, VideoFormat.opus]) {
        final out = '${tmp.path}/sound.${f.name}';
        await (Fs.file(clip).video().encode(f) > Fs.file(out));
        final v = await Fs.file(out).video();
        expect(v.width(), isNull, reason: f.name);
        expect(v.audioCodec(), {VideoFormat.m4a: 'aac', VideoFormat.mp3: 'mp3', VideoFormat.opus: 'opus'}[f]);
      }
    });

    test('bad arguments are refused up front', () async {
      final v = await Fs.file(clip).video();
      expect(() => v.encode(VideoFormat.mp4, quality: 0), throwsArgumentError);
      expect(() => v.encode(VideoFormat.mp4, width: 0), throwsArgumentError);
      expect(() => v.encode(VideoFormat.avi), throwsArgumentError);
      expect(() => v.encode(VideoFormat.webm, codec: VideoCodec.h264), throwsArgumentError);
      expect(() => v.encode(VideoFormat.mp3, codec: VideoCodec.h264), throwsArgumentError);
    });
  });

  test('frame returns an Image', () async {
    final img = await Fs.file(clip).video().frame(at: 1.seconds);
    expect((img.width(), img.height()), (640, 360));
  });

  group('Video.compress', () {
    test('replaces only when smaller, then keeps the file', () async {
      final path = await make('big.mp4', ['-i', clip, '-c:v', 'libx264', '-crf', '5', '-c:a', 'copy']);
      final m = Meter();
      final saved = await (Video.compress(path, quality: 50) & m) as Compressed;
      expect(m.total(), closeTo(2000000, 100000), reason: 'a watched compress counts media time');
      expect(saved.after, lessThan(saved.before));
      expect(await io.File(path).length(), saved.after);
      expect(await Fs.file(path).video().audioCodec(), 'aac');
      expect(await Video.compress(path, quality: 50), isA<Kept>().having((k) => k.reason, 'reason', KeptReason.notSmaller));
      expect(io.Directory(tmp.path).listSync().where((e) => e.path.endsWith('.compress')), isEmpty);
    });

    test('audio-only and non-video files are left alone', () async {
      final audio = await make('only.m4a', ['-i', clip, '-vn', '-c', 'copy']);
      expect(await Video.compress(audio), isA<Kept>().having((k) => k.reason, 'reason', KeptReason.lossy));
      final txt = '${tmp.path}/x.txt';
      await io.File(txt).writeAsString('not a video at all, really not');
      expect(await Video.compress(txt), isA<Kept>().having((k) => k.reason, 'reason', KeptReason.unknown));
    });

    test('E7: an MP4 that does not decode is Kept(broken), not a throw', () async {
      final junk = '${tmp.path}/junk.mp4';
      await io.File(junk).writeAsBytes([0, 0, 0, 24, ...'ftypisom'.codeUnits, ...List.filled(400, 0x41)]);
      expect(await Video.compress(junk), isA<Kept>().having((k) => k.reason, 'reason', KeptReason.broken));
    });

    test('Ctrl-C mid-compress leaves no .compress beside the file (B18)', () async {
      final path = await make('long.mp4', [
        '-f', 'lavfi', '-i', 'testsrc2=s=1280x720:d=20:r=30', //
        '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '5',
      ]);
      final temp = '${tmp.path}/.long.mp4.compress';
      final child = await startDart('''
import 'package:dart_toolkit/video.dart';
Future<void> main(List<String> args) async => print(await Video.compress(args[0], quality: 50));
''', args: [path]);
      expect(await eventually(() => io.File(temp).existsSync(), timeout: const Duration(seconds: 30)), isTrue);
      child.kill(io.ProcessSignal.sigint);
      expect(await child.exitCode.timeout(const Duration(seconds: 15)), 130);
      expect(io.File(temp).existsSync(), isFalse);
    }, skip: io.Platform.isWindows ? 'POSIX signals' : null);
  });
}

final class _Heard with Probe {
  _Heard(this._heard);
  final List<(int, int?)> _heard;
  @override
  void update(int done, int? total) => _heard.add((done, total));
}

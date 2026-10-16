// medialoader's download queue, feed walk and dashboard plumbing, against
// a local server (never the real sites).
import 'dart:io' as io;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/src/media.dart' as engine;
import 'package:dart_toolkit/video.dart';
import 'package:test/test.dart';

import '../projects/medialoader/dashboard.dart';
import '../projects/medialoader/download.dart';
import '../projects/medialoader/instagram.dart' as instagram;
import '../projects/medialoader/media.dart' as media;
import '../projects/medialoader/medialoader.dart' as cli;
import '../projects/medialoader/platform.dart';
import '../projects/medialoader/twitter.dart' as twitter;

late io.HttpServer server;
late String base;
late io.Directory tmp;
final served = <String, List<int>>{};
var flaky = 0;

Options opts({int? image, int? video, bool dry = false, DateTime? since}) =>
    (all: false, reset: false, dry: dry, since: since, image: image, video: video);

// A job for @[name] under a fresh downloads/ins/ folder, its folders read.
Future<Job> job(String name, Options o, {Set<String> cats = const {'post'}}) async {
  final j = Job(Target(instagram.platform, name), cats, Http.client(), Fs.dir('${tmp.path}/$name'), Queue(o));
  await j.open(name);
  return j;
}

Future<List<int>> make(String name, List<String> args) async {
  final out = '${tmp.path}/fixture-$name';
  await engine.ffmpeg(['-f', 'lavfi', ...args, '-y', out]);
  return io.File(out).readAsBytes();
}

void main() {
  setUpAll(() async {
    tmp = await io.Directory.systemTemp.createTemp('medialoader_test');
    // A high-quality JPEG and a near-lossless MP4: both shrink when re-encoded.
    served['/photo.jpg'] = await make('photo.jpg', ['-i', 'testsrc2=s=256x256', '-frames:v', '1', '-q:v', '1']);
    served['/video.mp4'] = await make('video.mp4', [
      '-i', 'testsrc2=s=160x120:d=1:r=10', '-c:v', 'libx264', '-crf', '5', '-pix_fmt', 'yuv420p', //
    ]);
    served['/small.jpg'] = await make('small.jpg', ['-i', 'testsrc2=s=64x64', '-frames:v', '1', '-q:v', '31']);
    server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((req) {
      final body = served[req.uri.path];
      if (req.uri.path == '/flaky' && flaky++ == 0) {
        req.response.statusCode = 503;
      } else if (req.uri.path == '/flaky') {
        req.response.write('ok');
      } else if (body == null) {
        req.response.statusCode = 404;
      } else {
        req.response.add(body);
      }
      req.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
    await cdn.close();
    await tmp.delete(recursive: true);
  });

  Future<(Job, Transfer, bool)> save(String name, String path, Options o, {DateTime? at}) async {
    final j = await job(name, o);
    final f = media.Download(j.dir.dir('posts').file(path.substring(1)), url: '$base$path', at: at);
    final t = Transfer(j.u, j.u.parts['posts']!, f.to.path(from: j.dir));
    return (j, t, await j.queue.save(j, f, t));
  }

  test('an image is compressed in its format, and the bytes counted are the file on disk', () async {
    final (j, t, isNew) = await save('img', '/photo.jpg', opts(image: 30));
    final file = j.dir.dir('posts').file('photo.jpg');
    final bytes = await file.bytes();
    expect(isNew, isTrue);
    expect(Image.sniff(bytes), ImageFormat.jpg);
    expect((await Image.decode(bytes)).width(), 256);
    expect(bytes.length, lessThan(served['/photo.jpg']!.length));
    expect(t.part.bytes, bytes.length, reason: 'part bytes follow the compressed size');
    expect(board.events.last.line, contains('compressed from'));
  });

  test('a video is compressed in its container', () async {
    final (j, _, _) = await save('vid', '/video.mp4', opts(video: 20));
    final bytes = await j.dir.dir('posts').file('video.mp4').bytes();
    expect(Video.sniff(bytes), VideoFormat.mp4);
    expect(bytes.length, lessThan(served['/video.mp4']!.length));
  });

  test('without a quality the file is saved as served', () async {
    final (j, _, _) = await save('raw', '/photo.jpg', opts());
    expect(await j.dir.dir('posts').file('photo.jpg').bytes(), served['/photo.jpg']);
    expect(board.events.last.line, isNot(contains('compress')));
  });

  test('a file compression cannot shrink is kept, and the log says so (regression: "already optimal")', () async {
    final (j, _, _) = await save('kept', '/small.jpg', opts(image: 95));
    expect(await j.dir.dir('posts').file('small.jpg').bytes(), served['/small.jpg']);
    expect(board.events.last.line, contains('kept'));
  });

  test('the speed never goes negative when compression shrinks a file (regression)', () async {
    await save('speed', '/photo.jpg', opts(image: 20));
    expect(board.speed.rate(), greaterThan(0));
  });

  test('a file is dated to its post', () async {
    final posted = DateTime(2020, 1, 2, 3, 4, 5);
    final (j, _, _) = await save('dated', '/small.jpg', opts(), at: posted);
    expect(await j.dir.dir('posts').file('small.jpg').modified(), posted);
  });

  test('--dry-run writes nothing', () async {
    final (j, _, isNew) = await save('dry', '/photo.jpg', opts(dry: true));
    expect(isNew, isTrue);
    expect(await j.dir.dir('posts').file('photo.jpg').exists(), isFalse);
    expect(board.events.last.line, contains('would save posts/photo.jpg'));
    await j.index.save();
    expect(await j.dir.file('.ins.json').exists(), isFalse, reason: 'the index is not written either');
  });

  test('folder stats skip partial downloads and compress temps (regression)', () async {
    final d = Fs.dir('${tmp.path}/stats/stats/posts/2024-01');
    await d.file('a.jpg').write('12345');
    await d.file('b.jpg.part').write('123');
    await d.file('b.jpg.part.tag').write('"e"');
    await d.file('.a.jpg.compress').write('123');
    final j = await job('stats', opts());
    expect((j.u.parts['posts']!.had, j.u.parts['posts']!.bytes), (1, 5));
  });

  test('without a terminal, failures are retried once while the clients are still open (regression: closed)', () async {
    final c = Http.client(retries: 0, check: true);
    var retried = false, closed = false;
    await watch(
      () async {
        try {
          await c.get('$base/flaky').text();
        } on HttpStatusException {
          board.fail('flaky failed', () async {
            expect(await c.get('$base/flaky').text(), 'ok');
            retried = true;
          });
        }
      },
      close: () async {
        expect(retried, isTrue, reason: 'the retry ran before the clients closed');
        closed = true;
        await c.close();
      },
    );
    expect((retried, closed), (true, true));
    expect(board.failures, isEmpty);
  });

  group('feed', () {
    Json post(String code, DateTime at) => Json.of({'code': code, 'taken_at': at.millisecondsSinceEpoch ~/ 1000});

    Future<void> walk(Job j, Map<String?, Page> pages, {String? fail}) => feed(
      j,
      folder: 'posts',
      noun: 'post',
      page: (cursor) async => pages[cursor]!,
      id: media.code,
      items: media.items,
      time: media.time,
      files: (page) => [
        for (final p in page)
          media.code(p) == fail
              ? media.Download(j.dir.dir('posts').file('${media.code(p)}.jpg'), url: '$base/missing')
              : media.Download(j.dir.dir('posts').file('${media.code(p)}.txt'), text: 'x', at: media.time(p)),
      ],
    );

    test('--since keeps newer posts and stops at the first page older than it', () async {
      final j = await job('since', opts(since: DateTime(2024, 3, 1)));
      final m = [for (final i in [5, 4, 3, 2, 1]) post('c$i', DateTime(2024, i, 15))];
      await walk(j, {
        null: (items: m.sublist(0, 2), next: 'p2'),
        'p2': (items: m.sublist(2, 4), next: 'p3'),
        'p3': (items: m.sublist(4), next: 'p4'), // p4 is never asked for
      });
      await Future.wait(j.batches);
      final saved = [for (final e in await j.dir.dir('posts').list()) e.name()]..sort();
      expect(saved, ['c3.txt', 'c4.txt', 'c5.txt']);
      expect(await j.dir.dir('posts').file('c5.txt').modified(), DateTime(2024, 5, 15));
      expect(await j.cursor('posts').exists(), isFalse);
    });

    test('the cursor moves only past pages whose files are all down', () async {
      final j = await job('cursor', opts());
      final pages = {
        null: (items: [post('a', DateTime(2024, 2))], next: 'p2'),
        'p2': (items: [post('b', DateTime(2024))], next: null),
      };
      await walk(j, pages, fail: 'b');
      await Future.wait(j.batches);
      expect(await j.cursor('posts').text(), 'p2', reason: 'page 2 failed: the next run starts there');
      expect(board.failures.single.line, contains('b.jpg'));
      board.failures.clear();
    });
  });

  group('command line', () {
    Future<(int, Options?)> parse(List<String> args) async {
      Options? got;
      final code = await Command('t', 't', params: cli.shared, handler: (c) => got = cli.options(c)).run(args);
      return (code, got);
    }

    test('--compress, --quality and per-kind qualities', () async {
      expect((await parse(['--compress'])).$2, isA<Options>().having((o) => (o.image, o.video), 'q', (85, 80)));
      expect((await parse(['--compress', '--image-quality', '90'])).$2?.image, 90);
      expect((await parse(['--quality', '70'])).$2?.video, 70);
      expect((await parse(['--since', '2024-05-01'])).$2?.since, DateTime(2024, 5, 1));
    });

    test('a quality outside 1-100 and the removed aliases are usage errors', () async {
      for (final args in [
        ['--image-quality', '0'],
        ['--video-quality', '101'],
        ['--compress-image', '80'],
        ['--since', 'soon'],
      ]) {
        expect((await parse(args)).$1, isNot(0), reason: '$args');
      }
      io.exitCode = 0;
    });
  });

  test('post URLs are single-post targets', () {
    final ig = parseTarget('https://www.instagram.com/p/DAbc123_x-Y/');
    expect((ig.platform, ig.post), (instagram.platform, 'DAbc123_x-Y'));
    expect(parseTarget('https://www.instagram.com/someone/reel/C0de/').post, 'C0de');
    expect(parseTarget('instagram.com/someone').post, isNull);
    final tw = parseTarget('https://x.com/someone/status/1790000000000000000');
    expect((tw.platform, tw.user, tw.post), (twitter.platform, 'someone', '1790000000000000000'));
    expect(twitter.tweetTime(Json.of({'rest_id': '1790000000000000000'})).year, 2024);
  });
}

/// Tests for what a crawl fetches, and what it manages not to. Each group
/// names the behaviour that used to be missing: every re-run downloaded
/// everything again, a PDF reached the HTML parser, and a form could only be
/// posted by reaching past `res.follow` for `engine.add`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

/// A local server that counts what it actually served.
class _Origin {
  _Origin(this.server, this.root);

  final HttpServer server;
  final String root;

  /// Bodies served, by path. A conditional hit adds nothing.
  final List<String> served = [];

  static Future<_Origin> start(
    Future<void> Function(HttpRequest req, _Origin origin) handle,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = _Origin(
      server,
      'http://${server.address.host}:${server.port}',
    );
    server.listen((req) async {
      await handle(req, origin);
      await req.response.close();
    });
    return origin;
  }

  Future<void> stop() => server.close(force: true);
}

String _tempDir() => Directory.systemTemp.createTempSync('dt_cache_').path;

void main() {
  group('HttpCache freshness', () {
    test('a response inside its max-age is fresh', () {
      final entry = CacheEntry(
        response: Reply(
          url: Uri.parse('https://example.com/'),
          status: 200,
          headers: const {'cache-control': 'max-age=600'},
          bytes: const [],
        ),
        stored: DateTime.now().subtract(const Duration(seconds: 5)),
      );

      expect(entry.lifetime, const Duration(seconds: 600));
      expect(entry.fresh, isTrue);
    });

    test('a response past its max-age is not', () {
      final entry = CacheEntry(
        response: Reply(
          url: Uri.parse('https://example.com/'),
          status: 200,
          headers: const {'cache-control': 'max-age=1'},
          bytes: const [],
        ),
        stored: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      expect(entry.fresh, isFalse);
    });

    test('no-cache means ask every time, however recent', () {
      final entry = CacheEntry(
        response: Reply(
          url: Uri.parse('https://example.com/'),
          status: 200,
          headers: const {'cache-control': 'no-cache, max-age=600'},
          bytes: const [],
        ),
        stored: DateTime.now(),
      );

      expect(entry.lifetime, Duration.zero);
      expect(entry.fresh, isFalse);
    });

    test('Expires is read against Date, not against the clock', () {
      final sent = DateTime.utc(2030);
      final entry = CacheEntry(
        response: Reply(
          url: Uri.parse('https://example.com/'),
          status: 200,
          headers: {
            'date': HttpDate.format(sent),
            'expires': HttpDate.format(sent.add(const Duration(hours: 2))),
          },
          bytes: const [],
        ),
        stored: DateTime.now(),
      );

      expect(entry.lifetime, const Duration(hours: 2));
    });

    test('a server that promised nothing is never fresh', () {
      final entry = CacheEntry(
        response: Reply(
          url: Uri.parse('https://example.com/'),
          status: 200,
          headers: const {},
          bytes: const [],
        ),
        stored: DateTime.now(),
      );

      expect(entry.lifetime, isNull);
      expect(entry.fresh, isFalse);
    });

    test('validators are whatever the response gave us to ask with', () {
      Reply with_(Map<String, String> headers) => Reply(
        url: Uri.parse('https://example.com/'),
        status: 200,
        headers: headers,
        bytes: const [],
      );

      expect(
        CacheEntry(
          response: with_(const {'etag': 'W/"1"'}),
          stored: DateTime.now(),
        ).validators,
        {'If-None-Match': 'W/"1"'},
      );
      expect(
        CacheEntry(
          response: with_(const {
            'last-modified': 'Wed, 21 Oct 2015 07:28:00 GMT',
          }),
          stored: DateTime.now(),
        ).validators,
        {'If-Modified-Since': 'Wed, 21 Oct 2015 07:28:00 GMT'},
      );
      expect(
        CacheEntry(
          response: with_(const {}),
          stored: DateTime.now(),
        ).validators,
        isEmpty,
      );
    });
  });

  group('HttpCache storage', () {
    test('a stored response round-trips, body and all', () async {
      final dir = _tempDir();
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      final cache = HttpCache(dir);
      final url = Uri.parse('https://example.com/page');

      await cache.write(
        url,
        Reply(
          url: url,
          status: 200,
          headers: const {'content-type': 'text/html', 'etag': '"abc"'},
          bytes: utf8.encode('<h1>Hi</h1>'),
        ),
      );

      final entry = await cache.read(url);
      expect(entry, isNotNull);
      expect(entry!.response.body, '<h1>Hi</h1>');
      expect(entry.response.status, 200);
      expect(entry.response.cached, isTrue);
      expect(entry.validators, {'If-None-Match': '"abc"'});
    });

    test('a body that is not text survives', () async {
      final dir = _tempDir();
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      final cache = HttpCache(dir);
      final url = Uri.parse('https://example.com/logo.png');
      final bytes = [0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF];

      await cache.write(
        url,
        Reply(
          url: url,
          status: 200,
          headers: const {'content-type': 'image/png'},
          bytes: bytes,
        ),
      );

      expect((await cache.read(url))!.response.bytes, bytes);
    });

    test('a corrupt file costs a refetch, not a crash', () async {
      final dir = _tempDir();
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      final cache = HttpCache(dir);
      final url = Uri.parse('https://example.com/page');

      Directory(dir).createSync(recursive: true);
      File(cache.path(url)).writeAsStringSync('{ not json');

      expect(await cache.read(url), isNull);
      // And the bad file is gone, so it cannot cost a second one.
      expect(File(cache.path(url)).existsSync(), isFalse);
    });

    test('clear forgets everything and says how much', () async {
      final dir = _tempDir();
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      final cache = HttpCache(dir);

      for (final path in ['/a', '/b']) {
        await cache.write(
          Uri.parse('https://example.com$path'),
          Reply(
            url: Uri.parse('https://example.com$path'),
            status: 200,
            headers: const {},
            bytes: const [],
          ),
        );
      }

      expect(await cache.clear(), 2);
      expect(await cache.read(Uri.parse('https://example.com/a')), isNull);
    });
  });

  group('Fetcher with a cache', () {
    test('a 304 serves the stored body, and no bytes cross the wire', () async {
      final origin = await _Origin.start((req, origin) async {
        if (req.headers.value('if-none-match') == '"v1"') {
          req.response.statusCode = 304;
          return;
        }
        origin.served.add(req.uri.path);
        req.response
          ..statusCode = 200
          ..headers.set('etag', '"v1"')
          ..headers.set('content-type', 'text/html')
          ..write('<h1>Original</h1>');
      });
      addTearDown(origin.stop);

      final dir = _tempDir();
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      final client = Fetcher(cache: HttpCache(dir));
      addTearDown(client.close);

      final first = await client.get('${origin.root}/page'.url);
      expect(first.body, '<h1>Original</h1>');
      expect(first.cached, isFalse);

      final second = await client.get('${origin.root}/page'.url);
      expect(second.body, '<h1>Original</h1>');
      expect(second.cached, isTrue);
      // Served once, asked about twice.
      expect(origin.served, ['/page']);
    });

    test('a response inside max-age is not even asked about', () async {
      final origin = await _Origin.start((req, origin) async {
        origin.served.add(req.uri.path);
        req.response
          ..statusCode = 200
          ..headers.set('cache-control', 'max-age=300')
          ..write('fresh');
      });
      addTearDown(origin.stop);

      final dir = _tempDir();
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      final client = Fetcher(cache: HttpCache(dir));
      addTearDown(client.close);

      await client.get('${origin.root}/page'.url);
      final second = await client.get('${origin.root}/page'.url);

      expect(second.cached, isTrue);
      expect(second.body, 'fresh');
      expect(origin.served, hasLength(1));
    });

    test('a changed page is refetched, not served stale', () async {
      var version = 1;
      final origin = await _Origin.start((req, origin) async {
        if (req.headers.value('if-none-match') == '"v$version"') {
          req.response.statusCode = 304;
          return;
        }
        origin.served.add(req.uri.path);
        req.response
          ..statusCode = 200
          ..headers.set('etag', '"v$version"')
          ..write('version $version');
      });
      addTearDown(origin.stop);

      final dir = _tempDir();
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      final client = Fetcher(cache: HttpCache(dir));
      addTearDown(client.close);

      expect((await client.get('${origin.root}/p'.url)).body, 'version 1');
      version = 2;
      final second = await client.get('${origin.root}/p'.url);

      expect(second.body, 'version 2');
      expect(second.cached, isFalse);
    });

    test('a POST is never stored', () async {
      final origin = await _Origin.start((req, origin) async {
        origin.served.add(req.method);
        req.response
          ..statusCode = 200
          ..headers.set('cache-control', 'max-age=300')
          ..write('ok');
      });
      addTearDown(origin.stop);

      final dir = _tempDir();
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      final client = Fetcher(cache: HttpCache(dir));
      addTearDown(client.close);

      await client.post('${origin.root}/submit'.url, body: Body.text('a'));
      await client.post('${origin.root}/submit'.url, body: Body.text('a'));

      expect(origin.served, ['POST', 'POST']);
    });

    test('no-store is honoured', () async {
      final origin = await _Origin.start((req, origin) async {
        origin.served.add(req.uri.path);
        req.response
          ..statusCode = 200
          ..headers.set('cache-control', 'no-store')
          ..write('secret');
      });
      addTearDown(origin.stop);

      final dir = _tempDir();
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      final cache = HttpCache(dir);
      final client = Fetcher(cache: cache);
      addTearDown(client.close);

      await client.get('${origin.root}/p'.url);
      expect(await cache.read('${origin.root}/p'.url), isNull);
    });
  });

  group('net.crawl().accept', () {
    test('a response of the wrong type never reaches a handler', () async {
      final handled = <String>[];
      final stats = await net
          .crawl<String>('https://example.com/page'.url)
          .accept(['text/html'])
          .downloader(
            MapDownloader<String>(
              {'/page': '%PDF-1.7'},
              headers: const {'content-type': 'application/pdf'},
            ),
          )
          .run((res) => handled.add(res.url.path));

      expect(handled, isEmpty);
      expect(stats.skipped, 1);
      expect(stats.completed, 0);
    });

    test('a subtype wildcard matches', () async {
      final handled = <String>[];
      await net
          .crawl<String>('https://example.com/page'.url)
          .accept(['text/*'])
          .downloader(MapDownloader<String>({'/page': '<h1>hi</h1>'}))
          .run((res) => handled.add(res.url.path));

      expect(handled, ['/page']);
    });

    test('the types asked for are sent as the Accept header', () {
      final downloader =
          net
                  .crawl<String>('https://example.com'.url)
                  .accept(['text/html', 'application/xhtml+xml'])
                  .engine()
                  .downloader
              as HttpDownloader<String>;

      expect(downloader.headers['Accept'], 'text/html, application/xhtml+xml');
    });

    test('an Accept the caller set themselves is left alone', () {
      final downloader =
          net
                  .crawl<String>('https://example.com'.url)
                  .accept(['text/html'])
                  .headers({'Accept': 'text/plain'})
                  .engine()
                  .downloader
              as HttpDownloader<String>;

      expect(downloader.headers['Accept'], 'text/plain');
    });
  });

  group('net.crawl().cap', () {
    test('reaches the client that enforces it', () {
      final downloader =
          net
                  .crawl<String>('https://example.com'.url)
                  .cap(2048)
                  .engine()
                  .downloader
              as HttpDownloader<String>;

      expect(downloader.cap, 2048);
    });

    test('a body over the cap is refused rather than held', () async {
      final origin = await _Origin.start((req, origin) async {
        req.response
          ..statusCode = 200
          ..write('x' * 5000);
      });
      addTearDown(origin.stop);

      final client = Fetcher(cap: 100, retries: 0);
      addTearDown(client.close);

      await expectLater(
        client.get('${origin.root}/big'.url),
        throwsA(isA<FatalHttpException>()),
      );
    });
  });

  group('Page.follow', () {
    test('can post a form instead of following a link', () async {
      final downloader = MapDownloader<String>({
        '/login': '<form action="/login" method="post"></form>',
        'POST /login': '<p class="welcome">Signed in</p>',
      });

      final seen = await net
          .crawl<String>('https://example.com/login'.url)
          .downloader(downloader)
          .collect((res) {
            if (res.tag == 'result') {
              res.emit(res.parse(format.html).find('.welcome').text);
              return;
            }
            res.follow(
              res.parse(format.html).find('form').attr('action')!,
              method: HttpMethod.post,
              body: Body.form({'user': 'ada'}),
              tag: 'result',
            );
          });

      expect(seen.list, ['Signed in']);
      expect(downloader.fetches.map((r) => r.method), [
        HttpMethod.get,
        HttpMethod.post,
      ]);
      expect((downloader.fetches.last.body! as FormBody).fields, {
        'user': 'ada',
      });
    });

    test(
      'two posts to one URL with different fields are two fetches',
      () async {
        final downloader = MapDownloader<String>({
          'POST /search': '<p>hits</p>',
        });

        await net
            .crawl<String>('https://example.com/search'.url)
            .downloader(downloader)
            .run((res) {
              if (res.depth > 0) return;
              for (final page in ['1', '2', '2']) {
                res.follow(
                  '/search',
                  method: HttpMethod.post,
                  body: Body.form({'page': page}),
                );
              }
            });

        // Page 2 asked for twice, fetched once: de-duplication reads the body.
        final posts = downloader.fetches.where(
          (r) => r.method == HttpMethod.post,
        );
        expect(posts, hasLength(2));
      },
    );
  });

  group('MapDownloader', () {
    test('a method-prefixed key beats the bare one', () async {
      final downloader = MapDownloader<String>({
        '/thing': 'get body',
        'POST /thing': 'post body',
      });

      final get = await downloader.download(
        Fetch<String>(Uri.parse('https://example.com/thing')),
      );
      final post = await downloader.download(
        Fetch<String>(
          Uri.parse('https://example.com/thing'),
          method: HttpMethod.post,
        ),
      );

      expect(get.body, 'get body');
      expect(post.body, 'post body');
    });

    test('a method with no key of its own still falls back', () async {
      final downloader = MapDownloader<String>({'/thing': 'shared'});
      final res = await downloader.download(
        Fetch<String>(
          Uri.parse('https://example.com/thing'),
          method: HttpMethod.put,
        ),
      );

      expect(res.body, 'shared');
      expect(res.status, 200);
    });

    test('an unknown path is still a 404', () async {
      final downloader = MapDownloader<String>({'/thing': 'x'});
      final res = await downloader.download(
        Fetch<String>(Uri.parse('https://example.com/other')),
      );

      expect(res.status, 404);
    });

    test('records the headers a pipeline sent', () async {
      final downloader = MapDownloader<String>({'/a': '<a href="/b">b</a>'});
      await net
          .crawl<String>('https://example.com/a'.url)
          .downloader(downloader)
          .run((res) => res.follow('/b', headers: {'X-Stage': 'two'}));

      expect(downloader.fetches.last.headers['X-Stage'], 'two');
      expect(downloader.fetches.last.headers['Referer'], contains('/a'));
    });
  });

  group('Robots.load', () {
    test('a 5xx disallows everything, per RFC 9309 2.3.1.4', () async {
      final origin = await _Origin.start((req, origin) async {
        req.response.statusCode = 503;
      });
      addTearDown(origin.stop);

      final robots = await Robots.load(origin.root.url);
      // Unreachable rules are not absent rules: the crawl stays out.
      expect(robots.allowed('${origin.root}/anything'.url), isFalse);
    });

    test('a 404 still allows everything, per 2.3.1.3', () async {
      final origin = await _Origin.start((req, origin) async {
        req.response.statusCode = 404;
      });
      addTearDown(origin.stop);

      final robots = await Robots.load(origin.root.url);
      expect(robots.allowed('${origin.root}/anything'.url), isTrue);
    });

    test('a crawl obeying robots skips a host whose rules 500', () async {
      final origin = await _Origin.start((req, origin) async {
        if (req.uri.path == '/robots.txt') {
          req.response.statusCode = 500;
          return;
        }
        origin.served.add(req.uri.path);
        req.response.write('<h1>page</h1>');
      });
      addTearDown(origin.stop);

      final stats = await net
          .crawl<String>('${origin.root}/page'.url)
          .robots()
          .run((res) {});

      expect(stats.skipped, 1);
      expect(origin.served, isEmpty);
    });
  });

  group('util.rand.seed', () {
    tearDown(() => util.rand.seed());

    test('the same seed replays the same choices', () {
      util.rand.seed(42);
      final first = [util.rand.id(), util.rand.between(0, 1000).toString()];

      util.rand.seed(42);
      final second = [util.rand.id(), util.rand.between(0, 1000).toString()];

      expect(second, first);
    });

    test('a crawl order can be made repeatable', () {
      const agents = ['a', 'b', 'c', 'd', 'e'];

      util.rand.seed(7);
      final first = util.rand.shuffle(agents);
      util.rand.seed(7);

      expect(util.rand.shuffle(agents).list, first.list);
    });

    test('seeding again with nothing goes back to being unpredictable', () {
      util.rand.seed(1);
      final seeded = util.rand.id(32);
      util.rand.seed();

      expect(util.rand.id(32), isNot(seeded));
    });

    test('retry jitter runs off the same generator', () {
      // One generator, so a test that seeds it gets a repeatable backoff too.
      util.rand.seed(3);
      final first = util.rand.jitter(const Duration(seconds: 1));
      util.rand.seed(3);

      expect(util.rand.jitter(const Duration(seconds: 1)), first);
    });
  });
}

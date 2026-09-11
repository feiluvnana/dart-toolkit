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

      final first = await client.send(.get, '${origin.root}/page'.url);
      expect(first.body, '<h1>Original</h1>');
      expect(first.cached, isFalse);

      final second = await client.send(.get, '${origin.root}/page'.url);
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

      await client.send(.get, '${origin.root}/page'.url);
      final second = await client.send(.get, '${origin.root}/page'.url);

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

      expect(
        (await client.send(.get, '${origin.root}/p'.url)).body,
        'version 1',
      );
      version = 2;
      final second = await client.send(.get, '${origin.root}/p'.url);

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

      await client.send(
        .post,
        '${origin.root}/submit'.url,
        body: Body.text('a'),
      );
      await client.send(
        .post,
        '${origin.root}/submit'.url,
        body: Body.text('a'),
      );

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

      await client.send(.get, '${origin.root}/p'.url);
      expect(await cache.read('${origin.root}/p'.url), isNull);
    });
  });

  group('net.crawl().accept', () {
    test('a response of the wrong type never reaches a handler', () async {
      final crawl = net.crawl([Fetch('https://example.com/page'.url)])
        ..accept(const ['text/html'])
        ..using(
          (fetch) async => Reply.text(
            '%PDF-1.7',
            fetch: fetch,
            headers: const {'content-type': 'application/pdf'},
          ),
        );

      final handled = await crawl.flow
          .transform(.map((res) => res.url.path))
          .collect(.list());

      expect(handled, isEmpty);
      expect(crawl.stats.skipped, 1);
      expect(crawl.stats.fetched, 0);
    });

    test('a subtype wildcard matches', () async {
      final crawl = net.crawl([Fetch('https://example.com/page'.url)])
        ..accept(const ['text/*'])
        ..using((fetch) async => Reply.text('<h1>hi</h1>', fetch: fetch));

      final handled = await crawl.flow
          .transform(.map((res) => res.url.path))
          .collect(.list());

      expect(handled, ['/page']);
    });

    test('the types asked for are sent as the Accept header', () async {
      // `accept` does two things on purpose — the header and the filter — and
      // they are two halves of one intent, so they are set in one place.
      final sent = <Fetch>[];
      await (net.crawl([Fetch('https://example.com/'.url)])
            ..accept(const ['text/html', 'application/xhtml+xml'])
            ..using((fetch) async {
              sent.add(fetch);
              return Reply.text('<h1>hi</h1>', fetch: fetch);
            }))
          .run();

      expect(sent.single.headers['Accept'], 'text/html, application/xhtml+xml');
    });

    test('a header the client already carries wins', () {
      // Everything about the client is the client's: a crawl has no
      // `.headers` to disagree with it.
      final client = Fetcher(headers: const {'Accept': 'text/plain'});
      expect(client.headers['Accept'], 'text/plain');
    });
  });

  group('the client knobs live on the client', () {
    test('cap is a Fetcher field, declared once', () {
      final client = Fetcher(cap: 2048);
      expect(client.cap, 2048);
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
        client.send(.get, '${origin.root}/big'.url),
        throwsA(isA<FatalHttpException>()),
      );
    });
  });

  group('Reply.follow', () {
    test('can post a form instead of following a link', () async {
      final sent = <Fetch>[];
      Future<Reply> transport(Fetch fetch) async {
        sent.add(fetch);
        return Reply.text(
          fetch.method == HttpMethod.post
              ? '<p class="welcome">Signed in</p>'
              : '<form action="/login" method="post"></form>',
          fetch: fetch,
        );
      }

      final crawl = net.crawl(
        [Fetch('https://example.com/login'.url)],
        (res) => switch (res.fetch.tag) {
          null => [
            res.follow(
              res.parse(format.html).$('form').attr('action')!,
              method: HttpMethod.post,
              body: Body.form({'user': 'ada'}),
              tag: 'result',
            ),
          ].seq,
          _ => const Sequence<Fetch>([]),
        },
      )..using(transport);

      final seen = await crawl.flow
          .transform(.where((res) => res.fetch.tag == 'result'))
          .transform(.map((res) => res.parse(format.html).$('.welcome').text))
          .collect(.list());

      expect(seen, ['Signed in']);
      expect(sent.map((r) => r.method), [HttpMethod.get, HttpMethod.post]);
      expect(sent.last.body!.toJson(), {
        'kind': 'form',
        'fields': {'user': 'ada'},
      });
    });

    test(
      'two posts to one URL with different fields are two fetches',
      () async {
        final sent = <Fetch>[];
        await (net.crawl(
              [Fetch('https://example.com/search'.url)],
              (res) => res.fetch.depth > 0
                  ? const Sequence<Fetch>([])
                  : ['1', '2', '2']
                        .map(
                          (page) => res.follow(
                            '/search',
                            method: HttpMethod.post,
                            body: Body.form({'page': page}),
                          ),
                        )
                        .seq,
            )..using((fetch) async {
              sent.add(fetch);
              return Reply.text('<p>hits</p>', fetch: fetch);
            }))
            .run();

        // Page 2 asked for twice, fetched once: de-duplication reads the body.
        expect(sent.where((r) => r.method == HttpMethod.post), hasLength(2));
      },
    );

    test(
      'a followed request carries the Referer and the caller headers',
      () async {
        final sent = <Fetch>[];
        await (net.crawl(
              [Fetch('https://example.com/a'.url)],
              (res) => res.fetch.depth > 0
                  ? const Sequence<Fetch>([])
                  : [
                      res.follow('/b', headers: {'X-Stage': 'two'}),
                    ].seq,
            )..using((fetch) async {
              sent.add(fetch);
              return Reply.text('<a href="/b">b</a>', fetch: fetch);
            }))
            .run();

        expect(sent.last.headers['X-Stage'], 'two');
        expect(sent.last.headers['Referer'], contains('/a'));
      },
    );
  });

  group('robots, over the crawl own transport', () {
    test('a 5xx disallows everything, per RFC 9309 2.3.1.4', () async {
      final origin = await _Origin.start((req, origin) async {
        req.response.statusCode = 503;
      });
      addTearDown(origin.stop);

      final crawl = net.crawl([Fetch('${origin.root}/anything'.url)])..obey();
      await crawl.run();

      // Unreachable rules are not absent rules: the crawl stays out.
      expect(crawl.stats.skipped, 1);
      expect(crawl.stats.fetched, 0);
    });

    test('a 404 still allows everything, per 2.3.1.3', () async {
      final origin = await _Origin.start((req, origin) async {
        if (req.uri.path == '/robots.txt') {
          req.response.statusCode = 404;
          return;
        }
        req.response.write('<h1>page</h1>');
      });
      addTearDown(origin.stop);

      final crawl = net.crawl([Fetch('${origin.root}/anything'.url)])..obey();
      await crawl.run();

      expect(crawl.stats.fetched, 1);
      expect(crawl.stats.skipped, 0);
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

      final crawl = net.crawl([Fetch('${origin.root}/page'.url)])..obey();
      await crawl.run();

      expect(crawl.stats.skipped, 1);
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

      expect(
        util.rand.shuffle(agents).collect(.list()),
        first.collect(.list()),
      );
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

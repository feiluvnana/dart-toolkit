import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

/// In-memory downloader for deterministic pipeline tests.
///
/// This is the intended way to test a crawl: subclass [Downloader] and serve
/// fixtures instead of reaching the network.
class MockDownloader<T> extends Downloader<T> {
  final Map<String, String> pages;

  MockDownloader(this.pages, {super.concurrency = 1});

  @override
  Future<Page<T>> download(Fetch<T> fetch) async {
    if (fetch.url.scheme == 'data') {
      final bytes =
          fetch.url.data?.contentAsBytes() ??
          utf8.encode(fetch.url.data?.contentAsString() ?? '');
      return Page<T>(
        fetch: fetch,
        status: 200,
        headers: {'content-type': 'text/html; charset=utf-8'},
        bytes: bytes,
        engine: engine,
      );
    }
    final body = pages[fetch.url.toString()];
    return Page<T>(
      fetch: fetch,
      status: body == null ? 404 : 200,
      headers: const {'content-type': 'text/html; charset=utf-8'},
      bytes: utf8.encode(body ?? '<html><body>404 Not Found</body></html>'),
      engine: engine,
    );
  }

  @override
  Future<File> save(
    Uri source,
    String path, {
    void Function(int received, int total)? onProgress,
    String part = '.part',
    bool match = false,
  }) async {
    final response = await download(Fetch<T>(source));
    return response.save(resolve(path), part: part);
  }
}

const _name = Slot<String>('name');

void main() {
  group('Deduplicator & Queue', () {
    test('Deduplicator normalises fragments and trailing slashes', () {
      final dedupe = Deduplicator();

      expect(dedupe.add('https://example.com/page1'.url), isTrue);
      expect(dedupe.add('https://example.com/page2'.url), isTrue);
      expect(dedupe.add('https://example.com/page1#section'.url), isFalse);
      expect(dedupe.add('https://example.com/page1/'.url), isFalse);

      expect(dedupe.seen('https://example.com/page1'.url), isTrue);
      expect(dedupe.seen('https://example.com/page3'.url), isFalse);
      expect(dedupe.length, equals(2));

      dedupe.clear();
      expect(dedupe.isEmpty, isTrue);
    });

    test('Engine queues, deduplicates and serves', () {
      final engine = Engine<String>();

      engine.add(Fetch('https://example.com/page1'.url));
      engine.add(Fetch('https://example.com/page2'.url));
      engine.add(Fetch('https://example.com/page1#section'.url));

      expect(engine.queue.length, equals(2));
      expect(engine.queue.isNotEmpty, isTrue);

      expect(engine.serve()?.url.path, equals('/page1'));
      expect(engine.serve()?.url.path, equals('/page2'));
      expect(engine.serve(), isNull);
      expect(engine.queue.isEmpty, isTrue);
    });

    test('higher priority is served first, ties stay FIFO', () {
      final engine = Engine<String>();

      engine.add(Fetch('https://example.com/low'.url));
      engine.add(Fetch('https://example.com/high'.url, priority: 100));
      engine.add(Fetch('https://example.com/mid'.url, priority: 50));
      engine.add(Fetch('https://example.com/high2'.url, priority: 100));

      expect([
        for (var r = engine.serve(); r != null; r = engine.serve()) r.url.path,
      ], equals(['/high', '/high2', '/mid', '/low']));
    });
  });

  group('Engine pipeline & routing', () {
    test('router follows links across stages by tag', () async {
      final pages = {
        'https://example.com/album': '''
          <div class="album">
            <h1>Sample Album</h1>
            <a href="/disc/1" class="disc-link">Disc 1</a>
            <a href="/disc/2" class="disc-link">Disc 2</a>
          </div>
        ''',
        'https://example.com/disc/1': '''
          <div class="disc" data-num="1">
            <span class="disc-title">Key+Lia Best 2001</span>
            <div class="track">01. Natukage</div>
          </div>
        ''',
        'https://example.com/disc/2': '''
          <div class="disc" data-num="2">
            <span class="disc-title">Kanon Original Soundtrack</span>
            <div class="track">01. Morning Shadows</div>
          </div>
        ''',
      };

      final engine = Engine<Map<String, Object?>>(
        downloader: MockDownloader<Map<String, Object?>>(pages),
      );

      engine.router
        ..on(RegExp(r'/album$'), (res) {
          expect(res.ok, isTrue);
          expect(res.engine, equals(engine));
          for (final href
              in res
                  .parse(format.html)
                  .find('a.disc-link')
                  .attrs('href')
                  .list) {
            res.follow(href, tag: 'disc');
          }
        })
        ..tag('disc', (res) {
          res.emit({
            'disc': int.parse(
              res.parse(format.html).find('.disc').attr('data-num') ?? '0',
            ),
            'title': res.parse(format.html).find('.disc-title').text,
            'firstTrack': res.parse(format.html).find('.track').text,
          });
        });

      final emitted = <Map<String, Object?>>[];
      engine.items.listen(emitted.add);

      engine.add(Fetch('https://example.com/album'.url));
      final stats = await engine.run();

      expect(stats.completed, equals(3));
      expect(stats.emitted, equals(2));
      expect(emitted.length, equals(2));

      expect(emitted[0]['disc'], equals(1));
      expect(emitted[0]['title'], equals('Key+Lia Best 2001'));
      expect(emitted[0]['firstTrack'], equals('01. Natukage'));
      expect(emitted[1]['disc'], equals(2));
      expect(emitted[1]['title'], equals('Kanon Original Soundtrack'));
    });

    test('a handler can stop the pipeline early', () async {
      final pages = {
        'https://example.com/item/1': '<div>Page 1</div>',
        'https://example.com/item/2': '<div>Page 2 (Abort)</div>',
        'https://example.com/item/3': '<div>Page 3</div>',
      };

      final engine = Engine<String>(
        downloader: MockDownloader<String>(pages),
        process: (res) {
          final text = res.parse(format.html).find('div').text;
          res.emit(text);
          if (text.contains('Abort')) res.stop('Found abort keyword');
        },
      );

      final items = <String>[];
      engine.items.listen(items.add);

      for (final url in pages.keys) {
        engine.add(Fetch(url.url));
      }
      final stats = await engine.run();

      expect(engine.stopped, isTrue);
      expect(stats.reason, equals('Found abort keyword'));
      expect(items, contains('Page 1'));
      expect(items, contains('Page 2 (Abort)'));
      expect(items, isNot(contains('Page 3')));
    });

    test('engine.on.error surfaces a throwing handler', () async {
      final errors = <Object>[];
      final engine = Engine<String>(
        downloader: MockDownloader<String>({
          'https://example.com/': '<div>ok</div>',
        }),
        process: (res) => throw StateError('handler blew up'),
      );
      engine.on.error((failure) => errors.add(failure.error));

      await engine.run(['https://example.com/']);
      expect(errors.single, isA<StateError>());
    });
  });

  group('net.crawl builder', () {
    test('multi-step follow carries tags and meta', () async {
      final pages = {
        'https://music.example.com/album': '''
          <table id="songlist">
            <tr><td><a href="/song/1">Track 1</a></td></tr>
            <tr><td><a href="/song/2">Track 2</a></td></tr>
          </table>
        ''',
        'https://music.example.com/song/1':
            '<div><a href="/audio/t1.mp3">Download MP3</a></div>',
        'https://music.example.com/song/2':
            '<div><a href="/audio/t2.mp3">Download MP3</a></div>',
      };

      final visited = <String>[];
      final stats = await net
          .crawl<String>('https://music.example.com/album'.url)
          .downloader(MockDownloader<String>(pages))
          .tag('song', (res) {
            visited.add(
              '${res.meta.get(_name)}: ${res.parse(format.html).find('a').attr('href')}',
            );
          })
          .run((res) {
            for (final a
                in res.parse(format.html).find('#songlist a').elements.list) {
              res.follow(a.attr('href')!, tag: 'song', meta: [_name(a.text)]);
            }
          });

      expect(stats.completed, equals(3));
      expect(
        visited,
        equals(['Track 1: /audio/t1.mp3', 'Track 2: /audio/t2.mp3']),
      );
    });

    test('collect gathers every emitted item', () async {
      final titles = await net
          .crawl<String>('https://news.example.com'.url)
          .concurrent(2)
          .downloader(
            MockDownloader<String>({
              'https://news.example.com': '''
                <div class="articles">
                  <h2 class="title">Article Alpha</h2>
                  <h2 class="title">Article Beta</h2>
                  <h2 class="title">Article Gamma</h2>
                </div>
              ''',
            }),
          )
          .collect((res) {
            for (final t in res.parse(format.html).find('.title').texts.list) {
              res.emit(t);
            }
          });

      expect(
        titles.list,
        equals(['Article Alpha', 'Article Beta', 'Article Gamma']),
      );
    });

    test('stream yields items as they are emitted', () async {
      final items =
          await net
              .crawl<String>('https://site.example.com'.url)
              .downloader(
                MockDownloader<String>({
                  'https://site.example.com':
                      '<span>Alpha</span><span>Beta</span>',
                }),
              )
              .stream((res) {
                for (final t
                    in res.parse(format.html).find('span').texts.list) {
                  res.emit(t);
                }
              })
              .toList();

      expect(items, equals(['Alpha', 'Beta']));
    });

    test('builder follows links discovered mid-crawl', () async {
      final pages = {
        'https://site.example.com':
            '<h1>Hello World</h1><a href="/sub">Sub</a>',
        'https://site.example.com/sub': '<h2>Subpage</h2>',
      };
      final titles = <String>[];

      final stats = await net
          .crawl<String>('https://site.example.com'.url)
          .concurrent(2)
          .delay(10.ms)
          .downloader(MockDownloader<String>(pages))
          .run((res) {
            if (res.url.path == '/sub') {
              titles.add(res.parse(format.html).find('h2').text);
            } else {
              titles.add(res.parse(format.html).find('h1').text);
              res.follow('/sub');
            }
          });

      expect(stats.completed, equals(2));
      expect(titles, equals(['Hello World', 'Subpage']));
    });

    test('all() seeds several URLs at once', () async {
      final stats = await net.crawl
          .all<String>([
            'https://site.example.com/a'.url,
            'https://site.example.com/b'.url,
          ])
          .downloader(
            MockDownloader<String>({
              'https://site.example.com/a': '<p>A</p>',
              'https://site.example.com/b': '<p>B</p>',
            }),
          )
          .run((res) {});

      expect(stats.completed, equals(2));
    });

    test('seed() takes fully-formed fetches', () async {
      final tags = <String?>[];
      await net.crawl
          .seed<String>([
            Fetch('https://site.example.com/a'.url, tag: 'first'),
            Fetch('https://site.example.com/b'.url, tag: 'second'),
          ])
          .downloader(
            MockDownloader<String>({
              'https://site.example.com/a': '<p>A</p>',
              'https://site.example.com/b': '<p>B</p>',
            }),
          )
          .run((res) => tags.add(res.tag));

      expect(tags, equals(['first', 'second']));
    });

    test('concurrent workers terminate once the frontier drains', () async {
      // Guards the worker wake-up path: idle workers must notice the run is
      // over instead of waiting on a completer nobody completes.
      final stats = await net
          .crawl<String>('https://site.example.com/1'.url)
          .concurrent(8)
          .downloader(
            MockDownloader<String>({
              'https://site.example.com/1': '<p>only page</p>',
            }),
          )
          .run((res) {});

      expect(stats.completed, equals(1));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('flow accepts HTML strings directly without URL', () async {
      const htmlString = '''
        <div class="container">
          <a href="/subpage">Subpage Link</a>
          <h1 class="headline">Breaking News</h1>
        </div>
      ''';

      final headlines = await net.crawl.html<String>(htmlString).collect((res) {
        // Test res.$ and emit
        final title = res.parse(format.html).find('.headline').text;
        if (title.isNotEmpty) res.emit(title);
      });

      expect(headlines.list, equals(['Breaking News']));
    });

    test('net.crawl.html explicitly parses markup without sniffing', () async {
      const markup = '<article><h2>Explicit HTML</h2></article>';
      final results = await net.crawl.html<String>(markup).collect((res) {
        res.emit(res.parse(format.html).find('h2').text);
      });
      expect(results.list, equals(['Explicit HTML']));
    });

    test('net.crawl.file explicitly parses file path', () async {
      final tmpFile = File('${Directory.systemTemp.path}/test_crawl_file.html');
      await tmpFile.writeAsString('<section><p>File Content</p></section>');
      try {
        final results = await net.crawl.file<String>(tmpFile.path).collect((
          res,
        ) {
          res.emit(res.parse(format.html).find('p').text);
        });
        expect(results.list, equals(['File Content']));
      } finally {
        if (await tmpFile.exists()) await tmpFile.delete();
      }
    });

    test('res.follow accepts plain string, not necessary a Uri', () async {
      final items = <String>[];
      await net.crawl
          .html<String>('''
        <div>
          <a href="https://example.com/step2">Next</a>
          <p>Step 1</p>
        </div>
      ''')
          .downloader(
            MockDownloader<String>({
              'https://example.com/step2': '<p>Step 2 Finished</p>',
            }),
          )
          .collect((res) {
            items.add(res.parse(format.html).find('p').text);
            for (final next
                in res.parse(format.html).find('a').attrs('href').list) {
              // follow takes a String directly without needing .url
              res.follow(next);
            }
          });

      expect(items, equals(['Step 1', 'Step 2 Finished']));
    });

    test('flow accepts arbitrary string tasks', () async {
      final seen = <String>[];
      await net.crawl<String>('task:seed-alpha'.url).collect((res) {
        seen.add(res.body);
        if (res.body == 'task:seed-alpha') {
          res.follow('task:seed-beta');
        }
      });

      expect(seen, equals(['task:seed-alpha', 'task:seed-beta']));
    });

    test(
      'Engine.run() throws StateError on second run and keeps external downloader open',
      () async {
        final downloader = MapDownloader<String>({
          'https://example.com/1': 'page1',
        });
        final engine = Engine<String>(downloader: downloader);

        final stats1 = await engine.run(['https://example.com/1']);
        expect(stats1.completed, equals(1));

        expect(() => engine.run(['https://example.com/1']), throwsStateError);

        // Downloader was external, so it should still be open
        final res = await downloader.download(
          Fetch('https://example.com/1'.url),
        );
        expect(res.status, equals(200));
      },
    );

    test(
      'CrawlBuilder applies concurrency, delay, base, retries to supplied downloader',
      () {
        final downloader = MapDownloader<String>({});
        net
            .crawl<String>('https://example.com'.url)
            .downloader(downloader)
            .concurrent(8)
            .delay(const Duration(seconds: 9))
            .retry(7)
            .base('out')
            .engine();

        expect(downloader.concurrency, equals(8));
        expect(downloader.delay, equals(const Duration(seconds: 9)));
        expect(downloader.retries, equals(7));
        expect(downloader.base, equals('out'));
      },
    );

    test(
      'Deduplicator keys on method, url, tag, body hash, normalizes host & query params, and resumes',
      () {
        final dedupe = Deduplicator();

        // Normalization: host case & query parameter order
        expect(dedupe.add('https://EXAMPLE.COM/page?b=2&a=1'.url), isTrue);
        expect(dedupe.seen('https://example.com/page?a=1&b=2'.url), isTrue);
        expect(dedupe.add('https://example.com/page?a=1&b=2'.url), isFalse);

        // Distinct tags do not collide
        final reqList = Fetch<void>(
          'https://example.com/items'.url,
          tag: 'list',
        );
        final reqDetail = Fetch<void>(
          'https://example.com/items'.url,
          tag: 'detail',
        );
        expect(dedupe.track(reqList), isTrue);
        expect(dedupe.track(reqDetail), isTrue);
        expect(dedupe.tracked(reqList), isTrue);
        expect(dedupe.tracked(reqDetail), isTrue);

        // Distinct methods do not collide
        final reqGet = Fetch<void>(
          'https://example.com/api'.url,
          method: HttpMethod.get,
        );
        final reqPost1 = Fetch<void>(
          'https://example.com/api'.url,
          method: HttpMethod.post,
          body: const Body.text('body1'),
        );
        final reqPost2 = Fetch<void>(
          'https://example.com/api'.url,
          method: HttpMethod.post,
          body: const Body.text('body2'),
        );
        expect(dedupe.track(reqGet), isTrue);
        expect(dedupe.track(reqPost1), isTrue);
        expect(dedupe.track(reqPost2), isTrue);

        // Dedupe escape hatch
        final reqNoDedupe1 = Fetch<void>(
          'https://example.com/fresh'.url,
          dedupe: false,
        );
        final reqNoDedupe2 = Fetch<void>(
          'https://example.com/fresh'.url,
          dedupe: false,
        );
        expect(dedupe.track(reqNoDedupe1), isTrue);
        expect(dedupe.track(reqNoDedupe2), isTrue);

        // Serialization / resume
        final json = dedupe.toJson();
        final restored = Deduplicator.fromJson(json);
        expect(restored.seen('https://example.com/page?a=1&b=2'.url), isTrue);
        expect(restored.tracked(reqList), isTrue);
      },
    );

    test('Page.stop() throws StateError when response has no engine', () {
      final standalone = Page<String>(fetch: Fetch('https://example.com'.url));
      expect(() => standalone.stop(), throwsStateError);
      expect(() => standalone.emit('item'), throwsStateError);
      expect(
        () => standalone.follow('https://example.com/next'),
        throwsStateError,
      );
    });

    test('CrawlEvents and EngineEvents are additive', () async {
      final log = <String>[];
      final downloader = MapDownloader<String>({
        'https://example.com': 'content',
      });

      final builder = net
          .crawl<String>('https://example.com'.url)
          .downloader(downloader);
      builder.on.item((item) => log.add('item1:$item'));
      builder.on.item((item) => log.add('item2:$item'));
      builder.on.start(() => log.add('start1'));
      builder.on.start(() => log.add('start2'));

      await builder.collect((res) => res.emit('hello'));

      expect(
        log,
        containsAllInOrder(['start1', 'start2', 'item1:hello', 'item2:hello']),
      );
    });

    test('Engine buffers items emitted before first listener', () async {
      final engine = Engine<String>(
        downloader: MapDownloader<String>({'https://example.com': 'ok'}),
        process: (res) {
          res.emit('buffered-1');
          res.emit('buffered-2');
        },
      );

      // Run without listening to items yet
      await engine.run(['https://example.com']);

      // First listener receives buffered items
      final collected = await engine.items.toList();
      expect(collected, equals(['buffered-1', 'buffered-2']));
    });

    test('CrawlBuilder limit, depth, and scope rules', () async {
      final pages = {
        'https://example.com/root':
            '<a href="/child1">1</a><a href="https://other.com/ext">ext</a>',
        'https://example.com/child1': '<a href="/child2">2</a>',
        'https://example.com/child2': '<p>deep</p>',
        'https://other.com/ext': '<p>ext</p>',
      };

      // Depth limit = 1: root is 0, child1 is 1, child2 (depth 2) is dropped
      final visited = <String>[];
      await net
          .crawl<String>('https://example.com/root'.url)
          .downloader(MapDownloader<String>(pages))
          .samehost()
          .depth(1)
          .collect((res) {
            visited.add(res.url.path);
            for (final href
                in res.parse(format.html).find('a').attrs('href').list) {
              res.follow(href);
            }
          });

      expect(visited, equals(['/root', '/child1']));
      expect(visited.contains('/child2'), isFalse);
      expect(visited.contains('https://other.com/ext'), isFalse);
    });

    test('CrawlBuilder limit stops crawl at maximum pages', () async {
      final pages = {
        'https://example.com/1': '<a href="/2">2</a>',
        'https://example.com/2': '<a href="/3">3</a>',
        'https://example.com/3': '<a href="/4">4</a>',
      };

      final stats = await net
          .crawl<String>('https://example.com/1'.url)
          .downloader(MapDownloader<String>(pages))
          .limit(2)
          .run((res) {
            for (final href
                in res.parse(format.html).find('a').attrs('href').list) {
              res.follow(href);
            }
          });

      expect(stats.completed, equals(2));
      expect(stats.reason, contains('Limit of 2 pages reached'));
    });

    test('Robots parses RFC 9309 rules, delays, sitemaps, and tests paths', () {
      const robotsTxt = '''
User-agent: *
Disallow: /admin
Disallow: /private/
Allow: /private/public
Crawl-delay: 2.5
Sitemap: https://example.com/sitemap.xml

User-agent: Googlebot
Disallow: /no-google/
Allow: /
Crawl-delay: 0.5
''';

      final robots = Robots.parse(robotsTxt);
      expect(robots.sitemaps, equals(['https://example.com/sitemap.xml'.url]));
      expect(
        robots.delay(agent: 'Googlebot'),
        equals(const Duration(milliseconds: 500)),
      );
      expect(
        robots.delay(agent: 'OtherBot'),
        equals(const Duration(milliseconds: 2500)),
      );

      // Googlebot rules
      expect(
        robots.allowed('https://example.com/admin'.url, agent: 'Googlebot'),
        isTrue,
      );
      expect(
        robots.allowed(
          'https://example.com/no-google/page'.url,
          agent: 'Googlebot',
        ),
        isFalse,
      );

      // Default (*) rules
      expect(robots.allowed('https://example.com/blog'.url), isTrue);
      expect(robots.allowed('https://example.com/admin'.url), isFalse);
      expect(robots.allowed('https://example.com/admin/users'.url), isFalse);
      expect(robots.allowed('https://example.com/private/secret'.url), isFalse);
      // Specificity: Allow /private/public is longer than Disallow /private/, so Allow wins
      expect(robots.allowed('https://example.com/private/public'.url), isTrue);
    });

    test('Sitemap parses XML urlset, sitemapindex, and plain text', () {
      const xmlSitemap = '''<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>https://example.com/</loc>
  </url>
  <url>
    <loc><![CDATA[https://example.com/page2]]></loc>
  </url>
</urlset>''';

      final urls1 = Sitemap.parse(xmlSitemap);
      expect(
        urls1.list,
        equals(['https://example.com/'.url, 'https://example.com/page2'.url]),
      );
      expect(Sitemap.nested(xmlSitemap), isFalse);

      const xmlIndex = '''<?xml version="1.0" encoding="UTF-8"?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <sitemap>
    <loc>https://example.com/sub-sitemap.xml</loc>
  </sitemap>
</sitemapindex>''';

      final urls2 = Sitemap.parse(xmlIndex);
      expect(urls2.list, equals(['https://example.com/sub-sitemap.xml'.url]));
      expect(Sitemap.nested(xmlIndex), isTrue);

      const textSitemap = '''
# Comment
https://example.com/item1
https://example.com/item2
''';
      final urls3 = Sitemap.parse(textSitemap);
      expect(
        urls3.list,
        equals([
          'https://example.com/item1'.url,
          'https://example.com/item2'.url,
        ]),
      );
    });

    test(
      'Engine Frontier prioritizes higher priority fetches while preserving FIFO order',
      () {
        final downloader = MapDownloader<void>({});
        final engine = Engine<void>(downloader: downloader);

        engine.add(Fetch('https://example.com/low1'.url, priority: 1));
        engine.add(Fetch('https://example.com/high1'.url, priority: 10));
        engine.add(Fetch('https://example.com/low2'.url, priority: 1));
        engine.add(Fetch('https://example.com/high2'.url, priority: 10));
        engine.add(Fetch('https://example.com/medium'.url, priority: 5));

        expect(
          engine.serve()?.url.toString(),
          equals('https://example.com/high1'),
        );
        expect(
          engine.serve()?.url.toString(),
          equals('https://example.com/high2'),
        );
        expect(
          engine.serve()?.url.toString(),
          equals('https://example.com/medium'),
        );
        expect(
          engine.serve()?.url.toString(),
          equals('https://example.com/low1'),
        );
        expect(
          engine.serve()?.url.toString(),
          equals('https://example.com/low2'),
        );
        expect(engine.serve(), isNull);
      },
    );

    test(
      'Downloader perhost politeness rate limits per-host independently',
      () async {
        final responses = {
          'https://host-a.com/1': '<h1>A1</h1>',
          'https://host-a.com/2': '<h1>A2</h1>',
          'https://host-b.com/1': '<h1>B1</h1>',
        };

        final downloader = MapDownloader<String>(
          responses,
          concurrency: 3,
          delay: const Duration(milliseconds: 60),
          perhost: true,
        );

        final order = <String>[];

        await net
            .crawl<String>('https://host-a.com/1'.url)
            .downloader(downloader)
            .perhost()
            .delay(const Duration(milliseconds: 60))
            .collect((res) {
              order.add(res.url.toString());
              if (res.url.toString() == 'https://host-a.com/1') {
                res.follow('https://host-b.com/1');
                res.follow('https://host-a.com/2');
              }
            });

        // host-b.com/1 does not wait for host-a.com/1's delay, so host-b.com/1 finishes before host-a.com/2
        expect(order, contains('https://host-b.com/1'));
        expect(order, contains('https://host-a.com/2'));
        expect(
          order.indexOf('https://host-b.com/1'),
          lessThan(order.indexOf('https://host-a.com/2')),
        );
      },
    );
  });
}

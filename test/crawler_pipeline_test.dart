/// The crawl, rebuilt around standard Stream and idiomatic Dart APIs.
library;

import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

/// A transport over a map of URL to body. **This is the way to test a crawl**:
/// a function, not a subclass.
Send fixture(Map<String, String> pages, {List<Fetch>? sent}) => (fetch) async {
  sent?.add(fetch);
  if (fetch.url.scheme == 'data') {
    return Reply.text(fetch.url.data?.contentAsString() ?? '', fetch: fetch);
  }
  final body = pages['${fetch.url}'] ?? pages[fetch.url.path];
  return Reply.text(
    body ?? '<html><body>404 Not Found</body></html>',
    fetch: fetch,
    status: body == null ? 404 : 200,
  );
};

/// Every `href` on the page, as the next requests.
Iterable<Fetch> links(Reply res) =>
    parseHtml(res.body).$('a').attrs('href').map(res.follow);

void main() {
  group('the frontier', () {
    test(
      'a crawl follows links and dedupes what it has already seen',
      () async {
        final sent = <Fetch>[];
        final crawl = Http.crawl([Fetch('https://a.test/'.url)], links)
          ..using(
            fixture({
              'https://a.test/': '<a href="/b">b</a><a href="/c">c</a>',
              'https://a.test/b': '<a href="/c">c again</a>',
              'https://a.test/c': '<p>leaf</p>',
            }, sent: sent),
          );

        final urls = await crawl
            .map((res) => res.url.path)
            .toList();

        expect(urls, equals(['/', '/b', '/c']));
        expect(
          sent.length,
          equals(3),
          reason: '/c was queued twice, fetched once',
        );
        expect(crawl.stats.fetched, equals(3));
        expect(crawl.stats.failed, isZero);
      },
    );

    test(
      'dedupe normalises fragment, trailing slash, host case and query order',
      () async {
        final sent = <Fetch>[];
        final crawl = Http.crawl(
          [
            Fetch('https://EXAMPLE.com/page?b=2&a=1'.url),
            Fetch('https://example.com/page?a=1&b=2'.url),
            Fetch('https://example.com/other'.url),
            Fetch('https://example.com/other#section'.url),
            Fetch('https://example.com/other/'.url),
          ],
        )..using(fixture(const {}, sent: sent));

        await crawl.run();
        expect(sent.length, equals(2));
      },
    );

    test('method, tag and body are part of the key', () async {
      final sent = <Fetch>[];
      final url = 'https://example.com/api'.url;
      await (Http.crawl(
        [
          Fetch(url),
          Fetch(url, tag: 'list'),
          Fetch(url, tag: 'detail'),
          Fetch(url, method: HttpMethod.post, body: const Body.text('one')),
          Fetch(url, method: HttpMethod.post, body: const Body.text('two')),
        ],
      )..using(fixture(const {}, sent: sent))).run();

      expect(sent.length, equals(5));
    });

    test('dedupe: false is the escape hatch, per request', () async {
      final sent = <Fetch>[];
      await (Http.crawl(
        [
          Fetch('https://example.com/fresh'.url, dedupe: false),
          Fetch('https://example.com/fresh'.url, dedupe: false),
        ],
      )..using(fixture(const {}, sent: sent))).run();

      expect(sent.length, equals(2));
    });

    test('higher priority is served first, ties stay FIFO', () async {
      final sent = <Fetch>[];
      await (Http.crawl(
              [
                Fetch('https://example.com/low'.url),
                Fetch('https://example.com/high'.url, priority: 100),
                Fetch('https://example.com/mid'.url, priority: 50),
                Fetch('https://example.com/high2'.url, priority: 100),
              ],
            )
            ..concurrent(1)
            ..using(fixture(const {}, sent: sent)))
          .run();

      expect(
        sent.map((f) => f.url.path).toList(),
        equals(['/high', '/high2', '/mid', '/low']),
      );
    });

    test('concurrent workers terminate once the frontier drains', () async {
      // Guards the worker wake-up path: an idle worker must notice the run is
      // over instead of parking on a completer nobody completes.
      final crawl = Http.crawl([Fetch('https://site.test/1'.url)])
        ..concurrent(8)
        ..using(fixture(const {'https://site.test/1': '<p>only page</p>'}));

      await crawl.run();
      expect(crawl.stats.fetched, equals(1));
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('next is the router', () {
    test(
      'a switch on the tag carries stages, with meta between them',
      () async {
        final pages = {
          'https://music.test/album': '''
          <table id="songlist">
            <tr><td><a href="/song/1">Track 1</a></td></tr>
            <tr><td><a href="/song/2">Track 2</a></td></tr>
          </table>
        ''',
          'https://music.test/song/1':
              '<div><a href="/audio/t1.mp3">Download MP3</a></div>',
          'https://music.test/song/2':
              '<div><a href="/audio/t2.mp3">Download MP3</a></div>',
        };

        final crawl = Http.crawl(
          [Fetch('https://music.test/album'.url)],
          (res) => switch (res.fetch.tag) {
            null =>
              parseHtml(res.body)
                  .$('#songlist a')
                  .elements
                  .map(
                    (a) => res.follow(
                      a.attributes['href']!,
                      tag: 'song',
                      meta: [('name', a.text)],
                    ),
                  ),
            _ => const <Fetch>[],
          },
        )..using(fixture(pages));

        final visited = await crawl
            .where((res) => res.fetch.tag == 'song')
            .map(
              (res) =>
                  '${res.fetch.meta['name']}: '
                  '${parseHtml(res.body).$('a').attr('href')}',
            )
            .toList();

        expect(crawl.stats.fetched, equals(3));
        expect(
          visited,
          equals(['Track 1: /audio/t1.mp3', 'Track 2: /audio/t2.mp3']),
        );
      },
    );

    test('next is a pure function, testable with no crawl at all', () {
      final res = Reply.text(
        '<a href="/b">b</a><a href="/c">c</a>',
        fetch: Fetch('https://a.test/'.url),
      );

      expect(
        links(res).map((f) => f.url.toString()).toList(),
        equals(['https://a.test/b', 'https://a.test/c']),
      );
      expect(links(res).firstOrNull?.depth, equals(1));
      expect(
        links(res).firstOrNull?.headers['Referer'],
        equals('https://a.test/'),
      );
    });

    test(
      'follow takes a plain string and resolves it against the reply',
      () async {
        final crawl =
            Http.crawl(
              [Fetch('https://example.com/step1'.url)],
              links,
            )..using(
              fixture(const {
                'https://example.com/step1':
                    '<p>Step 1</p><a href="https://example.com/step2">Next</a>',
                'https://example.com/step2': '<p>Step 2 Finished</p>',
              }),
            );

        final texts = await crawl
            .map((res) => parseHtml(res.body).$('p').text)
            .toList();

        expect(texts, equals(['Step 1', 'Step 2 Finished']));
      },
    );
  });

  group('the terminals', () {
    test('nothing is fetched until something collects', () async {
      final sent = <Fetch>[];
      Http.crawl([Fetch('https://a.test/'.url)])
        ..using(fixture(const {'https://a.test/': 'x'}, sent: sent))
        ..flow;

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sent, isEmpty);
    });

    test('a terminal that stops early stops the crawl', () async {
      final sent = <Fetch>[];
      final crawl = Http.crawl([Fetch('https://a.test/'.url)], links)
        ..using(
          fixture(const {
            'https://a.test/': '<a href="/b">b</a><a href="/c">c</a>',
            'https://a.test/b': '<p>b</p>',
            'https://a.test/c': '<p>c</p>',
          }, sent: sent),
        )
        ..concurrent(1);

      final first = await crawl.first;
      expect(first.url.path, equals('/'));
      expect(sent.length, equals(1));
      expect(crawl.stats.reason, equals('Flow cancelled'));
    });

    test('take.when is what res.stop was', () async {
      final crawl =
          Http.crawl(
              [
                Fetch('https://example.com/item/1'.url),
                Fetch('https://example.com/item/2'.url),
                Fetch('https://example.com/item/3'.url),
              ],
            )
            ..concurrent(1)
            ..using(
              fixture(const {
                'https://example.com/item/1': '<div>Page 1</div>',
                'https://example.com/item/2': '<div>Page 2 (Abort)</div>',
                'https://example.com/item/3': '<div>Page 3</div>',
              }),
            );

      final texts = await crawl
          .map((res) => parseHtml(res.body).$('div').text)
          .takeWhile((text) => !text.contains('Abort'))
          .toList();

      // `takeWhile` stops *at* the element it rejects, which is what
      // `res.stop(reason)` meant minus the page that triggered it. Page 3 is
      // never fetched: cancelling the flow stops the crawl.
      expect(texts, equals(['Page 1']));
      expect(crawl.stats.fetched, lessThan(3));
      expect(crawl.stats.reason, equals('Flow cancelled'));
    });

    test('settle puts the failures in band; flow leaves them out', () async {
      Future<Reply> flaky(Fetch fetch) async {
        if (fetch.url.path == '/bad') throw StateError('handler blew up');
        return Reply.text('<p>ok</p>', fetch: fetch);
      }

      final outcomes =
          await (Http.crawl(
                  [
                    Fetch('https://a.test/good'.url),
                    Fetch('https://a.test/bad'.url),
                  ],
                )
                ..concurrent(1)
                ..using(flaky))
              .settle
              .toList();

      expect(outcomes.length, equals(2));
      expect(
        outcomes
            .whereType<Broke<Reply>>()
            .singleOrNull
            ?.error,
        isA<StateError>(),
      );

      final crawl =
          Http.crawl(
              [
                Fetch('https://a.test/good'.url),
                Fetch('https://a.test/bad'.url),
              ],
            )
            ..concurrent(1)
            ..using(flaky);
      final replies = await crawl.toList();
      expect(replies.length, equals(1));
      expect(crawl.stats.failed, equals(1));
    });

    test('run drains and reports; stats is a record', () async {
      final crawl = Http.crawl([Fetch('https://a.test/'.url)], links)
        ..using(
          fixture(const {
            'https://a.test/': '<a href="/b">b</a>',
            'https://a.test/b': '<p>b</p>',
          }),
        );

      final Stats stats = await crawl.run();
      expect(stats.fetched, equals(2));
      expect(stats.failed, isZero);
      expect(stats.skipped, isZero);
      expect(stats.bytes, greaterThan(0));
      expect(stats.reason, isNull);
    });

    test('gather is flat.map on the flow', () async {
      final crawl = Http.crawl([Fetch('https://news.test/'.url)])
        ..using(
          fixture(const {
            'https://news.test/': '''
              <h2 class="title">Article Alpha</h2>
              <h2 class="title">Article Beta</h2>
              <h2 class="title">Article Gamma</h2>
            ''',
          }),
        );

      final titles = await crawl
          .expand((res) => parseHtml(res.body).$('.title').texts)
          .toList();

      expect(
        titles,
        equals(['Article Alpha', 'Article Beta', 'Article Gamma']),
      );
    });
  });

  group('scope', () {
    test('depth and samehost bound the walk', () async {
      final crawl = Http.crawl([Fetch('https://example.com/root'.url)], links)
        ..using(
          fixture(const {
            'https://example.com/root':
                '<a href="/child1">1</a><a href="https://other.com/ext">ext</a>',
            'https://example.com/child1': '<a href="/child2">2</a>',
            'https://example.com/child2': '<p>deep</p>',
            'https://other.com/ext': '<p>ext</p>',
          }),
        )
        ..sameHost()
        ..depth(1);

      final visited = await crawl
          .map((res) => res.url.path)
          .toList();

      expect(visited, equals(['/root', '/child1']));
    });

    test('allow and deny filter by pattern', () async {
      final crawl = Http.crawl([Fetch('https://example.com/a'.url)], links)
        ..using(
          fixture(const {
            'https://example.com/a':
                '<a href="/keep/1">k</a><a href="/drop/1">d</a>',
            'https://example.com/keep/1': '<p>keep</p>',
            'https://example.com/drop/1': '<p>drop</p>',
          }),
        )
        ..deny(RegExp(r'/drop/'));

      final visited = await crawl
          .map((res) => res.url.path)
          .toList();
      expect(visited, equals(['/a', '/keep/1']));
    });

    test('limit stops the crawl at the maximum', () async {
      final crawl = Http.crawl([Fetch('https://example.com/1'.url)], links)
        ..using(
          fixture(const {
            'https://example.com/1': '<a href="/2">2</a>',
            'https://example.com/2': '<a href="/3">3</a>',
            'https://example.com/3': '<a href="/4">4</a>',
          }),
        )
        ..concurrent(1)
        ..limit(2);

      final stats = await crawl.run();
      expect(stats.fetched, equals(2));
      expect(stats.reason, contains('Limit of 2 pages reached'));
    });

    test(
      'accept sets the header and drops what arrives as something else',
      () async {
        final sent = <Fetch>[];
        final crawl =
            Http.crawl(
                [
                  Fetch('https://example.com/page'.url),
                  Fetch('https://example.com/doc.pdf'.url),
                ],
              )
              ..using((fetch) async {
                sent.add(fetch);
                return Reply.text(
                  'body',
                  fetch: fetch,
                  headers: fetch.url.path.endsWith('.pdf')
                      ? const {'content-type': 'application/pdf'}
                      : const {'content-type': 'text/html; charset=utf-8'},
                );
              })
              ..accept(const ['text/html']);

        final urls = await crawl
            .map((res) => res.url.path)
            .toList();

        expect(sent.length, equals(2), reason: 'both are fetched');
        expect(urls, equals(['/page']), reason: 'only one is handled');
        expect(crawl.stats.skipped, equals(1));
      },
    );

    test('perhost paces each host separately', () async {
      final order = <String>[];
      final crawl =
          Http.crawl(
              [Fetch('https://host-a.test/1'.url)],
              (res) => res.url.path == '/1'
                  ? [
                      res.follow('https://host-b.test/1'),
                      res.follow('https://host-a.test/2'),
                    ]
                  : const <Fetch>[],
            )
            ..using(
              fixture(const {
                'https://host-a.test/1': '<h1>A1</h1>',
                'https://host-a.test/2': '<h1>A2</h1>',
                'https://host-b.test/1': '<h1>B1</h1>',
              }),
            )
            ..concurrent(3)
            ..delay(const Duration(milliseconds: 60), perHost: true);

      await for (final res in crawl) {
        order.add(res.url.toString());
      }

      // host-b does not wait out host-a's delay.
      expect(
        order.indexOf('https://host-b.test/1'),
        lessThan(order.indexOf('https://host-a.test/2')),
      );
    });
  });

  group('seeds are just requests', () {
    test('several URLs at once', () async {
      final crawl =
          Http.crawl(
            [
              'https://site.test/a'.url,
              'https://site.test/b'.url,
            ].map(Fetch.new),
          )..using(
            fixture(const {
              'https://site.test/a': '<p>A</p>',
              'https://site.test/b': '<p>B</p>',
            }),
          );

      expect((await crawl.run()).fetched, equals(2));
    });

    test('fully-formed fetches carry their tags', () async {
      final crawl =
          Http.crawl(
              [
                Fetch('https://site.test/a'.url, tag: 'first'),
                Fetch('https://site.test/b'.url, tag: 'second'),
              ],
            )
            ..concurrent(1)
            ..using(
              fixture(const {
                'https://site.test/a': '<p>A</p>',
                'https://site.test/b': '<p>B</p>',
              }),
            );

      final tags = await crawl
          .map((res) => res.fetch.tag)
          .toList();
      expect(tags, equals(['first', 'second']));
    });

    test('raw markup, through coerce and the default transport', () async {
      const markup = '<article><h2>Explicit HTML</h2></article>';
      final crawl = Http.crawl([Fetch(coerce(markup))]);

      final titles = await crawl
          .map((res) => parseHtml(res.body).$('h2').text)
          .toList();
      expect(titles, equals(['Explicit HTML']));
    });

    test('a local file, through the default transport', () async {
      final file = File('${Directory.systemTemp.path}/test_crawl_file.html');
      await file.writeAsString('<section><p>File Content</p></section>');
      try {
        final crawl = Http.crawl([Fetch(Uri.file(file.path))]);
        final texts = await crawl
            .map((res) => parseHtml(res.body).$('p').text)
            .toList();
        expect(texts, equals(['File Content']));
      } finally {
        if (await file.exists()) await file.delete();
      }
    });

    test('an arbitrary string task', () async {
      final crawl = Http.crawl(
        [Fetch(coerce('task:seed-alpha'))],
        (res) => res.body == 'task:seed-alpha'
            ? [res.follow('task:seed-beta')]
            : const <Fetch>[],
      );

      final seen = await crawl
          .map((res) => res.body)
          .toList();
      expect(seen, equals(['task:seed-alpha', 'task:seed-beta']));
    });
  });

  group('a transport is a function', () {
    test('middleware wraps one, which had no spelling before', () async {
      final log = <String>[];
      Send logged(Send inner) => (fetch) async {
        final res = await inner(fetch);
        log.add('${res.status} ${fetch.url}');
        return res;
      };

      await (Http.crawl(
        [Fetch('https://a.test/'.url)],
      )..using(logged(fixture(const {'https://a.test/': 'ok'})))).run();

      expect(log, equals(['200 https://a.test/']));
    });

    test('a Fetcher is a Send', () {
      final Send send = Fetcher().call;
      expect(send, isNotNull);
    });

    test('obey reads robots.txt through the crawl own transport', () async {
      final sent = <Fetch>[];
      final crawl =
          Http.crawl(
              [
                Fetch('https://a.test/admin/secret'.url),
                Fetch('https://a.test/public'.url),
              ],
            )
            ..concurrent(1)
            ..using(
              fixture(const {
                'https://a.test/robots.txt':
                    'User-agent: *\nDisallow: /admin\n',
                'https://a.test/public': '<p>public</p>',
                'https://a.test/admin/secret': '<p>secret</p>',
              }, sent: sent),
            )
            ..obey();

      final urls = await crawl
          .map((res) => res.url.path)
          .toList();

      expect(urls, equals(['/public']));
      expect(crawl.stats.skipped, equals(1));
      // Fetched once, through the fixture, and cached per origin.
      expect(sent.where((f) => f.url.path == '/robots.txt').length, equals(1));
    });
  });

  group('robots and sitemaps are formats', () {
    test('format.robots parses RFC 9309 rules, delays and sitemaps', () {
      const text = '''
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

      final robots = parseRobots(text);
      expect(robots.sitemaps, equals(['https://example.com/sitemap.xml'.url]));
      expect(
        robots.delay(agent: 'Googlebot'),
        equals(const Duration(milliseconds: 500)),
      );
      expect(
        robots.delay(agent: 'OtherBot'),
        equals(const Duration(milliseconds: 2500)),
      );

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

      expect(robots.allowed('https://example.com/blog'.url), isTrue);
      expect(robots.allowed('https://example.com/admin'.url), isFalse);
      expect(robots.allowed('https://example.com/admin/users'.url), isFalse);
      expect(robots.allowed('https://example.com/private/secret'.url), isFalse);
      // Allow /private/public is longer than Disallow /private/, so it wins.
      expect(robots.allowed('https://example.com/private/public'.url), isTrue);
    });

    test('format.robots round-trips through format and parse', () {
      const text = 'User-agent: *\nDisallow: /admin\nCrawl-delay: 1.0\n';
      final once = parseRobots(text);
      final twice = parseRobots(once.render());
      expect(twice.allowed('https://x.test/admin'.url), isFalse);
      expect(twice.delay(), equals(const Duration(seconds: 1)));
    });

    test('format.sitemap reads urlset, sitemapindex and plain text', () {
      const urlset = '''<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://example.com/</loc></url>
  <url><loc><![CDATA[https://example.com/page2]]></loc></url>
</urlset>''';

      expect(
        parseSitemap(urlset),
        equals(['https://example.com/'.url, 'https://example.com/page2'.url]),
      );
      expect(const SitemapAccessor().nested(urlset), isFalse);

      const index = '''<?xml version="1.0" encoding="UTF-8"?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <sitemap><loc>https://example.com/sub-sitemap.xml</loc></sitemap>
</sitemapindex>''';

      expect(
        parseSitemap(index),
        equals(['https://example.com/sub-sitemap.xml'.url]),
      );
      expect(const SitemapAccessor().nested(index), isTrue);

      const text = '''
# Comment
https://example.com/item1
https://example.com/item2
''';
      expect(
        parseSitemap(text),
        equals([
          'https://example.com/item1'.url,
          'https://example.com/item2'.url,
        ]),
      );
    });

    test(
      'a sitemap index is a crawl, with depth and dedupe for free',
      () async {
        final crawl =
            Http.crawl(
                [Fetch('https://x.test/sitemap.xml'.url)],
                (res) =>
                    parseSitemap(res.body).map(Fetch.new),
              )
              ..using(
                fixture(const {
                  'https://x.test/sitemap.xml': '''
<sitemapindex><sitemap><loc>https://x.test/one.xml</loc></sitemap></sitemapindex>
''',
                  'https://x.test/one.xml': '''
<urlset><url><loc>https://x.test/a</loc></url></urlset>
''',
                  'https://x.test/a': '<p>a</p>',
                }),
              )
              ..depth(8);

        final urls = await crawl
            .map((res) => res.url.path)
            .toList();
        expect(urls, equals(['/sitemap.xml', '/one.xml', '/a']));
      },
    );
  });
}

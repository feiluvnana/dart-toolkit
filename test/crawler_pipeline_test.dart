import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

/// In-memory mock downloader for deterministic unit testing.
class MockDownloader<T> extends Downloader<T> {
  final Map<String, String> htmlResponses;

  MockDownloader(this.htmlResponses);

  @override
  Future<Response<T>> download(Object requestOrUrl) async {
    final Request<T> request = requestOrUrl is Request<T>
        ? requestOrUrl
        : Request<T>.get(requestOrUrl);
    final urlStr = request.url.toString();
    final body =
        htmlResponses[urlStr] ?? '<html><body>404 Not Found</body></html>';
    final statusCode = htmlResponses.containsKey(urlStr) ? 200 : 404;

    return Response<T>(
      request: request,
      status: statusCode,
      headers: {'content-type': 'text/html; charset=utf-8'},
      bytes: utf8.encode(body),
      engine: engine,
    );
  }

  @override
  Future<void> save(
    Object destination,
    Object source, {
    void Function(int received, int total)? onProgress,
    String part = '.part',
    bool match = true,
  }) async {
    final Request<T> req = destination is Request<T>
        ? destination
        : Request<T>.get(source);
    final dest = source is File
        ? source
        : File(destination.toString());
    final response = await download(req);
    await response.save(dest.path, null, part);
  }

  @override
  Future<void> close() async {}
}

void main() {
  group('Deduplicator & Queue Tests', () {
    test('Deduplicator tracks and deduplicates URLs with 1-word methods', () {
      final dedupe = Deduplicator();

      expect(dedupe.add('https://example.com/page1'), isTrue);
      expect(dedupe.add('https://example.com/page2'), isTrue);
      expect(
        dedupe.add('https://example.com/page1#section'),
        isFalse,
      ); // Deduplicated!

      expect(dedupe.has('https://example.com/page1'), isTrue);
      expect(dedupe.has('https://example.com/page3'), isFalse);
      expect(dedupe.length, equals(2));

      dedupe.clear();
      expect(dedupe.isEmpty, isTrue);
      expect(dedupe.has('https://example.com/page1'), isFalse);
    });

    test('Engine serves requests to downloader and manages queue', () {
      final engine = Engine<String>();

      engine.add('https://example.com/page1');
      engine.add('https://example.com/page2');
      engine.add('https://example.com/page1#section'); // deduplicated!

      expect(engine.queue.length, equals(2));
      expect(engine.queue.isNotEmpty, isTrue);

      final req1 = engine.serve();
      expect(req1?.url.path, equals('/page1'));
      final req2 = engine.serve();
      expect(req2?.url.path, equals('/page2'));
      expect(engine.serve(), isNull);
      expect(engine.queue.isEmpty, isTrue);
    });
  });

  group('Engine Pipeline & Processor Tests', () {
    test(
      'Engine runs pipeline with namespaced queue and concise 1-word methods',
      () async {
        final mockData = {
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

        final downloader = MockDownloader<Map<String, Object?>>(mockData);
        final router = Router<Map<String, Object?>>();

        // 1. Root album page route with 1-word .on()
        router.on(RegExp(r'/album$'), (response, engine) {
          expect(response.engine, equals(engine));
          expect(response.ok, isTrue);

          // Use jQuery-like $() to find disc links and follow them
          for (final a in response.$('a.disc-link')) {
            final href = a.attributes['href'];
            if (href != null) {
              response.follow(href, tag: 'disc_page');
            }
          }
        });

        // 2. Disc pages route matching tag with 1-word .tag()
        router.tag('disc_page', (response, engine) {
          final discNum = int.parse(
            response.$('.disc').attr('data-num') ?? '0',
          );
          final discTitle = response.$('.disc-title').text;
          final track = response.$('.track').text;

          // 1-word emit
          response.emit({
            'disc': discNum,
            'title': discTitle,
            'firstTrack': track,
          });
        });

        final engine = Engine<Map<String, Object?>>(
          downloader: downloader,
          processor: router,
        );

        // Verify all components have engine reference
        expect(downloader.engine, equals(engine));
        expect(router.engine, equals(engine));

        // 1-word .add() schedule
        engine.add('https://example.com/album');

        final emittedItems = <Map<String, Object?>>[];
        engine.items.listen((item) {
          emittedItems.add(item);
        });

        final stats = await engine.run();

        expect(stats.completed, equals(3));
        expect(stats.emitted, equals(2));
        expect(emittedItems.length, equals(2));

        expect(emittedItems[0]['disc'], equals(1));
        expect(emittedItems[0]['title'], equals('Key+Lia Best 2001'));
        expect(emittedItems[0]['firstTrack'], equals('01. Natukage'));

        expect(emittedItems[1]['disc'], equals(2));
        expect(emittedItems[1]['title'], equals('Kanon Original Soundtrack'));
        expect(emittedItems[1]['firstTrack'], equals('01. Morning Shadows'));
      },
    );

    test(
      'Response processor can abort pipeline early with 1-word method',
      () async {
        final mockData = {
          'https://example.com/item/1': '<div>Page 1</div>',
          'https://example.com/item/2': '<div>Page 2 (Abort)</div>',
          'https://example.com/item/3': '<div>Page 3</div>',
        };

        final downloader = MockDownloader<String>(mockData);

        final engine = Engine<String>(
          downloader: downloader,
          onResponse: (response, engine) {
            final text = response.$('div').text;
            response.emit(text);
            if (text.contains('Abort')) {
              response.stop('Found abort keyword');
            }
          },
        );

        engine.add('https://example.com/item/1');
        engine.add('https://example.com/item/2');
        engine.add('https://example.com/item/3');

        final items = <String>[];
        engine.items.listen(items.add);

        final stats = await engine.run();

        expect(engine.stopped, isTrue);
        expect(stats.reason, equals('Found abort keyword'));
        expect(items, contains('Page 1'));
        expect(items, contains('Page 2 (Abort)'));
        expect(items, isNot(contains('Page 3')));
      },
    );

    test('crawl.run executes multi-step follow with tags and meta', () async {
      final mockData = {
        'https://music.example.com/album': '''
          <table id="songlist">
            <tr><td><a href="/song/1">Track 1</a></td></tr>
            <tr><td><a href="/song/2">Track 2</a></td></tr>
          </table>
        ''',
        'https://music.example.com/song/1': '''
          <div>
            <a href="/audio/t1.mp3">Download MP3</a>
          </div>
        ''',
        'https://music.example.com/song/2': '''
          <div>
            <a href="/audio/t2.mp3">Download MP3</a>
          </div>
        ''',
      };

      final dl = MockDownloader<String>(mockData);
      final visitedSongs = <String>[];

      final stats = await net.crawl.run('https://music.example.com/album', (res) {
        if (res.tag == 'song') {
          final trackName = res.meta['name'] as String;
          final mp3Link = res.link('.mp3');
          visitedSongs.add('$trackName: $mp3Link');
        } else {
          for (final a in res.$('#songlist a')) {
            final href = a.attr('href')!;
            final name = a.text;
            res.follow(href, tag: 'song', meta: {'name': name});
          }
        }
      }, downloader: dl);

      expect(stats.completed, equals(3));
      expect(
        visitedSongs,
        equals([
          'Track 1: https://music.example.com/audio/t1.mp3',
          'Track 2: https://music.example.com/audio/t2.mp3',
        ]),
      );
    });

    test('crawl.collect gathers all emitted items in one call', () async {
      final mockData = {
        'https://news.example.com': '''
          <div class="articles">
            <h2 class="title">Article Alpha</h2>
            <h2 class="title">Article Beta</h2>
            <h2 class="title">Article Gamma</h2>
          </div>
        ''',
      };

      final dl = MockDownloader<String>(mockData);

      final titles = await net.crawl.collect<String>('https://news.example.com', (
        res,
      ) {
        for (final t in res.$('.title').texts) {
          res.emit(t);
        }
      }, downloader: dl);

      expect(
        titles,
        equals(['Article Alpha', 'Article Beta', 'Article Gamma']),
      );
    });

    test('crawl.engine supports direct .tag and .route registration', () async {
      final mockData = {
        'https://shop.example.com/catalog': '''
          <a href="/item/100" class="item">Item 100</a>
        ''',
        'https://shop.example.com/item/100': '''
          <h1 class="name">Super Gadget</h1>
        ''',
      };

      final dl = MockDownloader<String>(mockData);
      final eng = net.crawl.engine<String>(downloader: dl);
      final results = <String>[];

      eng.route(RegExp(r'/catalog$'), (res) {
        for (final a in res.$('a.item')) {
          res.follow(a.attr('href')!, tag: 'item');
        }
      });

      eng.tag('item', (res) {
        results.add(res.$('h1.name').text);
      });

      final stats = await eng.run(['https://shop.example.com/catalog']);
      expect(stats.completed, equals(2));
      expect(results, equals(['Super Gadget']));
    });

    test(
      'crawl(...) builder pattern works with single process function',
      () async {
        final mockData = {
          'https://site.example.com':
              '<h1>Hello World</h1><a href="/sub">Sub</a>',
          'https://site.example.com/sub': '<h2>Subpage</h2>',
        };
        final dl = MockDownloader<String>(mockData);
        final titles = <String>[];

        final stats = await net.crawl<String>('https://site.example.com')
            .concurrent(2)
            .delay(Duration(milliseconds: 10))
            .downloader(dl)
            .run((res) {
              if (res.url.path == '/sub') {
                titles.add(res.$('h2').text);
              } else {
                titles.add(res.$('h1').text);
                res.follow('/sub');
              }
            });

        expect(stats.completed, equals(2));
        expect(titles, equals(['Hello World', 'Subpage']));
      },
    );

    test('crawl(...) builder pattern works with multi-stage tags', () async {
      final mockData = {
        'https://site.example.com': '<h1>Root</h1><a href="/item1">Item 1</a><a href="/item2">Item 2</a>',
        'https://site.example.com/item1': '<span>Item One</span>',
        'https://site.example.com/item2': '<span>Item Two</span>',
      };
      final dl = MockDownloader<String>(mockData);
      final items = <String>[];

      final stats = await net.crawl<String>('https://site.example.com')
          .concurrent(2)
          .downloader(dl)
          .tag('item', (res) {
            items.add(res.$('span').text);
          })
          .run((res) {
            for (final a in res.$('a')) {
              res.follow(a.attr('href')!, tag: 'item');
            }
          });

      expect(stats.completed, equals(3));
      expect(items, equals(['Item One', 'Item Two']));
    });

    test('crawl(...) builder supports .collect with process-only argument', () async {
      final mockData = {
        'https://site.example.com': '<span>Alpha</span><span>Beta</span>',
      };
      final dl = MockDownloader<String>(mockData);

      final collected = await net.crawl<String>('https://site.example.com')
          .concurrent(2)
          .downloader(dl)
          .collect<String>((res) {
            for (final span in res.$('span').texts) {
              res.emit(span);
            }
          });

      expect(collected, equals(['Alpha', 'Beta']));
    });
  });
}

/// Tests for a crawl that survives being interrupted. Each group names the
/// behaviour that used to be impossible: the frontier was in memory only, so
/// anything a run had not yet fetched died with the process.
///
/// In 6.0.0 `Snapshot`, `Stats` and `Deduplicator` are gone as public types —
/// the saved position is JSON off [Crawl.position], and the counters are a
/// record.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

/// A transport that serves fixtures and stops the crawl partway, so a test
/// can see what a half-finished run leaves behind.
Send halfway(Map<String, String> pages, int after, Crawl Function() crawl) {
  var served = 0;
  return (fetch) async {
    served++;
    if (served > after) crawl().stop('halfway');
    return Reply.text(pages['${fetch.url}'] ?? '', fetch: fetch);
  };
}

Send serve(Map<String, String> pages) =>
    (fetch) async => Reply.text(pages['${fetch.url}'] ?? '', fetch: fetch);

Iterable<Fetch> links(Reply res) =>
    res.parse(format.html).$('a').attrs('href').transform(.map(res.follow));

String tempPath(String name) =>
    '${Directory.systemTemp.createTempSync('dt_resume_').path}/$name';

const _widget = Slot<String>('name');
const _index = Slot<int>('index');

void main() {
  group('Fetch serialization', () {
    test('every field scheduling depends on round-trips', () {
      final fetch = Fetch(
        Uri.parse('https://example.com/search?q=a'),
        method: HttpMethod.post,
        headers: {'X-Token': 'abc'},
        body: Body.form({'page': '2'}),
        priority: 7,
        tag: 'detail',
        meta: [_widget('Widget'), _index(3)],
        dedupe: false,
        depth: 2,
      );

      final copy = Fetch.fromJson(
        jsonDecode(jsonEncode(fetch.toJson())) as Map<String, Object?>,
      );

      expect(copy.url, fetch.url);
      expect(copy.method, HttpMethod.post);
      expect(copy.headers, {'X-Token': 'abc'});
      expect(copy.body!.toJson(), {
        'kind': 'form',
        'fields': {'page': '2'},
      });
      expect(copy.priority, 7);
      expect(copy.tag, 'detail');
      // Through the slots, which is the point: the values come back typed
      // rather than as Object? out of a map.
      expect(copy.meta.read(_widget), 'Widget');
      expect(copy.meta.read(_index), 3);
      expect(copy.meta, {'name': 'Widget', 'index': 3});
      expect(copy.dedupe, isFalse);
      expect(copy.depth, 2);
    });

    test('a GET with nothing set serializes to just its url', () {
      final json = Fetch(Uri.parse('https://example.com/')).toJson();
      expect(json.keys, ['url']);
    });

    test('every body shape survives the trip', () {
      // The four shapes are private now — `Body.text`, `.bytes`, `.form` and
      // `.json` are the whole surface — so the round trip is asserted on the
      // wire form rather than on a class nobody can name.
      Map<String, Object?> round(Body body) => Body.fromJson(
        jsonDecode(jsonEncode(body.toJson())) as Map<String, Object?>,
      ).toJson();

      expect(round(Body.text('hi')), {'kind': 'text', 'text': 'hi'});
      // Base64, so bytes that are not valid UTF-8 come back intact.
      expect(
        round(Body.bytes([0, 255, 12]))['data'],
        base64Encode([0, 255, 12]),
      );
      expect(Body.fromJson(round(Body.bytes([0, 255, 12]))).bytes(), [
        0,
        255,
        12,
      ]);
      expect(round(Body.form({'a': 'b'})), {
        'kind': 'form',
        'fields': {'a': 'b'},
      });
      expect(round(Body.json({'n': 1})), {
        'kind': 'json',
        'data': {'n': 1},
      });
    });

    test('an unknown body kind is refused, not guessed at', () {
      expect(() => Body.fromJson({'kind': 'protobuf'}), throwsFormatException);
    });
  });

  group('Crawl.position', () {
    test('holds the frontier, the visited set and the counters', () async {
      final crawl = net.crawl(
        [
          Fetch(Uri.parse('https://example.com/a')),
          Fetch(Uri.parse('https://example.com/b')),
        ].seq,
      )..using(serve(const {}));

      await crawl.run();
      final position = crawl.position;

      expect(position['version'], Crawl.version);
      expect(position['pending'], isEmpty);
      expect((position['seen'] as List), hasLength(2));
      expect((position['stats'] as Map)['fetched'], 2);
    });

    test('a request that was never handled stays pending', () async {
      final path = tempPath('crawl.state');
      addTearDown(
        () => Directory(io.path.dirname(path)).deleteSync(recursive: true),
      );

      late Crawl crawl;
      crawl = net.crawl([Fetch('https://example.com/1'.url)].seq, links)
        ..concurrent(1)
        ..resume(path)
        ..using(
          halfway(
            const {
              'https://example.com/1':
                  '<a href="/2">2</a><a href="/3">3</a><a href="/4">4</a>',
            },
            1,
            () => crawl,
          ),
        );

      await crawl.run();

      // Pending is what the run had not finished, which is exactly what a
      // resumed crawl has to pick up.
      final pending = (crawl.position['pending'] as List)
          .cast<Map<String, Object?>>();
      expect(
        pending.map((r) => r['url']),
        containsAll(<String>[
          'https://example.com/2',
          'https://example.com/3',
          'https://example.com/4',
        ]),
      );
    });

    test('restore queues pending work past the visited set that saw it', () {
      const url = 'https://example.com/a';
      final crawl = net.crawl(const <Fetch>[])
        ..restore({
          'version': Crawl.version,
          'pending': [
            {'url': url},
          ],
          'seen': ['GET|$url||'],
        });

      // Routing it through the scope checks would have dropped it as a
      // duplicate, which is exactly the request the last run had not
      // finished.
      expect((crawl.position['pending'] as List), hasLength(1));
    });

    test('restore brings the counters back', () {
      final crawl = net.crawl(const <Fetch>[])
        ..restore({
          'stats': {'fetched': 40, 'scheduled': 40},
        });
      expect(crawl.stats.fetched, 40);
    });

    test('a position from a newer version is refused', () {
      expect(
        () => net.crawl(const <Fetch>[]).restore({
          'version': Crawl.version + 1,
        }),
        throwsFormatException,
      );
    });

    test('a started crawl refuses to be restored', () async {
      final crawl = net.crawl([Fetch('https://example.com/a'.url)].seq)
        ..using(serve(const {'https://example.com/a': '<h1>a</h1>'}));
      await crawl.run();
      expect(() => crawl.restore(const {}), throwsStateError);
    });
  });

  group('net.crawl().resume', () {
    test('an interrupted crawl leaves its unfetched queue on disk', () async {
      final path = tempPath('crawl.state');
      addTearDown(
        () => Directory(io.path.dirname(path)).deleteSync(recursive: true),
      );

      late Crawl crawl;
      crawl = net.crawl([Fetch('https://example.com/1'.url)].seq, links)
        ..concurrent(1)
        ..resume(path)
        ..using(
          halfway(
            const {
              'https://example.com/1':
                  '<a href="/2">2</a><a href="/3">3</a><a href="/4">4</a>',
            },
            1,
            () => crawl,
          ),
        );

      final stats = await crawl.run();

      expect(stats.reason, 'halfway');
      expect(File(path).existsSync(), isTrue);

      final saved = jsonDecode(File(path).readAsStringSync()) as Map;
      final pending = (saved['pending'] as List).cast<Map<String, Object?>>();
      expect(pending, isNotEmpty);
      expect(
        pending.map((r) => r['url']),
        containsAll(<String>[
          'https://example.com/2',
          'https://example.com/3',
          'https://example.com/4',
        ]),
      );
    });

    test('a second run fetches what the first one did not', () async {
      final path = tempPath('crawl.state');
      addTearDown(
        () => Directory(io.path.dirname(path)).deleteSync(recursive: true),
      );

      const pages = {
        'https://example.com/1': '<a href="/2">2</a><a href="/3">3</a>',
        'https://example.com/2': '<p>two</p>',
        'https://example.com/3': '<p>three</p>',
      };

      late Crawl one;
      one = net.crawl([Fetch('https://example.com/1'.url)].seq, links)
        ..concurrent(1)
        ..resume(path)
        ..using(halfway(pages, 1, () => one));

      final first = await one.flow
          .through(.map((res) => res.url.toString()))
          .collect(.list());
      expect(first, ['https://example.com/1']);

      final two = net.crawl([Fetch('https://example.com/1'.url)].seq, links)
        ..resume(path)
        ..using(serve(pages));

      final second = await two.flow
          .through(.map((res) => res.url.toString()))
          .collect(.list());

      // The seed is not fetched again, and the pages the first leg queued but
      // never reached are.
      expect(
        second,
        unorderedEquals(<String>[
          'https://example.com/2',
          'https://example.com/3',
        ]),
      );
      // Drained on its own, so there is nothing left to resume from.
      expect(File(path).existsSync(), isFalse);
    });

    test('limit counts the whole crawl, not each leg of it', () async {
      final path = tempPath('crawl.state');
      addTearDown(
        () => Directory(io.path.dirname(path)).deleteSync(recursive: true),
      );

      const pages = {
        'https://example.com/1': '<a href="/2">2</a><a href="/3">3</a>',
        'https://example.com/2': '<a href="/4">4</a>',
        'https://example.com/3': '<p>three</p>',
        'https://example.com/4': '<p>four</p>',
      };

      late Crawl one;
      one = net.crawl([Fetch('https://example.com/1'.url)].seq, links)
        ..concurrent(1)
        ..resume(path)
        ..limit(2)
        ..using(halfway(pages, 1, () => one));
      final first = await one.run();
      expect(first.fetched, 1);

      final two = net.crawl([Fetch('https://example.com/1'.url)].seq, links)
        ..concurrent(1)
        ..resume(path)
        ..limit(2)
        ..using(serve(pages));
      final second = await two.run();
      // Two pages across both runs, not two more.
      expect(second.fetched, 2);
    });

    test('a corrupt resume file throws instead of starting over', () async {
      final path = tempPath('crawl.state');
      addTearDown(
        () => Directory(io.path.dirname(path)).deleteSync(recursive: true),
      );
      File(path).writeAsStringSync('{not json');

      final crawl = net.crawl([Fetch('https://example.com/1'.url)].seq)
        ..resume(path)
        ..using(serve(const {}));

      expect(crawl.run(), throwsFormatException);
    });

    test(
      'a finished crawl leaves no watcher holding the process open',
      () async {
        final path = tempPath('crawl.state');
        addTearDown(
          () => Directory(io.path.dirname(path)).deleteSync(recursive: true),
        );

        await (net.crawl([Fetch('https://example.com/1'.url)].seq)
              ..resume(path)
              ..using(serve(const {'https://example.com/1': '<p>one</p>'})))
            .run();

        // The exit hook that flushes the position has to come off again: it
        // keeps the signal watcher, and so the isolate, alive.
        expect(File(path).existsSync(), isFalse);
      },
    );
  });
}

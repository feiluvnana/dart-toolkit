/// Tests for a crawl that survives being interrupted. Each group names the
/// behaviour that used to be impossible: the frontier was in memory only, so
/// anything a run had not yet fetched died with the process.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

/// A downloader that serves fixtures and stops the run partway, so a test can
/// see what a half-finished crawl leaves behind.
class _HalfwayDownloader extends Downloader<String> {
  _HalfwayDownloader(this.pages, this.after) : super(concurrency: 1);

  final Map<String, String> pages;
  final int after;
  int served = 0;

  @override
  Future<Page<String>> download(Fetch<String> fetch) async {
    served++;
    if (served > after) engine?.stop('halfway');
    return Page<String>(
      fetch: fetch,
      status: 200,
      headers: const {'content-type': 'text/html'},
      bytes: utf8.encode(pages[fetch.url.toString()] ?? ''),
      engine: engine,
    );
  }
}

String _tempPath(String name) =>
    '${Directory.systemTemp.createTempSync('dt_resume_').path}/$name';

const _widget = Slot<String>('name');
const _index = Slot<int>('index');

void main() {
  group('Fetch serialization', () {
    test('every field routing depends on round-trips', () {
      final fetch = Fetch<String>(
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

      final copy = Fetch<String>.fromJson(
        jsonDecode(jsonEncode(fetch.toJson())) as Map<String, Object?>,
      );

      expect(copy.url, fetch.url);
      expect(copy.method, HttpMethod.post);
      expect(copy.headers, {'X-Token': 'abc'});
      expect(copy.body, isA<FormBody>());
      expect((copy.body! as FormBody).fields, {'page': '2'});
      expect(copy.priority, 7);
      expect(copy.tag, 'detail');
      // Through the slots, which is the point: the values come back typed
      // rather than as Object? out of a map.
      expect(copy.meta.read(_widget), 'Widget');
      expect(copy.meta.read(_index), 3);
      expect(copy.meta.map, {'name': 'Widget', 'index': 3});
      expect(copy.dedupe, isFalse);
      expect(copy.depth, 2);
    });

    test('a GET with nothing set serializes to just its url', () {
      final json = Fetch<String>(Uri.parse('https://example.com/')).toJson();
      expect(json.keys, ['url']);
    });

    test('every body shape survives the trip', () {
      Body round(Body body) => Body.fromJson(
        jsonDecode(jsonEncode(body.toJson())) as Map<String, Object?>,
      );

      expect((round(Body.text('hi')) as TextBody).text, 'hi');
      // Base64, so bytes that are not valid UTF-8 come back intact.
      expect((round(Body.bytes([0, 255, 12])) as BytesBody).data, [0, 255, 12]);
      expect((round(Body.form({'a': 'b'})) as FormBody).fields, {'a': 'b'});
      expect((round(Body.json({'n': 1})) as JsonBody).data, {'n': 1});
    });

    test('an unknown body kind is refused, not guessed at', () {
      expect(() => Body.fromJson({'kind': 'protobuf'}), throwsFormatException);
    });
  });

  group('Engine.snapshot', () {
    test('holds the queue, the visited set and the counters', () {
      final engine = Engine<String>(downloader: MapDownloader<String>({}));
      engine
        ..add(Fetch<String>(Uri.parse('https://example.com/a')))
        ..add(Fetch<String>(Uri.parse('https://example.com/b')));

      final snapshot = engine.snapshot();

      expect(snapshot.pending, hasLength(2));
      expect(snapshot.deduplicator.length, 2);
      expect(snapshot.stats.scheduled, 2);
    });

    test('a fetch in flight counts as pending, not as done', () async {
      final engine = Engine<String>(downloader: MapDownloader<String>({}));
      engine.add(Fetch<String>(Uri.parse('https://example.com/a')));

      // Served, but never handled: the shape of a crawl killed mid-fetch.
      final served = engine.serve();
      expect(served, isNotNull);
      expect(engine.queue.isEmpty, isTrue);

      // It used to vanish here, so a resumed crawl silently skipped the page.
      expect(engine.snapshot().pending, hasLength(1));

      // Settling the worker is not finishing the page. Only a handled
      // response is done, which is what keeps a fetch that arrived after the
      // run stopped from being counted as crawled.
      engine.leave();
      expect(engine.snapshot().pending, hasLength(1));

      await engine.process(Page<String>(fetch: served!, engine: engine));
      expect(engine.snapshot().pending, isEmpty);
    });

    test('a page robots.txt refused is settled, not left pending', () {
      final engine = Engine<String>(downloader: MapDownloader<String>({}));
      engine.add(Fetch<String>(Uri.parse('https://example.com/a')));
      final served = engine.serve();

      engine.skip(served);
      expect(engine.snapshot().pending, isEmpty);
      expect(engine.stats.skipped, 1);
    });

    test('the snapshot is a copy, so a later fetch cannot rewrite it', () {
      final engine = Engine<String>(downloader: MapDownloader<String>({}));
      engine.add(Fetch<String>(Uri.parse('https://example.com/a')));
      final snapshot = engine.snapshot();

      engine.add(Fetch<String>(Uri.parse('https://example.com/b')));

      expect(snapshot.pending, hasLength(1));
      expect(snapshot.deduplicator.length, 1);
      expect(snapshot.stats.scheduled, 1);
    });

    test('round-trips through JSON', () {
      final engine = Engine<String>(downloader: MapDownloader<String>({}));
      engine.add(
        Fetch<String>(Uri.parse('https://example.com/a'), tag: 'listing'),
      );

      final copy = Snapshot<String>.fromJson(
        jsonDecode(jsonEncode(engine.snapshot().toJson()))
            as Map<String, Object?>,
      );

      expect(copy.pending.single.tag, 'listing');
      expect(copy.pending.single.url.path, '/a');
      expect(copy.deduplicator.length, 1);
    });

    test('a snapshot from a newer version is refused', () {
      expect(
        () => Snapshot<String>.fromJson({'version': Snapshot.version + 1}),
        throwsFormatException,
      );
    });
  });

  group('Engine.restore', () {
    test('queues pending work past the deduplicator that already saw it', () {
      final url = Uri.parse('https://example.com/a');
      final dedupe = Deduplicator()..add(url);
      final snapshot = Snapshot<String>(
        pending: [Fetch<String>(url)],
        deduplicator: dedupe,
      );

      final engine = Engine<String>(downloader: MapDownloader<String>({}));
      engine.restore(snapshot);

      // Routing it through add() would have dropped it as a duplicate, which
      // is exactly the request the last run had not finished.
      expect(engine.queue.length, 1);
    });

    test('brings the counters back so limit still spans the whole crawl', () {
      final snapshot = Snapshot<String>(
        stats: Stats()
          ..scheduled = 40
          ..completed = 40,
      );

      final engine = Engine<String>(downloader: MapDownloader<String>({}));
      engine.restore(snapshot);

      expect(engine.stats.completed, 40);
      expect(engine.stats.scheduled, 40);
    });

    test('a seed already visited is dropped rather than fetched twice', () {
      final url = Uri.parse('https://example.com/a');
      final engine = Engine<String>(downloader: MapDownloader<String>({}));
      engine.restore(Snapshot<String>(deduplicator: Deduplicator()..add(url)));

      engine.add(Fetch<String>(url));
      expect(engine.queue.isEmpty, isTrue);
    });

    test('a running engine refuses to be restored', () async {
      final engine = Engine<String>(
        downloader: MapDownloader<String>({'/a': '<h1>a</h1>'}),
      );
      final run = engine.run(['https://example.com/a']);
      expect(() => engine.restore(Snapshot<String>()), throwsStateError);
      await run;
      expect(() => engine.restore(Snapshot<String>()), throwsStateError);
    });
  });

  group('net.crawl().resume', () {
    test('an interrupted crawl leaves its unfetched queue on disk', () async {
      final path = _tempPath('crawl.state');
      addTearDown(
        () => Directory(io.path.dirname(path)).deleteSync(recursive: true),
      );

      final stats = await net
          .crawl<String>('https://example.com/1'.url)
          .downloader(
            _HalfwayDownloader({
              'https://example.com/1':
                  '<a href="/2">2</a><a href="/3">3</a><a href="/4">4</a>',
            }, 1),
          )
          .resume(path)
          .run((res) {
            for (final href
                in res
                    .parse(format.html)
                    .find('a')
                    .attrs('href')
                    .collect(.list())) {
              res.follow(href);
            }
          });

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
      final path = _tempPath('crawl.state');
      addTearDown(
        () => Directory(io.path.dirname(path)).deleteSync(recursive: true),
      );

      const pages = {
        'https://example.com/1': '<a href="/2">2</a><a href="/3">3</a>',
        'https://example.com/2': '<p>two</p>',
        'https://example.com/3': '<p>three</p>',
      };

      final first = await net
          .crawl<String>('https://example.com/1'.url)
          .downloader(_HalfwayDownloader(pages, 1))
          .resume(path)
          .items((res) {
            res.emit(res.url.toString());
            for (final href
                in res
                    .parse(format.html)
                    .find('a')
                    .attrs('href')
                    .collect(.list())) {
              res.follow(href);
            }
          });

      expect(first.collect(.list()), ['https://example.com/1']);

      final second = await net
          .crawl<String>('https://example.com/1'.url)
          .downloader(MapDownloader<String>(pages))
          .resume(path)
          .items((res) {
            res.emit(res.url.toString());
            for (final href
                in res
                    .parse(format.html)
                    .find('a')
                    .attrs('href')
                    .collect(.list())) {
              res.follow(href);
            }
          });

      // The seed is not fetched again, and the pages the first leg queued but
      // never reached are.
      expect(
        second.collect(.list()),
        unorderedEquals(<String>[
          'https://example.com/2',
          'https://example.com/3',
        ]),
      );
      // Drained on its own, so there is nothing left to resume from.
      expect(File(path).existsSync(), isFalse);
    });

    test('limit counts the whole crawl, not each leg of it', () async {
      final path = _tempPath('crawl.state');
      addTearDown(
        () => Directory(io.path.dirname(path)).deleteSync(recursive: true),
      );

      const pages = {
        'https://example.com/1': '<a href="/2">2</a><a href="/3">3</a>',
        'https://example.com/2': '<a href="/4">4</a>',
        'https://example.com/3': '<p>three</p>',
        'https://example.com/4': '<p>four</p>',
      };

      Future<Stats> leg(Downloader<String> downloader) => net
          .crawl<String>('https://example.com/1'.url)
          .downloader(downloader)
          .resume(path)
          .limit(2)
          .run((res) {
            for (final href
                in res
                    .parse(format.html)
                    .find('a')
                    .attrs('href')
                    .collect(.list())) {
              res.follow(href);
            }
          });

      final first = await leg(_HalfwayDownloader(pages, 1));
      expect(first.completed, 1);

      final second = await leg(MapDownloader<String>(pages));
      // Two pages across both runs, not two more.
      expect(second.completed, 2);
    });

    test('a corrupt resume file throws instead of starting over', () async {
      final path = _tempPath('crawl.state');
      addTearDown(
        () => Directory(io.path.dirname(path)).deleteSync(recursive: true),
      );
      File(path).writeAsStringSync('{not json');

      expect(
        () => net
            .crawl<String>('https://example.com/1'.url)
            .downloader(MapDownloader<String>({}))
            .resume(path)
            .run((res) {}),
        throwsFormatException,
      );
    });

    test(
      'a finished crawl leaves no watcher holding the process open',
      () async {
        final path = _tempPath('crawl.state');
        addTearDown(
          () => Directory(io.path.dirname(path)).deleteSync(recursive: true),
        );

        await net
            .crawl<String>('https://example.com/1'.url)
            .downloader(MapDownloader<String>({'/1': '<p>one</p>'}))
            .resume(path)
            .run((res) {});

        // The exit hook that flushes the snapshot has to come off again: it
        // keeps the signal watcher, and so the isolate, alive.
        expect(File(path).existsSync(), isFalse);
      },
    );
  });
}

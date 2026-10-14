import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/scrape.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late String base;
  final hits = <String>[];

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((request) async {
      hits.add('${request.method} ${request.uri.path}');
      final path = request.uri.path;
      if (path == '/') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<a href="/a">a</a><a href="/b">b</a><a href="/a">again</a>',
        );
      } else if (path == '/a') {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<title>A</title><img src="/img.png">');
      } else if (path == '/b') {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('nope');
      } else if (path == '/img.png') {
        request.response.write('PNGDATA');
      } else if (path == '/flaky') {
        if (hits.where((h) => h.endsWith('/flaky')).length == 1) {
          request.response
            ..statusCode = HttpStatus.serviceUnavailable
            ..write('try later');
        } else {
          request.response.write('recovered');
        }
      } else if (path == '/slow') {
        request.response.write('slow-ok');
      } else if (path == '/js') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<title>plain</title>'
          '<script>document.title = "rendered";</script>',
        );
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('nope');
      }
      await request.response.close();
    });
  });

  tearDownAll(() => server.close(force: true));

  setUp(() => hits.clear());

  group('Scrape.crawl', () {
    test('crawls start URLs and emits records', () async {
      final titles = await Scrape.crawl<String>(['$base/'], (v) async {
        final doc = await v.html();
        v.follow(doc.$('a').attrs('href'), (w) async {
          w.emit('${w.statusCode()}:${w.finalUrl()}');
        });
      }).toList();
      expect(
        titles..sort(),
        ['200:$base/a', '404:$base/b'],
      );
    });

    test('each URL is visited once', () async {
      var n = 0;
      await Scrape.crawl<String>(['$base/', '$base/a'], (v) async {
        n++;
      }).toList();
      expect(n, 2); // / and /a; the duplicate /a from follow is skipped
      hits.clear();
      await Scrape.crawl<String>(['$base/'], (v) async {
        v.follow(['$base/a', '$base/a#frag'], (w) async {});
      }).toList();
      expect(hits.where((h) => h.endsWith('/a')), hasLength(1));
    });

    test('a 404 reaches its handler', () async {
      var status = 0;
      await Scrape.crawl<void>(['$base/b'], (v) async {
        status = v.statusCode();
        expect(await v.text(), 'nope');
      }).toList();
      expect(status, HttpStatus.notFound);
    });

    test('relative links resolve against the page', () async {
      final urls = <String>[];
      await Scrape.crawl<void>(['$base/'], (v) async {
        final doc = await v.html();
        v.follow(doc.$('a').attrs('href'), (w) async {
          urls.add(w.finalUrl());
        });
      }).toList();
      expect(urls..sort(), ['$base/a', '$base/b']);
    });

    test('a 3-level tree with more workers than URLs never stalls', () async {
      // concurrency: 8 with a narrow tree parks most workers in _waitWork;
      // without a notify on every enqueue/finish the crawl would hang here.
      final seen = <String>{};
      Future<void> handler(Visit<void> v) async {
        seen.add(v.finalUrl());
        if (v.finalUrl() == '$base/') {
          final doc = await v.html();
          v.follow(doc.$('a').attrs('href'), handler);
        } else if (v.finalUrl() == '$base/a') {
          final doc = await v.html();
          v.follow(doc.$('img').attrs('src'), handler);
        }
      }

      await Scrape.crawl<void>(['$base/'], handler, concurrency: 8)
          .toList()
          .timeout(const Duration(seconds: 30));
      expect(seen, {'$base/', '$base/a', '$base/b', '$base/img.png'});
    });

    test('visit is a Reader: download assets in a handler', () async {
      final dir = await Directory.systemTemp.createTemp('scrape_img');
      try {
        await Scrape.crawl<void>(['$base/a'], (v) async {
          final doc = await v.html();
          v.follow(doc.$('img').attrs('src'), (img) async {
            await (img > Fs.dir(dir.path).file('img.png'));
          });
        }).toList();
        expect(await Fs.file('${dir.path}/img.png').text(), 'PNGDATA');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('visit reads agree: fileName, contentLength, isSuccess', () async {
      await Scrape.crawl<void>(['$base/a'], (v) async {
        expect(v.fileName(), 'a');
        expect(v.contentLength(), greaterThan(0));
        expect(v.isSuccess(), isTrue);
        expect((await v.bytes()).length, v.contentLength());
        expect(v.origin().url, v.finalUrl());
        expect(v.origin().status, v.statusCode());
      }).toList();
      await Scrape.crawl<void>(['$base/b'], (v) async {
        expect(v.isSuccess(), isFalse);
        expect(v.statusCode(), HttpStatus.notFound);
      }).toList();
    });

    test('retries recover a flaky page', () async {
      final out = await Scrape.crawl<String>(
        ['$base/flaky'],
        (w) async => w.emit(await w.text()),
        retries: 2,
      ).toList();
      expect(out, ['recovered']);
    });

    test('failures end the run by default', () async {
      expect(
        Scrape.crawl<String>(['$base/flaky'], (w) async {
          throw StateError('handler blew up');
        }).toList(),
        throwsStateError,
      );
    });

    test('S1: a failure with queued URLs errors instead of hanging',
        () async {
      // concurrency: 1, the handler queues two URLs then throws: without the
      // queue-clearing fix the workers exit but _drain waits forever.
      await expectLater(
        Scrape.crawl<String>(
          ['$base/'],
          (v) async {
            v.follow(['$base/a', '$base/b'], (w) async {});
            throw StateError('handler blew up after queueing');
          },
          concurrency: 1,
        ).toList().timeout(const Duration(seconds: 30)),
        throwsStateError,
      );
    });

    test('S2: non-http(s) links are skipped, never visited', () async {
      final seen = <String>[];
      await Scrape.crawl<void>(['$base/'], (v) async {
        v.follow(
          ['mailto:a@b.c', 'tel:+1', 'javascript:void(0)', 'data:,x', '$base/a'],
          (w) async => seen.add(w.finalUrl()),
        );
      }).toList();
      expect(seen, ['$base/a']);
    });

    test('onError reports and the crawl goes on', () async {
      final errors = <String>[];
      final out = await Scrape.crawl<String>(
        ['$base/a', '$base/b'],
        (w) async {
          if (w.finalUrl().endsWith('/a')) throw StateError('bad a');
          w.emit('b-ok');
        },
        onError: (url, e) => errors.add(url),
      ).toList();
      expect(out, ['b-ok']);
      expect(errors, ['$base/a']);
    });

    test('bad concurrency is an ArgumentError', () {
      expect(
        () => Scrape.crawl<String>([], (v) async {}, concurrency: 0),
        throwsArgumentError,
      );
    });

    test('cache replays a rerun without traffic', () async {
      final dir = await Directory.systemTemp.createTemp('scrape_cache');
      try {
        Future<Stream<String>> crawl() => Future.value(
              Scrape.crawl<String>(['$base/slow'], (w) async {
                w.emit(await w.text());
              }, cacheDir: dir.path),
            );
        expect(await (await crawl()).toList(), ['slow-ok']);
        final firstHits = hits.length;
        expect(firstHits, greaterThan(0));
        hits.clear();
        expect(await (await crawl()).toList(), ['slow-ok']);
        expect(hits, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('perHostDelay spaces requests to one host', () async {
      final sw = Stopwatch()..start();
      await Scrape.crawl<void>(
        ['$base/a', '$base/b'],
        (v) async {},
        perHostDelay: const Duration(milliseconds: 400),
        concurrency: 2,
      ).toList();
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(350));
    });

    test('browser visits render JS', () async {
      final browser = await Chrome.launch();
      try {
        final out = await Scrape.crawl<String>(['$base/js'], (v) async {
          v.emit('${v.statusCode()}:${(await v.html()).$('title').text()}');
        }, browser: browser).toList();
        expect(out, ['200:rendered']);
      } finally {
        await browser.close();
      }
    });
  });
}

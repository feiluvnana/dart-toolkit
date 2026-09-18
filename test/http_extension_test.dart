import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart' as xml_dom;

class _CountingClient extends http.BaseClient {
  final http.Client _inner;
  final void Function() _onClose;

  _CountingClient(this._inner, this._onClose);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _inner.send(request);

  @override
  void close() {
    _onClose();
    _inner.close();
  }
}

void main() {
  group('HTTP Extension & Crawler', () {
    test('res.html() parses HTML with CSS selectors and memoizes parsed doc', () {
      final res = http.Response('''
        <!DOCTYPE html>
        <html>
          <head><title>Test Page</title></head>
          <body>
            <h1>Heading 1</h1>
            <ul class="items">
              <li class="item">Item 1</li>
              <li class="item">Item 2</li>
            </ul>
          </body>
        </html>
        ''', 200);

      final html = res.html();
      expect(html, isA<HtmlDocument>());
      expect(identical(res.html(), html), isTrue); // Memoized per response instance
      expect(html.document.querySelector('h1')?.text, equals('Heading 1'));

      // CSS selector query
      final h1 = html.$('h1');
      expect(h1.firstOrNull?.text, equals('Heading 1'));

      final items = html.$('.items .item');
      expect(items.length, equals(2));
      expect(items.map((e) => e.text).toList(), equals(['Item 1', 'Item 2']));

      // Descendant selector reaches the same nodes
      final listItems = html.$('ul li');
      expect(listItems.length, equals(2));
      expect(listItems.map((e) => e.text).toList(), equals(['Item 1', 'Item 2']));
    });

    test('res.xml() parses XML with XPath selector', () {
      final res = http.Response('''
        <bookstore>
          <book category="fiction">
            <title lang="en">Harry Potter</title>
            <price>29.99</price>
          </book>
          <book category="learning">
            <title lang="en">Learning XML</title>
            <price>39.95</price>
          </book>
        </bookstore>
        ''', 200);

      final xml = res.xml();
      expect(xml, isA<XmlDocument>());
      expect(identical(res.xml(), xml), isTrue);
      expect(xml.raw.rootElement.name.local, equals('bookstore'));

      // XPath selector query
      final titles = xml.$('//book/title');
      expect(titles.length, equals(2));
      expect(titles.map((n) => (n as xml_dom.XmlElement).innerText).toList(), equals(['Harry Potter', 'Learning XML']));

      final learningTitles = xml.$('//book[@category="learning"]/title');
      expect(learningTitles.length, equals(1));
      expect((learningTitles.first as xml_dom.XmlElement).innerText, equals('Learning XML'));
    });

    test('res.json() parses JSON with JSONPath selector and memoizes parsed doc', () {
      final res = http.Response('''
        {
          "store": {
            "book": [
              {
                "category": "reference",
                "author": "Nigel Rees",
                "title": "Sayings of the Century",
                "price": 8.95
              },
              {
                "category": "fiction",
                "author": "Evelyn Waugh",
                "title": "Sword of Honour",
                "price": 12.99
              }
            ],
            "bicycle": {
              "color": "red",
              "price": 19.95
            }
          }
        }
        ''', 200);

      final json = res.json();
      expect(json, isA<JsonDocument>());
      expect(identical(res.json(), json), isTrue);
      expect(json.raw, isA<Map<String, dynamic>>());

      // JSONPath selector query
      final prices = json.$(r'$.store.book[*].price');
      expect(prices.length, equals(2));
      expect(prices.map((d) => d.raw).toList(), equals([8.95, 12.99]));

      final authors = json.$(r'$..author');
      expect(authors.length, equals(2));
      expect(authors.map((d) => d.raw).toList(), equals(['Nigel Rees', 'Evelyn Waugh']));

      final allPrices = json.$(r'$..price');
      expect(allPrices.length, equals(3));
      expect(allPrices.map((d) => d.raw).toList(), equals([8.95, 12.99, 19.95]));

      // Index operator & unified to<T>() method with nullable type arguments
      expect(json['store']['bicycle']['color'].to<String>(), equals('red'));
      expect(json['store']['bicycle']['price'].to<double>(), equals(19.95));
      expect(json['store']['bicycle']['price'].to<double?>(), equals(19.95));
      expect(json['store']['bicycle']['price'].to<num>(), equals(19.95));
      expect(json['store']['bicycle']['price'].to<int?>(), equals(19));
      expect(json['store']['book'][0]['author'].to<String>(), equals('Nigel Rees'));
      expect(json['store']['book'].list.length, equals(2));
      expect(json['store']['book'].to<List<dynamic>>()?.length, equals(2));
      expect(json['store']['nonexistent'].isNull, isTrue);
      expect(json['store']['nonexistent'].to<int?>(), isNull);
      expect(json['store']['bicycle'].to<Map<String, dynamic>>()?['color'], equals('red'));

      // Primitive coercion in to<T>()
      final primitiveDoc = JsonDocument.parse('{"numStr": "123", "boolStr": "true", "intNum": 42}');
      expect(primitiveDoc['numStr'].to<int>(), equals(123));
      expect(primitiveDoc['numStr'].to<int?>(), equals(123));
      expect(primitiveDoc['boolStr'].to<bool>(), isTrue);
      expect(primitiveDoc['intNum'].to<String>(), equals('42'));
      expect(primitiveDoc['intNum'].to<double>(), equals(42.0));
    });

    test('scrape pipeline follows links, handles relative URLs, typed ScrapeContext callbacks, and meta', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path == '/index') {
          return http.Response(
            '<html><body><h1>Catalog</h1><a href="product/1">Product 1</a></body></html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        } else if (path == '/product/1') {
          return http.Response(
            '{"name": "Widget", "price": 49.99}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      final items = await Http.session(() async {
        return await 'https://example.com/index'.url
            .scrape<Map<String, dynamic>>()
            .onResponse((ctx) {
              expect(ctx, isA<ResponseContext<Map<String, dynamic>>>());
              final category = ctx.response.html().$('h1').firstOrNull?.text;

              for (final a in ctx.response.html().$('a')) {
                final href = a.attr('href');
                if (href != null) {
                  ctx.follow(
                    href,
                    meta: {'category': category, 'label': a.text},
                    onResponse: (detailCtx) {
                      expect(detailCtx, isA<ResponseContext<Map<String, dynamic>>>());
                      final json = detailCtx.response.json();
                      detailCtx.emit({
                        'category': detailCtx.meta['category'],
                        'label': detailCtx.meta['label'],
                        'name': json.$(r'$.name').firstOrNull?.raw,
                        'price': json.$(r'$.price').firstOrNull?.raw,
                      });
                    },
                  );
                }
              }
            })
            .rights
            .toList();
      }, client: client);

      expect(items.length, equals(1));
      expect(items.first, equals({'category': 'Catalog', 'label': 'Product 1', 'name': 'Widget', 'price': 49.99}));
    });

    test('fetch-and-parse refuses a non-2xx page, get() reports it instead', () async {
      final client = MockClient((request) async => http.Response('<html>not found</html>', 404));

      await expectLater('https://example.com/missing'.url.html(client: client), throwsA(isA<HttpException>()));

      final res = await 'https://example.com/missing'.url.get(client: client);
      expect(res.ok, isFalse);
      expect(res.html().$('html').isNotEmpty, isTrue, reason: 'the body is still there to inspect');
    });

    test('ctx.url is the response URL, and ctx.resolve matches what follow() does', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/album') {
          return http.Response('<a href="track/7.mp3">t</a>', 200);
        }
        return http.Response('ok', 200);
      });

      final resolved = await Http.session(() async {
        return await 'https://example.com/album'.url
            .scrape<Uri>()
            .onResponse((ctx) {
              expect(ctx.url, equals('https://example.com/album'.url));
              ctx.emit(ctx.resolve(ctx.response.html().$('a').first.attr('href')!));
            })
            .rights
            .toList();
      }, client: client);

      expect(resolved.single, equals('https://example.com/track/7.mp3'.url));
    });

    test('Http.session shares one client across every call inside it', () async {
      var closed = 0;
      var requests = 0;
      final client = _CountingClient(
        MockClient((request) async {
          requests++;
          return http.Response('<html><b>ok</b></html>', 200);
        }),
        () => closed++,
      );

      expect(Http.client, isNull, reason: 'no ambient client outside a session');

      final pages = await Http.session(() async {
        expect(identical(Http.client, client), isTrue);
        final a = await 'https://example.com/a'.url.html();
        final b = await 'https://example.com/b'.url.get();
        expect(b.ok, isTrue);
        return [a.$('b').first.text, b.body];
      }, client: client);

      expect(pages.first, equals('ok'));
      expect(requests, equals(2));
      expect(closed, equals(0), reason: 'a supplied client is the caller\'s to close');
      expect(Http.client, isNull, reason: 'the session ends with its body');
    });

    test('scrape accepts http.Request seeds directly and handles dedupe properly', () async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        if (request.method == 'POST') {
          return http.Response('{"ok": true, "body": "${request.body}"}', 200);
        }
        return http.Response('{"ok": true}', 200, headers: {'content-type': 'application/json'});
      });

      final req1 = http.Request('POST', Uri.parse('https://example.com/api'))..body = 'body1';
      final req2 = http.Request('POST', Uri.parse('https://example.com/api'))..body = 'body2';

      final results = await Http.session(() async {
        return await [req1, req2]
            .scrape<String>()
            .onResponse((ctx) {
              ctx.emit(ctx.response.json()['body'].to<String>() ?? '');
            })
            .rights
            .toList();
      }, client: client);

      // Two POST requests with different bodies must both execute and not be falsely deduped
      expect(results, equals(['body1', 'body2']));
      expect(requestCount, equals(2));
    });

    test('scrape supports CancelToken to abort gracefully', () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('{"ok": true}', 200);
      });

      final cancelToken = CancelToken();
      final items = await Http.session(() async {
        final stream = 'https://example.com/items'.url
            .scrape<String>()
            .onResponse((ctx) {
              ctx.emit('item');
            })
            .rights
            .cancelWith(cancelToken);

        Future.microtask(() => cancelToken.cancel('User requested stop'));
        return await stream.toList();
      }, client: client);

      expect(items.isEmpty, isTrue);
    });

    test('res.isolate() runs parsing and extraction on background isolate', () async {
      final res = http.Response('''
        <html>
          <body>
            <ul class="users">
              <li data-id="1">Alice</li>
              <li data-id="2">Bob</li>
            </ul>
          </body>
        </html>
      ''', 200);

      final extracted = await res.isolate((r) {
        final items = r.html().$('.users li');
        return items.map((e) => {'id': e.attr('data-id'), 'name': e.text}).toList();
      });

      expect(
        extracted,
        equals([
          {'id': '1', 'name': 'Alice'},
          {'id': '2', 'name': 'Bob'},
        ]),
      );
    });

    test('Response.isolate composes with html(), json() and xml()', () async {
      final htmlRes = http.Response('<div><span class="val">42</span></div>', 200);
      final numVal = await htmlRes.isolate((r) => r.html().$('.val').firstOrNull?.text);
      expect(numVal, equals('42'));

      final jsonRes = http.Response('{"user": {"name": "John"}}', 200);
      final nameVal = await jsonRes.isolate((r) => r.json().$(r'$.user.name').firstOrNull?.to<String>());
      expect(nameVal, equals('John'));

      final xmlRes = http.Response('<root><item id="99">Hello</item></root>', 200);
      final xmlVal = await xmlRes.isolate((r) => r.xml().$('//item').firstOrNull?.innerText);
      expect(xmlVal, equals('Hello'));

      final mockClient = MockClient((req) async {
        if (req.url.path == '/api/item') {
          return http.Response('{"id": 99, "title": "Toolkit"}', 200);
        }
        return http.Response('<html><body><h1>Hello Uri Isolate</h1></body></html>', 200);
      });

      final itemRes = await 'https://example.com/api/item'.url.get(client: mockClient);
      final title = await itemRes.isolate((r) => r.json()['title'].to<String>());
      expect(title, equals('Toolkit'));

      final pageRes = await 'https://example.com/page'.url.get(client: mockClient);
      final heading = await pageRes.isolate((r) => r.html().$('h1').firstOrNull?.text);
      expect(heading, equals('Hello Uri Isolate'));
    });

    test('follow rejects a non-Uri, non-String target', () async {
      final client = MockClient((request) async => http.Response('<html></html>', 200));

      await Http.session(() async {
        final stream = 'https://example.com/'.url.scrape<String>().onResponse((ctx) {
          ctx.follow(42);
        });

        final lefts = await stream.lefts.toList();
        expect(lefts.single, isA<HandlerFailed>());
        expect((lefts.single as HandlerFailed).error, isA<ArgumentError>());
        expect(
          () => 'https://example.com/'.url
              .scrape<String>()
              .onResponse((ctx) {
                ctx.follow(42);
              })
              .unwrap()
              .toList(),
          throwsA(isA<HandlerFailed>()),
        );
      }, client: client);
    });

    test('follow rejects body and fields together', () async {
      final client = MockClient((request) async => http.Response('<html></html>', 200));

      await Http.session(() async {
        final stream = 'https://example.com/'.url.scrape<String>().onResponse((ctx) {
          ctx.follow('/next', method: 'POST', body: 'raw', fields: {'a': 'b'});
        });

        final lefts = await stream.lefts.toList();
        expect(lefts.single, isA<HandlerFailed>());
        expect((lefts.single as HandlerFailed).error, isA<ArgumentError>());
      }, client: client);
    });

    test('a followed POST carries its body', () async {
      final bodies = <String>[];
      final client = MockClient((request) async {
        bodies.add(request.body);
        return http.Response('<html></html>', 200);
      });

      await Http.session(() async {
        await 'https://example.com/'.url
            .scrape<String>()
            .onResponse((ctx) {
              if (ctx.request.url.path == '/') {
                ctx.follow('/submit', method: 'POST', fields: {'q': 'dart'});
              }
            })
            .rights
            .toList();
      }, client: client);

      expect(bodies, contains('q=dart'));
    });

    test('a transport failure is a Left and the stream continues', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/bad') {
          throw const SocketException('Connection refused');
        }
        return http.Response('ok', 200);
      });

      await Http.session(() async {
        final outcomes = await [Uri.parse('https://example.com/bad'), Uri.parse('https://example.com/good')]
            .scrape<String>()
            .onResponse((ctx) {
              ctx.emit(ctx.response.body);
            })
            .toList();

        expect(outcomes.length, equals(2));
        expect(outcomes.rights, equals(['ok']));
        expect(outcomes.lefts.single, isA<RequestFailed>());
      }, client: client);
    });

    test('a 404 is a BadStatus and the handler does not run', () async {
      var handlerRan = false;
      final client = MockClient((request) async => http.Response('Not Found', 404));

      await Http.session(() async {
        final outcomes = await 'https://example.com/missing'.url.scrape<String>().onResponse((ctx) {
          handlerRan = true;
          ctx.emit('should not emit');
        }).toList();

        expect(handlerRan, isFalse);
        expect(outcomes.length, equals(1));
        final failure = outcomes.single.leftOrNull;
        expect(failure, isA<BadStatus>());
        expect((failure as BadStatus).response.statusCode, equals(404));
      }, client: client);
    });

    test('an off-host follow is dropped, an on-host one and an offsite: true one are not', () async {
      final requestedPaths = <String>[];
      final client = MockClient((request) async {
        requestedPaths.add('${request.url.host}${request.url.path}');
        return http.Response('ok', 200);
      });

      await Http.session(() async {
        await 'https://example.com/root'.url
            .scrape<void>()
            .onResponse((ctx) {
              ctx.follow('https://other.com/drop');
              ctx.follow('https://example.com/keep');
              ctx.follow('https://other.com/allowed', offsite: true);
            })
            .rights
            .toList();
      }, client: client);

      expect(requestedPaths, contains('example.com/root'));
      expect(requestedPaths, contains('example.com/keep'));
      expect(requestedPaths, contains('other.com/allowed'));
      expect(requestedPaths, isNot(contains('other.com/drop')));
    });

    test('mailto: is dropped', () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.toString());
        return http.Response('ok', 200);
      });

      await Http.session(() async {
        await 'https://example.com/start'.url
            .scrape<void>()
            .onResponse((ctx) {
              ctx.follow('mailto:alice@example.com');
              ctx.follow('javascript:void(0)');
              ctx.follow('tel:123456');
            })
            .rights
            .toList();
      }, client: client);

      expect(requested, equals(['https://example.com/start']));
    });

    test('stop() after page 3 leaves the crawl at <= 3 + in-flight pages', () async {
      var handledPages = 0;
      final client = MockClient((request) async => http.Response('ok', 200));

      await Http.session(() async {
        await 'https://example.com/1'.url
            .scrape<void>()
            .onResponse((ctx) {
              handledPages++;
              if (ctx.pages >= 3) {
                ctx.stop();
              }
              ctx.follow('https://example.com/${ctx.pages + 1}');
            })
            .rights
            .toList();
      }, client: client);

      expect(handledPages, lessThanOrEqualTo(3 + 16));
      expect(handledPages, greaterThanOrEqualTo(3));
    });

    test('.take(2) stops dispatch', () async {
      var dispatched = 0;
      final client = MockClient((request) async {
        dispatched++;
        return http.Response('ok', 200);
      });

      await Http.session(() async {
        final stream = 'https://example.com/1'.url.scrape<int>().onResponse((ctx) {
          ctx.emit(ctx.pages);
          ctx.follow('https://example.com/${ctx.pages + 1}');
        });

        final results = await stream.rights.take(2).toList();
        expect(results, equals([1, 2]));
      }, client: client);

      expect(dispatched, lessThanOrEqualTo(4));
    });

    test('a 429 pauses the host for Retry-After and other hosts keep going', () async {
      final log = <String>[];
      final client = MockClient((request) async {
        if (request.url.host == 'a.com') {
          if (!log.contains('a-429')) {
            log.add('a-429');
            return http.Response('too many requests', 429, headers: {'retry-after': '1'});
          }
          log.add('a-ok');
          return http.Response('ok-a', 200);
        } else {
          log.add('b-ok');
          return http.Response('ok-b', 200);
        }
      });

      await Http.session(() async {
        final stream = [Uri.parse('https://a.com/1'), Uri.parse('https://b.com/1')].scrape<String>().onResponse((ctx) {
          ctx.emit('${ctx.url.host}:${ctx.response.body}');
        });

        final items = await stream.rights.toList();
        expect(items, contains('b.com:ok-b'));
        expect(items, contains('a.com:ok-a'));
      }, client: client);

      expect(log.indexOf('b-ok'), lessThan(log.indexOf('a-ok')));
    });

    test('HandshakeException is sent once', () async {
      var attempts = 0;
      final client = MockClient((request) async {
        attempts++;
        throw const HandshakeException('Handshake failed');
      });

      await Http.session(() async {
        final outcomes = await 'https://example.com/tls'.url.scrape<void>().toList();
        expect(outcomes.length, equals(1));
        final failure = outcomes.single.leftOrNull as RequestFailed;
        expect(failure.attempts, equals(1));
        expect(failure.error, isA<HandshakeException>());
        expect(attempts, equals(1));
      }, client: client);
    });

    test('a 17 MB body is a RequestFailed and no more than 16 MB was read', () async {
      var bytesSent = 0;
      final mock = MockClient.streaming((request, bodyStream) async {
        final total17Mb = 17 * 1024 * 1024;
        const chunkSize = 64 * 1024;
        Stream<List<int>> generateBody() async* {
          while (bytesSent < total17Mb) {
            bytesSent += chunkSize;
            yield Uint8List(chunkSize);
          }
        }

        return http.StreamedResponse(generateBody(), 200);
      });

      await Http.session(() async {
        final outcomes = await 'https://example.com/large'.url.scrape<void>().toList();
        expect(outcomes.length, equals(1));
        final failure = outcomes.single.leftOrNull as RequestFailed;
        expect(failure.error, isA<http.ClientException>());
        expect(failure.attempts, equals(1));
        expect(bytesSent, lessThanOrEqualTo(16 * 1024 * 1024 + 64 * 1024));
      }, client: mock);
    });

    test('a redirect updates ctx.url and relative resolution', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/initial') {
          return http.Response('', 301, headers: {'location': '/final/page'});
        }
        if (request.url.path == '/final/page') {
          return http.Response('<html><a href="detail">Link</a></html>', 200);
        }
        return http.Response('ok', 200);
      });

      await Http.session(() async {
        await 'https://example.com/initial'.url
            .scrape<void>()
            .onResponse((ctx) {
              expect(ctx.url, equals(Uri.parse('https://example.com/final/page')));
              expect(ctx.resolve('detail'), equals(Uri.parse('https://example.com/final/detail')));
            })
            .rights
            .toList();
      }, client: client);
    });

    test('per-host limit holds at 8 with 20 queued', () async {
      var currentInFlight = 0;
      var maxInFlightSeen = 0;

      final client = MockClient((request) async {
        currentInFlight++;
        if (currentInFlight > maxInFlightSeen) {
          maxInFlightSeen = currentInFlight;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        currentInFlight--;
        return http.Response('ok', 200);
      });

      await Http.session(() async {
        final seeds = [for (var i = 0; i < 20; i++) Uri.parse('https://example.com/item/$i')];
        await seeds.scrape<void>().rights.toList();
      }, client: client);

      expect(maxInFlightSeen, lessThanOrEqualTo(8));
      expect(maxInFlightSeen, greaterThanOrEqualTo(2));
    });

    test('a seed that redirects to another host moves the crawl there, and keeps its headers', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.host == 'example.com') {
          return http.Response('', 301, headers: {'location': 'https://www.example.com/home'});
        }
        return http.Response('<a href="/next">n</a>', 200);
      });

      final seed = http.Request('GET', Uri.parse('https://example.com/'))..headers['x-test'] = '1';
      final pages = await Http.session(() async {
        return await [seed]
            .scrape<String>()
            .onResponse((ctx) {
              ctx.emit(ctx.url.toString());
              ctx.follow('/next');
            })
            .rights
            .toList();
      }, client: client);

      expect(
        pages,
        equals(['https://www.example.com/home', 'https://www.example.com/next']),
        reason: 'www is the crawl\'s home now, so /next is on-host',
      );
      expect(
        requests.take(2).map((r) => r.headers['x-test']),
        everyElement('1'),
        reason: 'the redirect hop carries the request\'s headers; a follow starts clean',
      );
    });

    test('a redirect off the seeds\' hosts is a BadStatus, not silence', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/out') return http.Response('', 302, headers: {'location': 'https://other.com/'});
        return http.Response('<a href="/out">o</a>', 200);
      });

      final outcomes = await Http.session(() async {
        return await 'https://example.com/'.url.scrape<void>().onResponse((ctx) => ctx.follow('/out')).toList();
      }, client: client);

      final failure = outcomes.single.leftOrNull;
      expect(failure, isA<BadStatus>());
      expect((failure as BadStatus).response.statusCode, equals(302));
    });

    test('stop() lets running handlers finish and delivers their emits', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/slow') await Future<void>.delayed(const Duration(milliseconds: 100));
        return http.Response('ok', 200);
      });

      final items = await Http.session(() async {
        return await [Uri.parse('https://example.com/slow'), Uri.parse('https://example.com/fast')]
            .scrape<String>()
            .onResponse((ctx) async {
              if (ctx.url.path == '/fast') {
                ctx.stop();
                await Future<void>.delayed(const Duration(milliseconds: 150));
                ctx.emit('after-stop');
                ctx.follow('/never');
              }
            })
            .rights
            .toList();
      }, client: client);

      expect(items, equals(['after-stop']));
    });

    test('nothing reaches the error channel: a throwing handler is a Left', () async {
      final client = MockClient((request) async => http.Response('ok', 200));
      final outcomes = await Http.session(() async {
        return await 'https://example.com/'.url.scrape<void>().onResponse((ctx) => throw StateError('boom')).toList();
      }, client: client);
      expect(outcomes.single.leftOrNull, isA<HandlerFailed>());
    });

    test('the session\'s user-agent wins over the engine default', () async {
      final agents = <String?>[];
      final client = MockClient((request) async {
        agents.add(request.headers['user-agent']);
        return http.Response('ok', 200);
      });

      await Http.session(() => 'https://example.com/'.url.scrape<void>().toList(), client: client);
      await Http.session(
        () => 'https://example.com/'.url.scrape<void>().toList(),
        client: client,
        headers: {'user-agent': 'mine/1.0'},
      );

      expect(agents, equals(['dart-toolkit', 'mine/1.0']));
    });

    group('Scrape chain', () {
      test('onRequest edits headers and skip() drops a request without a report', () async {
        final seen = <String, String?>{};
        final client = MockClient((request) async {
          seen[request.url.path] = request.headers['x-sig'];
          return http.Response('ok', 200);
        });

        final outcomes = await Http.session(() async {
          return await [Uri.parse('https://example.com/a'), Uri.parse('https://example.com/skip')]
              .scrape<String>()
              .onRequest((ctx) {
                if (ctx.url.path == '/skip') return ctx.skip();
                ctx.request.headers['x-sig'] = 'signed:${ctx.attempt}';
              })
              .onResponse((ctx) => ctx.emit(ctx.url.path))
              .toList();
        }, client: client);

        expect(outcomes.rights, equals(['/a']));
        expect(outcomes.lefts, isEmpty);
        expect(seen, equals({'/a': 'signed:1'}));
      });

      test('onError: retry past the budget, ignore, emit a fallback, or let it be a Left', () async {
        var flaky = 0;
        final client = MockClient((request) async {
          switch (request.url.path) {
            case '/flaky':
              return ++flaky < 5 ? http.Response('down', 500) : http.Response('up', 200);
            case '/gone':
              return http.Response('gone', 410);
            case '/quiet':
              return http.Response('nope', 404);
            default:
              return http.Response('teapot', 418);
          }
        });

        final outcomes = await Http.session(() async {
          return await ['/flaky', '/gone', '/quiet', '/teapot']
              .map((p) => Uri.parse('https://example.com$p'))
              .scrape<String>()
              .onInit((c) => c.retries = 1)
              .onResponse((ctx) => ctx.emit(ctx.response.body))
              .onError((ctx) {
                switch (ctx.failure) {
                  case BadStatus(response: http.Response(statusCode: 500)):
                    ctx.retry();
                  case BadStatus(response: http.Response(statusCode: 410)):
                    ctx.emit('fallback');
                  case BadStatus(response: http.Response(statusCode: 404)):
                    ctx.ignore();
                  default:
                    break;
                }
              })
              .toList();
        }, client: client);

        expect(outcomes.rights, containsAll(['up', 'fallback']));
        expect(outcomes.lefts.map((f) => (f as BadStatus).response.statusCode), equals([418]));
        expect(flaky, equals(5), reason: 'the engine sent twice, the hook kept retrying until 200');
      });

      test('onFinish gets the summary once, after the last item', () async {
        final client = MockClient((request) async {
          if (request.url.path == '/bad') return http.Response('x', 404);
          return http.Response('body', 200);
        });

        ScrapeSummary? summary;
        final order = <String>[];
        await Http.session(() async {
          await for (final r
              in [
                Uri.parse('https://example.com/a'),
                Uri.parse('https://example.com/bad'),
              ].scrape<String>().onResponse((ctx) => ctx.emit('a')).onFinish((s) {
                summary = s;
                order.add('finish');
              })) {
            order.add(r.isRight ? 'item' : 'left');
          }
        }, client: client);

        expect(order, hasLength(3));
        expect(order.last, equals('finish'));
        expect(summary!.pages, equals(1));
        expect(summary!.failures, equals(1));
        expect(summary!.requests, equals(2));
        expect(summary!.bytes, equals(5));
      });

      test('maxPages stops the crawl and never over-fetches by more than the in-flight window', () async {
        var sent = 0;
        final client = MockClient((request) async {
          sent++;
          return http.Response('ok', 200);
        });

        final pages = await Http.session(() async {
          return await 'https://example.com/0'.url
              .scrape<int>()
              .onInit((c) => c.maxPages = 3)
              .onResponse((ctx) {
                ctx.emit(ctx.pages);
                for (var i = 1; i <= 20; i++) {
                  ctx.follow('/${ctx.pages}-$i');
                }
              })
              .rights
              .toList();
        }, client: client);

        expect(pages, equals([1, 2, 3]));
        expect(sent, equals(3));
      });

      test('maxDepth drops what is too deep; scope() widens the hosts', () async {
        final requested = <String>[];
        final client = MockClient((request) async {
          requested.add('${request.url.host}${request.url.path}');
          return http.Response('ok', 200);
        });

        await Http.session(() async {
          await 'https://a.com/0'.url
              .scrape<void>()
              .onInit((c) {
                c.maxDepth = 1;
                c.scope = (u) => u.host == 'a.com' || u.host == 'b.com';
              })
              .onResponse((ctx) {
                ctx.follow('https://b.com/${ctx.depth + 1}');
                ctx.follow('https://c.com/${ctx.depth + 1}');
              })
              .toList();
        }, client: client);

        expect(requested, equals(['a.com/0', 'b.com/1']));
      });

      test('delay() spaces requests to one host and not to another', () async {
        final stamps = <String, List<int>>{};
        final watch = Stopwatch()..start();
        final client = MockClient((request) async {
          (stamps[request.url.host] ??= []).add(watch.elapsedMilliseconds);
          return http.Response('ok', 200);
        });

        await Http.session(() async {
          await [
            Uri.parse('https://a.com/1'),
            Uri.parse('https://a.com/2'),
            Uri.parse('https://a.com/3'),
            Uri.parse('https://b.com/1'),
          ].scrape<void>().onInit((c) => c.delay = const Duration(milliseconds: 80)).toList();
        }, client: client);

        final a = stamps['a.com']!..sort();
        expect(a[1] - a[0], greaterThanOrEqualTo(70));
        expect(a[2] - a[1], greaterThanOrEqualTo(70));
        expect(stamps['b.com']!.single, lessThan(70), reason: 'the other host is not paced by a.com');
      });

      test(
        'onInit may be async; seed() adds a start with its own meta; headers and userAgent apply to every send',
        () async {
          final seen = <String, Map<String, String>>{};
          final client = MockClient((request) async {
            seen[request.url.path] = request.headers;
            return http.Response('ok', 200);
          });

          final metas = await Http.session(() async {
            return await 'https://example.com/a'.url
                .scrape<Object?>()
                .onInit((c) async {
                  await Future<void>.delayed(Duration.zero); // may be async: fetch a token, read a config
                  c.seed(Uri.parse('https://example.com/b'), meta: {'tag': 'b'});
                  c.headers['x-crawl'] = '1';
                  c.userAgent = 'mine/2';
                  expect(c.seeds.map((u) => u.path), equals(['/a', '/b']));
                })
                .onResponse((ctx) => ctx.emit(ctx.meta['tag']))
                .rights
                .toList();
          }, client: client);

          expect(metas.toSet(), equals({null, 'b'}));
          expect(seen['/b']!['x-crawl'], equals('1'));
          expect(seen['/b']!['user-agent'], equals('mine/2'));
        },
      );

      test('a Scrape is a Stream; a throwing onInit sends nothing and is the only event', () async {
        var sent = 0;
        final client = MockClient((request) async {
          sent++;
          return http.Response('ok', 200);
        });
        await Http.session(() async {
          final crawl = 'https://example.com/'.url.scrape<void>();
          expect(crawl, isA<Stream<Either<ScrapeFailure, void>>>());
          await expectLater(
            'https://example.com/'.url.scrape<void>().onInit((_) => throw StateError('no token')).toList(),
            throwsStateError,
          );
        }, client: client);
        expect(sent, equals(0));
      });

      test('follow(onResponse:, onError:) override the crawl hooks for one request', () async {
        final client = MockClient((request) async {
          if (request.url.path == '/detail') return http.Response('d', 404);
          return http.Response('ok', 200);
        });

        final outcomes = await Http.session(() async {
          return await 'https://example.com/'.url
              .scrape<String>()
              .onResponse((ctx) => ctx.follow('/detail', onError: (e) => e.emit('detail-fallback')))
              .onError((ctx) => ctx.emit('crawl-fallback'))
              .toList();
        }, client: client);

        expect(outcomes.rights, equals(['detail-fallback']));
      });
    });

    test('JsonDocument rejects a key that is neither String nor int', () {
      final doc = JsonDocument.parse('{"a": [1, 2]}');
      expect(doc['a'][0].to<int>(), equals(1));
      expect(doc['missing'].isNull, isTrue);
      expect(doc['a'][99].isNull, isTrue);
      expect(() => doc[3.5], throwsA(isA<ArgumentError>()));
    });
  });
}

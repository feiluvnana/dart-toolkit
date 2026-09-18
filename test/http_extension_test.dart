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
            .scrape<Map<String, dynamic>>((ctx) {
              expect(ctx, isA<ScrapeContext<Map<String, dynamic>>>());
              final category = ctx.response.html().$('h1').firstOrNull?.text;

              for (final a in ctx.response.html().$('a')) {
                final href = a.attr('href');
                if (href != null) {
                  ctx.follow(
                    href,
                    meta: {'category': category, 'label': a.text},
                    callback: (detailCtx) {
                      expect(detailCtx, isA<ScrapeContext<Map<String, dynamic>>>());
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
            .scrape<Uri>((ctx) {
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
            .scrape<String>((ctx) {
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
            .scrape<String>((ctx) {
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
        final stream = 'https://example.com/'.url.scrape<String>((ctx) {
          ctx.follow(42);
        });

        final lefts = await stream.lefts.toList();
        expect(lefts.single, isA<HandlerFailed>());
        expect((lefts.single as HandlerFailed).error, isA<ArgumentError>());
        expect(
          () => 'https://example.com/'.url
              .scrape<String>((ctx) {
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
        final stream = 'https://example.com/'.url.scrape<String>((ctx) {
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
            .scrape<String>((ctx) {
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
            .scrape<String>((ctx) {
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
        final outcomes = await 'https://example.com/missing'.url.scrape<String>((ctx) {
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
            .scrape<void>((ctx) {
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
            .scrape<void>((ctx) {
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
            .scrape<void>((ctx) {
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
        final stream = 'https://example.com/1'.url.scrape<int>((ctx) {
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
        final stream = [Uri.parse('https://a.com/1'), Uri.parse('https://b.com/1')].scrape<String>((ctx) {
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
        final outcomes = await 'https://example.com/tls'.url.scrape<void>((_) {}).toList();
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
        final outcomes = await 'https://example.com/large'.url.scrape<void>((_) {}).toList();
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
            .scrape<void>((ctx) {
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
        await seeds.scrape<void>((_) {}).rights.toList();
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
            .scrape<String>((ctx) {
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
        return await 'https://example.com/'.url.scrape<void>((ctx) => ctx.follow('/out')).toList();
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
            .scrape<String>((ctx) async {
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
        return await 'https://example.com/'.url.scrape<void>((ctx) => throw StateError('boom')).toList();
      }, client: client);
      expect(outcomes.single.leftOrNull, isA<HandlerFailed>());
    });

    test('the session\'s user-agent wins over the engine default', () async {
      final agents = <String?>[];
      final client = MockClient((request) async {
        agents.add(request.headers['user-agent']);
        return http.Response('ok', 200);
      });

      await Http.session(() => 'https://example.com/'.url.scrape<void>((_) {}).toList(), client: client);
      await Http.session(
        () => 'https://example.com/'.url.scrape<void>((_) {}).toList(),
        client: client,
        headers: {'user-agent': 'mine/1.0'},
      );

      expect(agents, equals(['dart-toolkit', 'mine/1.0']));
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

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'client_conformance.dart';
import 'mock_client.dart';
import 'package:test/test.dart';

class _CountingClient implements Client {
  final Client _inner;
  final void Function() _onClose;

  _CountingClient(this._inner, this._onClose);

  @override
  Future<StreamedResponse> send(Request request) => _inner.send(request);

  @override
  void close() {
    _onClose();
    _inner.close();
  }
}

void main() {
  group('http', () {
    test('head, put, patch, delete and json bodies', () async {
      final seen = <String>[];
      final client = MockClient((r) async {
        seen.add('${r.method} ${r.headers['content-type'] ?? '-'} ${r.text}');
        return Response('', 200);
      });
      await Http.session(() async {
        final u = 'https://a.com/x'.url;
        await u.head();
        await u.put(json: {'a': 1});
        await u.patch(body: 'text');
        await u.delete();
        await u.post(body: {'k': 'v w'});
      }, client: client);
      expect(seen, [
        'HEAD - ',
        'PUT application/json; charset=utf-8 {"a":1}',
        'PATCH text/plain; charset=utf-8 text',
        'DELETE - ',
        'POST application/x-www-form-urlencoded; charset=utf-8 k=v+w',
      ]);
      expect(() => 'https://a.com/'.url.post(body: 'x', json: 1), throwsArgumentError);
    });

    test('Uri.withQuery adds, replaces and removes parameters', () {
      final u = 'https://a.com/s?q=old&keep=1'.url;
      expect(u.withQuery({'q': 'new', 'page': 2}).toString(), 'https://a.com/s?q=new&keep=1&page=2');
      expect(u.withQuery({'keep': null}).toString(), 'https://a.com/s?q=old');
    });

    test('a download resumes its .part with a Range request', () async {
      final dir = Directory.systemTemp.createTempSync('resume_');
      try {
        final body = List.generate(5000, (i) => i & 0xff);
        final ranges = <String?>[];
        var fail = true;
        final client = MockClient.streaming((req, _) async {
          ranges.add(req.headers['range']);
          final from = int.tryParse(req.headers['range']?.replaceAll(RegExp(r'\D'), '') ?? '') ?? 0;
          Stream<List<int>> chunks() async* {
            for (var i = from; i < body.length; i += 1000) {
              if (fail && i >= 2000) throw const SocketException('dropped');
              yield body.sublist(i, i + 1000);
            }
          }

          return StreamedResponse(
            chunks(),
            from > 0 ? 206 : 200,
            contentLength: body.length - from,
            headers: from > 0 ? {'content-range': 'bytes $from-${body.length - 1}/${body.length}'} : null,
          );
        });
        final target = Path(dir.path) / 'f.bin';
        await Http.session(() async {
          final first = await target.download('https://a.com/f'.url).toList();
          expect(first.last.current, isA<DownloadFailed>());
          expect(File('$target.part').lengthSync(), 2000);
          fail = false;
          final second = await target.download('https://a.com/f'.url).toList();
          expect(second.last.current, isA<Downloaded>());
          expect((second.first.current as Downloading).received, greaterThan(2000));
        }, client: client);
        expect(ranges, [null, 'bytes=2000-']);
        expect(target.readBytesSync(), body);
        expect(File('$target.part').existsSync(), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('HTTP Extension & Crawler', () {
    test('res.html parses HTML with CSS selectors and memoizes parsed doc', () {
      final res = Response('''
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

      final html = res.html;
      expect(html, isA<HtmlDocument>());
      expect(identical(res.html, html), isTrue); // Memoized per response instance
      expect(html.$('h1').text, equals('Heading 1'));

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

    test('res.xml parses XML with XPath selector', () {
      final res = Response('''
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

      final xml = res.xml;
      expect(xml, isA<XmlDocument>());
      expect(identical(res.xml, xml), isTrue);
      expect(xml.root.local, equals('bookstore'));

      // XPath selector query
      final titles = xml.$x('//book/title');
      expect(titles.length, equals(2));
      expect(titles.map((n) => n.text).toList(), equals(['Harry Potter', 'Learning XML']));

      final learningTitles = xml.$x('//book[@category="learning"]/title');
      expect(learningTitles.length, equals(1));
      expect(learningTitles.text, equals('Learning XML'));
    });

    test('res.json parses JSON with JSONPath selector and memoizes parsed doc', () {
      final res = Response('''
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

      final json = res.json;
      expect(json, isA<JsonDocument>());
      expect(identical(res.json, json), isTrue);
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
          return Response(
            '<html><body><h1>Catalog</h1><a href="product/1">Product 1</a></body></html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        } else if (path == '/product/1') {
          return Response('{"name": "Widget", "price": 49.99}', 200, headers: {'content-type': 'application/json'});
        }
        return Response('Not Found', 404);
      });

      final items = await Http.session(() async {
        return await 'https://example.com/index'.url
            .scrape<Map<String, dynamic>>()
            .onResponse((ctx) {
              expect(ctx, isA<ResponseContext<Map<String, dynamic>>>());
              final category = ctx.response.html.$('h1').firstOrNull?.text;

              for (final a in ctx.response.html.$('a')) {
                final href = a.attr('href');
                if (href != null) {
                  ctx.follow(
                    href,
                    meta: {'category': category, 'label': a.text},
                    onResponse: (detailCtx) {
                      expect(detailCtx, isA<ResponseContext<Map<String, dynamic>>>());
                      final json = detailCtx.response.json;
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
      final client = MockClient((request) async => Response('<html>not found</html>', 404));

      await Http.session(client: client, () async {
        await expectLater('https://example.com/missing'.url.html(), throwsA(isA<HttpException>()));

        final res = await 'https://example.com/missing'.url.get();
        expect(res.isOk, isFalse);
        expect(res.html.$('html').isNotEmpty, isTrue, reason: 'the body is still there to inspect');
      });
    });

    test('ctx.url is the response URL, and ctx.resolve matches what follow() does', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/album') {
          return Response('<a href="track/7.mp3">t</a>', 200);
        }
        return Response('ok', 200);
      });

      final resolved = await Http.session(() async {
        return await 'https://example.com/album'.url
            .scrape<Uri>()
            .onResponse((ctx) {
              expect(ctx.url, equals('https://example.com/album'.url));
              ctx.emit(ctx.resolve(ctx.response.html.$('a').first.attr('href')!));
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
          return Response('<html><b>ok</b></html>', 200);
        }),
        () => closed++,
      );

      expect(Http.client, isNull, reason: 'no ambient client outside a session');

      final pages = await Http.session(() async {
        expect(identical(Http.client, client), isTrue);
        final a = await 'https://example.com/a'.url.html();
        final b = await 'https://example.com/b'.url.get();
        expect(b.isOk, isTrue);
        return [a.$('b').first.text, b.text];
      }, client: client);

      expect(pages.first, equals('ok'));
      expect(requests, equals(2));
      expect(closed, equals(0), reason: 'a supplied client is the caller\'s to close');
      expect(Http.client, isNull, reason: 'the session ends with its body');
    });

    test('scrape accepts Request seeds directly and handles dedupe properly', () async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        if (request.method == 'POST') {
          return Response('{"ok": true, "body": "${request.text}"}', 200);
        }
        return Response('{"ok": true}', 200, headers: {'content-type': 'application/json'});
      });

      final req1 = Request('POST', Uri.parse('https://example.com/api'))..text = 'body1';
      final req2 = Request('POST', Uri.parse('https://example.com/api'))..text = 'body2';

      final results = await Http.session(() async {
        return await [req1, req2]
            .scrape<String>()
            .onResponse((ctx) {
              ctx.emit(ctx.response.json['body'].to<String>() ?? '');
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
        return Response('{"ok": true}', 200);
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
      final res = Response('''
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
        final items = r.html.$('.users li');
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
      final htmlRes = Response('<div><span class="val">42</span></div>', 200);
      final numVal = await htmlRes.isolate((r) => r.html.$('.val').firstOrNull?.text);
      expect(numVal, equals('42'));

      final jsonRes = Response('{"user": {"name": "John"}}', 200);
      final nameVal = await jsonRes.isolate((r) => r.json.$(r'$.user.name').firstOrNull?.to<String>());
      expect(nameVal, equals('John'));

      final xmlRes = Response('<root><item id="99">Hello</item></root>', 200);
      final xmlVal = await xmlRes.isolate((r) => r.xml.$x('//item').text);
      expect(xmlVal, equals('Hello'));

      final mockClient = MockClient((req) async {
        if (req.url.path == '/api/item') {
          return Response('{"id": 99, "title": "Toolkit"}', 200);
        }
        return Response('<html><body><h1>Hello Uri Isolate</h1></body></html>', 200);
      });

      await Http.session(client: mockClient, () async {
        final itemRes = await 'https://example.com/api/item'.url.get();
        final title = await itemRes.isolate((r) => r.json['title'].to<String>());
        expect(title, equals('Toolkit'));

        final pageRes = await 'https://example.com/page'.url.get();
        final heading = await pageRes.isolate((r) => r.html.$('h1').firstOrNull?.text);
        expect(heading, equals('Hello Uri Isolate'));
      });
    });

    test('follow rejects a non-Uri, non-String target', () async {
      final client = MockClient((request) async => Response('<html></html>', 200));

      await Http.session(() async {
        final stream = 'https://example.com/'.url.scrape<String>().onResponse((ctx) {
          ctx.follow(42);
        });

        final lefts = await stream.lefts.toList();
        expect(lefts.single, isA<HookFailed>());
        expect((lefts.single as HookFailed).error, isA<ArgumentError>());
        expect(
          () => 'https://example.com/'.url
              .scrape<String>()
              .onResponse((ctx) {
                ctx.follow(42);
              })
              .unwrap()
              .toList(),
          throwsA(isA<HookFailed>()),
        );
      }, client: client);
    });

    test('follow rejects body and fields together', () async {
      final client = MockClient((request) async => Response('<html></html>', 200));

      await Http.session(() async {
        final stream = 'https://example.com/'.url.scrape<String>().onResponse((ctx) {
          ctx.follow('/next', method: 'POST', body: 'raw', fields: {'a': 'b'});
        });

        final lefts = await stream.lefts.toList();
        expect(lefts.single, isA<HookFailed>());
        expect((lefts.single as HookFailed).error, isA<ArgumentError>());
      }, client: client);
    });

    test('a followed POST carries its body', () async {
      final bodies = <String>[];
      final client = MockClient((request) async {
        bodies.add(request.text);
        return Response('<html></html>', 200);
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
        return Response('ok', 200);
      });

      await Http.session(() async {
        final outcomes = await [Uri.parse('https://example.com/bad'), Uri.parse('https://example.com/good')]
            .scrape<String>()
            .onResponse((ctx) {
              ctx.emit(ctx.response.text);
            })
            .toList();

        expect(outcomes.length, equals(2));
        expect(outcomes.rights, equals(['ok']));
        expect(outcomes.lefts.single, isA<RequestFailed>());
      }, client: client);
    });

    test('a 404 is a StatusFailed and the handler does not run', () async {
      var handlerRan = false;
      final client = MockClient((request) async => Response('Not Found', 404));

      await Http.session(() async {
        final outcomes = await 'https://example.com/missing'.url.scrape<String>().onResponse((ctx) {
          handlerRan = true;
          ctx.emit('should not emit');
        }).toList();

        expect(handlerRan, isFalse);
        expect(outcomes.length, equals(1));
        final failure = outcomes.single.leftOrNull;
        expect(failure, isA<StatusFailed>());
        expect((failure as StatusFailed).response.statusCode, equals(404));
      }, client: client);
    });

    test('an off-host follow is dropped, an on-host one and an offsite: true one are not', () async {
      final requestedPaths = <String>[];
      final client = MockClient((request) async {
        requestedPaths.add('${request.url.host}${request.url.path}');
        return Response('ok', 200);
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
        return Response('ok', 200);
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
      final client = MockClient((request) async => Response('ok', 200));

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
        return Response('ok', 200);
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
            return Response('too many requests', 429, headers: {'retry-after': '1'});
          }
          log.add('a-ok');
          return Response('ok-a', 200);
        } else {
          log.add('b-ok');
          return Response('ok-b', 200);
        }
      });

      await Http.session(() async {
        final stream = [Uri.parse('https://a.com/1'), Uri.parse('https://b.com/1')].scrape<String>().onResponse((ctx) {
          ctx.emit('${ctx.url.host}:${ctx.response.text}');
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

        return StreamedResponse(generateBody(), 200);
      });

      await Http.session(() async {
        final outcomes = await 'https://example.com/large'.url.scrape<void>().toList();
        expect(outcomes.length, equals(1));
        final failure = outcomes.single.leftOrNull as RequestFailed;
        expect(failure.error, isA<ClientException>());
        expect(failure.attempts, equals(1));
        expect(bytesSent, lessThanOrEqualTo(16 * 1024 * 1024 + 64 * 1024));
      }, client: mock);
    });

    test('a redirect updates ctx.url and relative resolution', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/initial') {
          return Response('', 301, headers: {'location': '/final/page'});
        }
        if (request.url.path == '/final/page') {
          return Response('<html><a href="detail">Link</a></html>', 200);
        }
        return Response('ok', 200);
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
        return Response('ok', 200);
      });

      await Http.session(() async {
        final seeds = [for (var i = 0; i < 20; i++) Uri.parse('https://example.com/item/$i')];
        await seeds.scrape<void>().rights.toList();
      }, client: client);

      expect(maxInFlightSeen, lessThanOrEqualTo(8));
      expect(maxInFlightSeen, greaterThanOrEqualTo(2));
    });

    test('a seed that redirects to another host moves the crawl there, and keeps its headers', () async {
      final requests = <Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.host == 'example.com') {
          return Response('', 301, headers: {'location': 'https://www.example.com/home'});
        }
        return Response('<a href="/next">n</a>', 200);
      });

      final seed = Request('GET', Uri.parse('https://example.com/'))..headers['x-test'] = '1';
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

    test('a redirect off the seeds\' hosts is a StatusFailed, not silence', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/out') return Response('', 302, headers: {'location': 'https://other.com/'});
        return Response('<a href="/out">o</a>', 200);
      });

      final outcomes = await Http.session(() async {
        return await 'https://example.com/'.url.scrape<void>().onResponse((ctx) => ctx.follow('/out')).toList();
      }, client: client);

      final failure = outcomes.single.leftOrNull;
      expect(failure, isA<StatusFailed>());
      expect((failure as StatusFailed).response.statusCode, equals(302));
    });

    test('stop() lets running handlers finish and delivers their emits', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/slow') await Future<void>.delayed(const Duration(milliseconds: 100));
        return Response('ok', 200);
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
      final client = MockClient((request) async => Response('ok', 200));
      final outcomes = await Http.session(() async {
        return await 'https://example.com/'.url.scrape<void>().onResponse((ctx) => throw StateError('boom')).toList();
      }, client: client);
      expect(outcomes.single.leftOrNull, isA<HookFailed>());
    });

    test('the session\'s user-agent wins over the engine default', () async {
      final agents = <String?>[];
      final client = MockClient((request) async {
        agents.add(request.headers['user-agent']);
        return Response('ok', 200);
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
          return Response('ok', 200);
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
              return ++flaky < 5 ? Response('down', 500) : Response('up', 200);
            case '/gone':
              return Response('gone', 410);
            case '/quiet':
              return Response('nope', 404);
            default:
              return Response('teapot', 418);
          }
        });

        final outcomes = await Http.session(() async {
          return await ['/flaky', '/gone', '/quiet', '/teapot']
              .map((p) => Uri.parse('https://example.com$p'))
              .scrape<String>()
              .onInit((c) => c.retries = 1)
              .onResponse((ctx) => ctx.emit(ctx.response.text))
              .onError((ctx) {
                switch (ctx.failure) {
                  case StatusFailed(response: Response(statusCode: 500)):
                    ctx.retry();
                  case StatusFailed(response: Response(statusCode: 410)):
                    ctx.emit('fallback');
                  case StatusFailed(response: Response(statusCode: 404)):
                    ctx.ignore();
                  default:
                    break;
                }
              })
              .toList();
        }, client: client);

        expect(outcomes.rights, containsAll(['up', 'fallback']));
        expect(outcomes.lefts.map((f) => (f as StatusFailed).response.statusCode), equals([418]));
        expect(flaky, equals(5), reason: 'the engine sent twice, the hook kept retrying until 200');
      });

      test('onFinish gets the summary once, after the last item', () async {
        final client = MockClient((request) async {
          if (request.url.path == '/bad') return Response('x', 404);
          return Response('body', 200);
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

      test('pages stops the crawl and never over-fetches by more than the in-flight window', () async {
        var sent = 0;
        final client = MockClient((request) async {
          sent++;
          return Response('ok', 200);
        });

        final pages = await Http.session(() async {
          return await 'https://example.com/0'.url
              .scrape<int>()
              .onInit((c) => c.pages = 3)
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

      test('depth drops what is too deep; scope() widens the hosts', () async {
        final requested = <String>[];
        final client = MockClient((request) async {
          requested.add('${request.url.host}${request.url.path}');
          return Response('ok', 200);
        });

        await Http.session(() async {
          await 'https://a.com/0'.url
              .scrape<void>()
              .onInit((c) {
                c.depth = 1;
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
          return Response('ok', 200);
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
            return Response('ok', 200);
          });

          final metas = await Http.session(() async {
            return await 'https://example.com/a'.url
                .scrape<Object?>()
                .onInit((c) async {
                  await Future<void>.delayed(Duration.zero); // may be async: fetch a token, read a config
                  c.seed(Uri.parse('https://example.com/b'), meta: {'tag': 'b'});
                  expect(c.seeds.map((u) => u.path), equals(['/a', '/b']));
                })
                .onRequest((r) => r.request.headers.addAll({'x-crawl': '1', 'user-agent': 'mine/2'}))
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
          return Response('ok', 200);
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
          if (request.url.path == '/detail') return Response('d', 404);
          return Response('ok', 200);
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

  group('http', () {
    test('Uri / joins a segment, treating the base as a directory', () {
      expect(('https://x.com/api'.url / 'users').toString(), equals('https://x.com/api/users'));
      expect(('https://x.com/api/'.url / 'users').toString(), equals('https://x.com/api/users'));
      expect(('https://x.com/api'.url / '/root').toString(), equals('https://x.com/root'));
    });

    test('leaving a downloadAll loop stops the transfers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var served = 0;
      server.listen((req) async {
        served++;
        req.response.headers.contentLength = 4;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        req.response.add([1, 2, 3, 4]);
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));
      final dir = Path(Directory.systemTemp.createTempSync('dl_break_').path);
      addTearDown(() => dir.delete(recursive: true));

      final base = Uri.parse('http://127.0.0.1:${server.port}/');
      final pairs = [for (var i = 0; i < 12; i++) (url: base / '$i', path: dir / '$i.bin')];
      await for (final p in pairs.downloadAll(concurrency: 2)) {
        if (p.completed >= 1) break;
      }
      final atBreak = served;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(served, lessThanOrEqualTo(atBreak + 2), reason: 'only the in-flight requests may finish');
    });

    test('a session timeout fails a stalled server instead of hanging', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {}); // never answers
      addTearDown(() => server.close(force: true));
      final url = Uri.parse('http://127.0.0.1:${server.port}/');
      await expectLater(
        Http.session(() => url.get(), timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('session headers reach every request that does not set them', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response
          ..write(req.headers.value('user-agent'))
          ..close();
      });
      addTearDown(() => server.close(force: true));
      final url = Uri.parse('http://127.0.0.1:${server.port}/');
      final ua = await Http.session(() async => (await url.get()).text, headers: {'user-agent': 'toolkit-test'});
      expect(ua, equals('toolkit-test'));
    });
  });

  group('scrape', () {
    test('a hook that calls stop() and then throws still closes the stream', () async {
      final client = MockClient((r) async => Response('ok', 200));
      final items = await Http.session(
        () => 'https://a.com/x'.url.scrape<int>().onResponse((ctx) {
          ctx.stop();
          throw StateError('boom');
        }).toList(),
        client: client,
      ).timeout(const Duration(seconds: 3));
      expect(items, hasLength(1));
      expect(items.single.leftOrNull, isA<HookFailed>());
    });

    test('follow returns false for a URL already followed, and the drop is counted', () async {
      final client = MockClient((r) async => Response('<a href="/song/1">s</a>', 200));
      final results = <bool>[];
      ScrapeSummary? summary;
      final out = await Http.session(
        () => 'https://a.com/list'.url
            .scrape<String>()
            .onResponse((ctx) {
              if (ctx.depth > 0) return;
              for (final ext in ['mp3', 'flac']) {
                results.add(ctx.follow('/song/1', onResponse: (song) => song.emit(ext)));
              }
            })
            .onFinish((s) => summary = s)
            .rights
            .toList(),
        client: client,
      );
      expect(results, [true, false]);
      expect(out, ['mp3']);
      expect(summary!.dropped, 1);
    });

    test('fragments are not part of a page identity', () async {
      final hits = <String>[];
      final client = MockClient((r) async {
        hits.add(r.url.toString());
        return Response(r.url.path == '/' ? '<a href="/p#a">a</a><a href="/p#b">b</a><a href="/p">c</a>' : 'x', 200);
      });
      await Http.session(
        () => 'https://a.com/#top'.url.scrape<int>().onResponse((ctx) {
          for (final a in ctx.response.html.$('a')) {
            ctx.follow(a.attr('href')!);
          }
        }).toList(),
        client: client,
      );
      expect(hits, ['https://a.com/', 'https://a.com/p']);
    });

    test('the default scope treats www. and the apex as one site', () async {
      final hits = <String>[];
      final client = MockClient((r) async {
        hits.add(r.url.host);
        return Response(
          r.url.host == 'a.com' ? '<a href="https://www.a.com/q">w</a><a href="https://b.com/">b</a>' : '',
          200,
        );
      });
      await Http.session(
        () => 'https://a.com/'.url.scrape<int>().onResponse((ctx) {
          for (final a in ctx.response.html.$('a')) {
            ctx.follow(a.attr('href')!);
          }
        }).toList(),
        client: client,
      );
      expect(hits, ['a.com', 'www.a.com']);
    });

    test('credentials do not follow a redirect to another host', () async {
      final seen = <String, String?>{};
      final client = MockClient((r) async {
        seen[r.url.host] = r.headers['authorization'];
        if (r.url.host == 'a.com') return Response('', 302, headers: {'location': 'https://cdn.example/'});
        return Response('ok', 200);
      });
      await Http.session(
        () => 'https://a.com/'.url
            .scrape<int>()
            .onRequest((ctx) {
              if (ctx.url.host == 'a.com') ctx.request.headers['authorization'] = 'Bearer SECRET';
            })
            .onResponse((ctx) {})
            .toList(),
        client: client,
      );
      expect(seen['a.com'], 'Bearer SECRET');
      expect(seen['cdn.example'], isNull);
    });

    test('Retry-After as an HTTP date in the past means no wait', () async {
      var n = 0;
      final client = MockClient((r) async {
        n++;
        if (n == 1) return Response('', 503, headers: {'retry-after': 'Wed, 21 Oct 2015 07:28:00 GMT'});
        return Response('ok', 200);
      });
      final sw = Stopwatch()..start();
      final out = await Http.session(
        () => 'https://a.com/'.url.scrape<int>().onResponse((c) => c.emit(1)).rights.toList(),
        client: client,
      );
      expect(out, [1]);
      expect(sw.elapsedMilliseconds, lessThan(400));
    });

    test('a second 429 never shortens a longer pause', () async {
      var n = 0;
      final sent = <int>[];
      final sw = Stopwatch()..start();
      final client = MockClient((r) async {
        sent.add(sw.elapsedMilliseconds);
        n++;
        if (n <= 2) return Response('', 429, headers: {'retry-after': n == 1 ? '1' : '0'});
        return Response('ok', 200);
      });
      await Http.session(
        () => ['https://a.com/1'.url, 'https://a.com/2'.url].scrape<int>().onResponse((c) => c.emit(1)).toList(),
        client: client,
      );
      // The third and fourth sends waited for the 1 s pause, not the 0 s one that arrived later.
      expect(sent.skip(2).every((t) => t >= 900), isTrue, reason: '$sent');
    });
  });

  group('download', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('dl_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('a non-2xx response is drained so the connection is not held', () async {
      var cancelled = false;
      final client = MockClient.streaming((req, body) async {
        final c = StreamController<List<int>>(onCancel: () => cancelled = true, onListen: () {});
        return StreamedResponse(c.stream, 404, contentLength: 10);
      });
      final r = await Http.session(
        () => (Path(dir.path) / 'x').download('https://a.com/x'.url).toList(),
        client: client,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(r.single.current, isA<DownloadFailed>());
      expect(cancelled, isTrue);
    });
  });

  group('brevity', () {
    test('merge runs its sources at the same time', () async {
      Stream<String> tick(String tag, int ms) async* {
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(Duration(milliseconds: ms));
          yield '$tag$i';
        }
      }

      final out = await [tick('a', 30), tick('b', 20)].merge().toList();
      expect(out, hasLength(6));
      expect(out.first, 'b0');
    });

    test('show() renders a batch and returns its last event', () async {
      final out = StringBuffer();
      Io.out = out;
      try {
        final client = MockClient((r) async => Response('data', 200));
        final dir = Directory.systemTemp.createTempSync('show_');
        try {
          final last = await Http.session(
            () => {
              'https://a.com/1'.url: Path(dir.path) / '1',
              'https://a.com/2'.url: Path(dir.path) / '2',
            }.downloadAll().show(slots: 2, message: 'Downloading', done: 'All done'),
            client: client,
          );
          expect(last!.completed, 2);
          expect(out.toString(), contains('All done'));
        } finally {
          dir.deleteSync(recursive: true);
        }
      } finally {
        Io.reset();
      }
    });

    test('Elements answers for its first match and queries within every match', () {
      final doc = '<ul><li><a href="/1">one</a></li><li><a href="/2">two</a></li></ul><p>x</p>'.html;
      expect(doc.$('li a').text, 'one');
      expect(doc.$('li a').attr('href'), '/1');
      expect(doc.$('li').$('a').map((a) => a.attr('href')), ['/1', '/2']);
      expect(doc.$('nothing').attr('href'), isNull);
      expect(() => doc.$('nothing').text, throwsStateError);
      expect(doc.$('li').length, 2);
    });

    test('String.match returns the group in one pass', () {
      expect('disc-12-track'.match(RegExp(r'-(\d+)-'), 1), '12');
      expect('disc-12-track'.match(RegExp(r'-(\d+)-'), 2), isNull);
      expect('nothing'.match(RegExp(r'\d+')), isNull);
      expect('a.b'.match('.'), '.');
    });
  });

  group('scrape -> download -> progress, over real sockets', () {
    late HttpServer server;
    late Uri base;
    late Directory tempDir;
    late StringBuffer out;

    setUp(() async {
      out = StringBuffer();
      Io.out = out;
      tempDir = Directory.systemTemp.createTempSync('pipeline_test_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((req) {
        final path = req.uri.path;
        final res = req.response;
        if (path == '/index') {
          res.write([for (var i = 1; i <= 3; i++) '<a class="track" href="/track/$i">t$i</a>'].join());
        } else if (path.startsWith('/track/')) {
          res.write('<a href="/file/${path.split('/').last}.mp3">dl</a>');
        } else if (path.startsWith('/file/') || path.startsWith('/art/')) {
          final body = List<int>.filled(64, 7);
          res.headers.contentLength = body.length;
          res.add(body);
        } else {
          res.statusCode = 404;
        }
        res.close();
      });
    });

    tearDown(() async {
      Io.reset();
      await server.close(force: true);
      tempDir.deleteSync(recursive: true);
    });

    test('one session, overlapped discovery, one report() per update', () async {
      final dir = Path(tempDir.path);
      final artwork = <Uri, Path>{
        base.resolve('/art/1.png'): dir / 'art' / '1.png',
        base.resolve('/art/2.png'): dir / 'art' / '2.png',
      };

      final progress = Console.multiProgress(slots: 2, message: 'Downloading');
      BatchDownloadProgress? last;

      await Http.session(() async {
        Stream<({Uri url, Path path})> queue() async* {
          yield* Stream.fromIterable(artwork.pairs);
          yield* base.resolve('/index').scrape<({Uri url, Path path})>().onResponse((ctx) {
            for (final a in ctx.response.html.$('a.track')) {
              ctx.follow(
                a.attr('href')!,
                onResponse: (song) {
                  final href = song.response.html.$('a').first.attr('href')!;
                  song.emit((url: song.resolve(href), path: dir / 'tracks' / song.url.pathSegments.last));
                },
              );
            }
          }).rights;
        }

        await for (final p in queue().downloadAll(concurrency: 2)) {
          progress.report(last = p);
        }
      });
      progress.done('done');

      expect(last, isNotNull);
      expect(last!.total, equals(5), reason: 'two artworks plus three scraped tracks');
      expect(last!.completed, equals(5));
      expect(last!.written, equals(5));
      expect(last!.current, isA<Downloaded>());

      expect((dir / 'art' / '1.png').existsSync(), isTrue);
      for (var i = 1; i <= 3; i++) {
        expect((dir / 'tracks' / '$i').existsSync(), isTrue, reason: 'track $i landed');
      }

      // Every completion is reported exactly once, without a terminal.
      final lines = out.toString().trim().split('\n');
      expect(lines.where((l) => l.contains('[done]')).length, equals(5));

      // Re-running skips what is already on disk instead of re-fetching it.
      final again = await artwork.downloadAll().toList();
      expect(again.last.written, equals(0));
      expect(again.every((p) => p.current is DownloadSkipped), isTrue);
    });

    test('a paused consumer stops the crawl instead of buffering it', () async {
      // /chain/n links to /chain/n+1, so the frontier is as long as the crawl runs.
      var served = 0;
      final chain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      chain.listen((req) {
        served++;
        final n = int.parse(req.uri.pathSegments.last);
        req.response
          ..write(n < 200 ? '<a href="/chain/${n + 1}">next</a>' : '')
          ..close();
      });
      addTearDown(() => chain.close(force: true));

      final root = Uri.parse('http://127.0.0.1:${chain.port}/chain/0');
      const concurrency = 8;
      final sub = root
          .scrape<String>()
          .onResponse((ctx) {
            ctx.emit(ctx.url.toString());
            for (final a in ctx.response.html.$('a')) {
              final href = a.attr('href');
              if (href != null) ctx.follow(href);
            }
          })
          .rights
          .listen((_) {});

      sub.pause();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Bounded by the in-flight requests, not by the size of the frontier.
      expect(served, lessThanOrEqualTo(concurrency + 1), reason: 'fetched $served pages while paused');

      sub.resume();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(served, greaterThan(concurrency + 1), reason: 'resuming restarts the crawl');
      await sub.cancel();
    });
  });

  clientConformance('IoClient', (_) => IoClient());
}

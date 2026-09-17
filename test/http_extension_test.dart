import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart' as xml_dom;

void main() {
  group('HTTP Extension & Crawler', () {
    test('res.html() parses HTML with CSS and XPath selectors and memoizes parsed doc', () {
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

      // XPath selector query
      final xpathItems = html.$xpath('//ul/li');
      expect(xpathItems.length, equals(2));
      expect(xpathItems.map((e) => e.text).toList(), equals(['Item 1', 'Item 2']));

      // XPath throws on invalid syntax
      expect(() => html.$xpath('//[['), throwsException);
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
      final titles = xml.$xpath('//book/title');
      expect(titles.length, equals(2));
      expect(titles.map((n) => (n as xml_dom.XmlElement).innerText).toList(), equals(['Harry Potter', 'Learning XML']));

      final learningTitles = xml.$xpath('//book[@category="learning"]/title');
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
      final prices = json.$jsonpath(r'$.store.book[*].price');
      expect(prices.length, equals(2));
      expect(prices.map((d) => d.raw).toList(), equals([8.95, 12.99]));

      final authors = json.$jsonpath(r'$..author');
      expect(authors.length, equals(2));
      expect(authors.map((d) => d.raw).toList(), equals(['Nigel Rees', 'Evelyn Waugh']));

      final allPrices = json.$jsonpath(r'$..price');
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

      final items = await 'https://example.com/index'.url.scrape<Map<String, dynamic>>((ctx) {
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
                  'name': json.$jsonpath(r'$.name').firstOrNull?.raw,
                  'price': json.$jsonpath(r'$.price').firstOrNull?.raw,
                });
              },
            );
          }
        }
      }, client: client).toList();

      expect(items.length, equals(1));
      expect(items.first, equals({'category': 'Catalog', 'label': 'Product 1', 'name': 'Widget', 'price': 49.99}));
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

      final results = await [req1, req2].scrape<String>((ctx) {
        ctx.emit(ctx.response.json()['body'].to<String>() ?? '');
      }, client: client).toList();

      // Two POST requests with different bodies must both execute and not be falsely deduped
      expect(results, equals(['body1', 'body2']));
      expect(requestCount, equals(2));
    });

    test('scrape supports CancellationToken to abort gracefully', () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('{"ok": true}', 200);
      });

      final cancelToken = CancellationToken();
      final stream = 'https://example.com/items'.url.scrape<String>(
        (ctx) {
          ctx.emit('item');
        },
        client: client,
        cancelToken: cancelToken,
      );

      Future.microtask(() => cancelToken.cancel('User requested stop'));
      final items = await stream.toList();
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

    test('Response.isolateHtml/Json/Xml parse directly in an isolate', () async {
      final htmlRes = http.Response('<div><span class="val">42</span></div>', 200);
      final numVal = await htmlRes.isolateHtml((doc) => doc.$('.val').firstOrNull?.text);
      expect(numVal, equals('42'));

      final jsonRes = http.Response('{"user": {"name": "John"}}', 200);
      final nameVal = await jsonRes.isolateJson((json) => json.$jsonpath(r'$.user.name').firstOrNull?.to<String>());
      expect(nameVal, equals('John'));

      final xmlRes = http.Response('<root><item id="99">Hello</item></root>', 200);
      final xmlVal = await xmlRes.isolateXml((xml) => xml.$xpath('//item').firstOrNull?.innerText);
      expect(xmlVal, equals('Hello'));

      final mockClient = MockClient((req) async {
        if (req.url.path == '/api/item') {
          return http.Response('{"id": 99, "title": "Toolkit"}', 200);
        }
        return http.Response('<html><body><h1>Hello Uri Isolate</h1></body></html>', 200);
      });

      final itemRes = await 'https://example.com/api/item'.url.get(client: mockClient);
      final title = await itemRes.isolateJson((doc) => doc['title'].to<String>());
      expect(title, equals('Toolkit'));

      final pageRes = await 'https://example.com/page'.url.get(client: mockClient);
      final heading = await pageRes.isolateHtml((doc) => doc.$('h1').firstOrNull?.text);
      expect(heading, equals('Hello Uri Isolate'));
    });

    test('follow rejects a non-Uri, non-String target', () async {
      final client = MockClient((request) async => http.Response('<html></html>', 200));

      final stream = 'https://example.com/'.url.scrape<String>((ctx) {
        ctx.follow(42);
      }, client: client);

      await expectLater(stream, emitsError(isA<ArgumentError>()));
    });

    test('follow rejects body and fields together', () async {
      final client = MockClient((request) async => http.Response('<html></html>', 200));

      final stream = 'https://example.com/'.url.scrape<String>((ctx) {
        ctx.follow('/next', method: 'POST', body: 'raw', fields: {'a': 'b'});
      }, client: client);

      await expectLater(stream, emitsError(isA<ArgumentError>()));
    });

    test('a followed POST carries its body', () async {
      final bodies = <String>[];
      final client = MockClient((request) async {
        bodies.add(request.body);
        return http.Response('<html></html>', 200);
      });

      await 'https://example.com/'.url.scrape<String>((ctx) {
        if (ctx.request.url.path == '/') {
          ctx.follow('/submit', method: 'POST', fields: {'q': 'dart'});
        }
      }, client: client).toList();

      expect(bodies, contains('q=dart'));
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

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart' as xml_dom;

void main() {
  group('HTTP Extension & Crawler', () {
    test('res.html() parses HTML with CSS and XPath selectors', () {
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
      expect(xml.raw.rootElement.name.local, equals('bookstore'));

      // XPath selector query
      final titles = xml.$xpath('//book/title');
      expect(titles.length, equals(2));
      expect(titles.map((n) => (n as xml_dom.XmlElement).innerText).toList(), equals(['Harry Potter', 'Learning XML']));

      final learningTitles = xml.$xpath('//book[@category="learning"]/title');
      expect(learningTitles.length, equals(1));
      expect((learningTitles.first as xml_dom.XmlElement).innerText, equals('Learning XML'));
    });

    test('res.json() parses JSON with JSONPath selector', () {
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
    });

    test('scrape pipeline follows links, handles relative URLs, callbacks, and meta', () async {
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

      final items = await 'https://example.com/index'.url.scrape<Map<String, dynamic>>((res) {
        expect(res, isA<http.Response>());
        final category = res.$('h1').firstOrNull?.text;

        for (final a in res.$('a')) {
          final href = a.attr('href');
          if (href != null) {
            res.follow(
              href, // relative URL 'product/1' -> resolved to 'https://example.com/product/1'
              meta: {'category': category, 'label': a.text},
              callback: (detailRes) {
                expect(detailRes, isA<http.Response>());
                final json = detailRes.json();
                detailRes.emit({
                  'category': detailRes.meta['category'],
                  'label': detailRes.meta['label'],
                  'name': json.$jsonpath(r'$.name').firstOrNull?.raw,
                  'price': json.$jsonpath(r'$.price').firstOrNull?.raw,
                });
              },
            );
          }
        }
      }, client: client).toList();

      expect(items.length, equals(1));
      expect(items.first, equals({
        'category': 'Catalog',
        'label': 'Product 1',
        'name': 'Widget',
        'price': 49.99,
      }));
    });

    test('scrape accepts http.Request seeds directly', () async {
      final client = MockClient((request) async {
        expect(request.headers['x-custom'], equals('test-header'));
        return http.Response('{"ok": true}', 200, headers: {'content-type': 'application/json'});
      });

      final req = http.Request('GET', Uri.parse('https://example.com/api'))
        ..headers['x-custom'] = 'test-header';

      final results = await req.scrape<bool>((res) {
        expect(res, isA<http.Response>());
        res.emit(res.json().$jsonpath(r'$.ok').firstOrNull?.raw == true);
      }, client: client).toList();

      expect(results, equals([true]));
    });

  });
}

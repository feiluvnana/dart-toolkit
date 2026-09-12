// Pull data out of one page.
//
//   dart run example/scrape.dart
//
// A response parsed from a string behaves exactly like one off the wire, so
// this runs offline. Swap `Reply.text(_page, ...)` for
// `await net.http.send(.get, url)` and nothing below it changes.

import 'package:dart_toolkit/dart_toolkit.dart';

typedef Variant = ({String name, String? sku});
typedef Product = ({String? title, num? price, List<Variant> variants});

void main() {
  final log = system.console.logger;
  final res = Reply.text(_page, url: 'https://shop.test/p/1'.url);

  // Parse HTML once into a typed Markup cursor.
  final page = res.html;

  // `page.$` is a jQuery-like selector over the parsed body: a chainable set
  // whose extraction helpers are getters.
  log.info('Title:  ${page.$('h1').text}');
  log.info('Price:  ${page.$('.price').text}');
  log.info('Tags:   ${page.$('.tag').texts}');
  log.info('Links:  ${page.$('a').attrs('href')}');
  log.info('Data:   ${page.$('#product').attr('data-id')}');

  // Beyond CSS: :contains, :has, :eq, :first, :last, :even, :odd, :gt, :lt,
  // and [attr!=value]. Traversal mirrors jQuery too.
  log.info('In stock:  ${page.$('.variant:contains("In stock")').texts}');
  log.info('Non-sale:  ${page.$('.variant[data-sale!=yes]').count}');
  log.info('Siblings:  ${page.$('.price').siblings().count}');
  log.info('XPath:     ${page.$xpath('//span[@class="price"]').text}');

  // Where the type matters, name the field with dot shorthand: `pick` keeps it.
  final String? title = page.pick(.text('h1'));
  final List<String> skus = page.pick(.attrs('.variant', 'data-sku'));
  final num? price = page.pick(.text('.price').map(_price));

  // Build a strongly-typed record: zero dynamic, zero cast.
  final Product item = (
    title: title,
    price: price,
    variants: page.all(
      '.variant',
      (row) => (name: row.$('.name').text, sku: row.attr('data-sku')),
    ),
  );

  log.ok('$title — $price, skus $skus');
  final first = item.variants.firstOrNull;
  log.ok('First variant: ${first?.name} (${first?.sku})');
}

num? _price(String? text) => util.text.number(text ?? '');

const _page = '''
<html>
  <head><link rel="canonical" href="https://shop.test/p/1"></head>
  <body>
    <div id="product" data-sku="KB-1" data-brand="Acme">
      <h1>Mechanical Keyboard</h1>
      <span class="price">\$89.00</span>
      <span class="tag">wireless</span>
      <span class="tag">rgb</span>
      <div class="variant" data-sku="KB-1-BLK" data-sale="yes">
        <span class="name">Black</span><span class="stock">In stock</span>
      </div>
      <div class="variant" data-sku="KB-1-WHT">
        <span class="name">White</span><span class="stock">Backorder</span>
      </div>
      <a href="/p/2">Related</a>
    </div>
  </body>
</html>
''';

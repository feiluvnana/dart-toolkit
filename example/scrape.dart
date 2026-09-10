// Pull data out of one page.
//
//   dart run example/scrape.dart
//
// A response parsed from a string behaves exactly like one off the wire, so
// this runs offline. Swap `Reply.text(_page, ...)` for
// `await net.http.get(url)` and nothing below it changes.

import 'package:dart_toolkit/dart_toolkit.dart';

void main() {
  final log = system.console.logger;
  final res = Reply.text(_page, url: 'https://shop.test/p/1'.url);

  // `res.$` is a jQuery-like selector over the parsed body: a chainable set
  // whose extraction helpers are getters.
  log.info('Title:  ${res.parse(format.html)('h1').text}');
  log.info('Price:  ${res.parse(format.html)('.price').text}');
  log.info('Tags:   ${res.parse(format.html)('.tag').texts}');
  log.info('Links:  ${res.parse(format.html)('a').hrefs}');
  log.info('Data:   ${res.parse(format.html)('#product').dataset}');

  // Beyond CSS: :contains, :has, :eq, :first, :last, :even, :odd, :gt, :lt,
  // and [attr!=value]. Traversal mirrors jQuery too.
  log.info(
    'In stock:  ${res.parse(format.html)('.variant:contains("In stock")').texts}',
  );
  log.info(
    'Non-sale:  ${res.parse(format.html)('.variant[data-sale!=yes]').count}',
  );
  log.info('Siblings:  ${res.parse(format.html)('.price').siblings().count}');
  log.info(
    'XPath:     ${res.parse(format.html).xpath('//span[@class="price"]').text}',
  );

  // The string shorthand, for a first look at an unfamiliar page: 'sel' is
  // text, 'sel@attr' an attribute, ['sel'] every match, and ['sel', {...}] a
  // repeated sub-object. Everything comes back as Object?.
  final loose = res.parse(format.html).extract({
    'title': 'h1',
    'canonical': 'link[rel="canonical"]@href',
    'tags': ['.tag'],
    'variants': [
      '.variant',
      {'name': '.name', 'sku': '@data-sku'},
    ],
  });
  system.console.writer.box(
    loose.entries.map((e) => '${e.key.padRight(10)} ${e.value}').join('\n'),
    title: 'extract',
  );

  // Where the type matters, name the field: `pick` keeps it. `map` converts,
  // so a price arrives as a number rather than '$89.00'.
  final String? title = res.parse(format.html).pick(Field.text('h1'));
  final List<String> skus = res
      .parse(format.html)
      .pick(Field.attrs('.variant', 'data-sku'));
  final num? price = res
      .parse(format.html)
      .pick(Field.text('.price').map(_price));

  // Or build a record, every field's type intact and no cast anywhere.
  final item = (
    title: title,
    price: price,
    variants: res
        .parse(format.html)
        .all(
          '.variant',
          (row) => (name: row('.name').text, sku: row.attr('data-sku')),
        ),
  );

  log.ok('$title — $price, skus $skus');
  log.ok(
    'First variant: ${item.variants.first.name} (${item.variants.first.sku})',
  );
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

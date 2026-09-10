// One-off requests: sessions, bodies, selectors and typed extraction.
//
//   dart run example/scrape.dart
//
// Nothing here needs the crawler engine. `net.http` is a plain client whose
// responses know how to query their own HTML.

import 'dart:convert';

import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final log = system.console.logger;

  // A response parsed from a string behaves exactly like one off the wire, so
  // the rest of this file runs offline.
  final res = HttpResponse.text(_page, url: 'https://shop.test/p/1'.url);

  // --------------------------------------------------------------- selectors
  // `res.$` is a jQuery-like selector over the parsed body. It returns a
  // chainable set, and every extraction helper is a getter on it.
  log.info('Title:  ${res.$('h1').text}');
  log.info('Links:  ${res.$('a').hrefs}');
  log.info('Tags:   ${res.$('.tag').texts}');
  log.info('Price:  ${res.$('.price').text}');
  log.info('Image:  ${res.$('img').src}');
  log.info('Data:   ${res.$('#product').dataset}');

  // jQuery extensions beyond CSS are supported: :contains, :has, :eq, :first,
  // :last, :even, :odd, :gt, :lt, :header, :input, and [attr!=value].
  log.info('In stock: ${res.$('.variant:contains("In stock")').texts}');
  log.info('First tag: ${res.$('.tag:first').text}');
  log.info('Non-sale:  ${res.$('.variant[data-sale!=yes]').length}');

  // Traversal mirrors jQuery too.
  final price = res.$('.price');
  log.info('Closest card: ${price.closest('#product').attr('id')}');
  log.info('Siblings:     ${price.siblings().length}');

  // XPath, when a selector cannot say it.
  log.info('XPath:  ${res.$xpath('//span[@class="price"]').text}');

  // ------------------------------------------------------- extraction (loose)
  // The string shorthand: 'sel' is text, 'sel@attr' an attribute, ['sel'] every
  // match, and ['sel', {...}] a repeated sub-object.
  final data = res.extract({
    'title': 'h1',
    'price': '.price',
    'canonical': 'link[rel="canonical"]@href',
    'tags': ['.tag'],
    'variants': [
      '.variant',
      {'name': '.name', 'stock': '.stock', 'sku': '@data-sku'},
    ],
  });
  system.console.writer.box(
    data.entries.map((e) => '${e.key.padRight(10)} ${e.value}').join('\n'),
    title: 'extract',
  );

  // ------------------------------------------------------- extraction (typed)
  // Where the type matters, name the field. `pick` keeps it.
  final String? title = res.pick(Field.text('h1'));
  final List<String> tags = res.pick(Field.texts('.tag'));
  final List<String> skus = res.pick(Field.attrs('.variant', 'data-sku'));
  final int variants = res.pick(
    Field.fn((el) => el.querySelectorAll('.variant').length),
  );
  log.ok('$title — ${tags.length} tags, $variants variants, skus $skus');

  // Prices arrive as '$89.00'; util.text pulls the number out.
  log.ok('Numeric price: ${util.text.number(res.$('.price').text)}');

  // ------------------------------------------------------------------- forms
  // A page's forms come back filled in as a browser would submit them: the
  // hidden inputs, the ticked boxes, the option already selected. Override the
  // fields you care about and leave the rest alone — that is what carries a
  // CSRF token through a login without hand-copying it.
  final order = res.form('#order')!;
  log.info('Form fields: ${order.fields}');

  order.fill({'qty': '2'});
  log.info('${order.method.wire} ${order.url}');
  log.info('Body: ${utf8.decode(order.body!.bytes())}');

  // A GET form puts its fields in the query instead.
  final search = res.form('form.search')!..fill({'q': 'keyboard'});
  log.ok('Search URL: ${search.url}');

  // `send()` submits it — hand it a session client and the login cookies go
  // along — and inside a crawl `res.submit(form)` queues it on the engine.

  // ------------------------------------------------------------- live requests
  // Everything below reaches the network, so it is guarded. Run with a real
  // endpoint to see it work.
  if (!system.env.get('LIVE', false)) {
    log.debug('Set LIVE=1 to run the networked half.');
    return;
  }

  // A client of your own: headers, timeout, retries, a body-size cap, and a
  // cookie jar that makes it a session. Close it when done.
  final client = HttpClient(
    headers: {'User-Agent': 'ExampleBot/1.0'},
    timeout: 15.s,
    retries: 3,
    session: true,
    cap: 10 * 1024 * 1024,
  );

  try {
    // Bodies are sealed, so the shape is explicit at the call site.
    final login = await client.post(
      'https://httpbin.org/post'.url,
      body: const Body.form({'user': 'alice', 'pass': 'secret'}),
    );
    log.ok('POST ${login.status}, ${util.size.format(login.bytes.length)}');

    // `json` throws on a bad body; `decode` hands back a fallback instead.
    final payload = login.decode(const <String, Object?>{});
    log.info('Echoed: ${(payload as Map)['form']}');

    // Cookies set anywhere in the session are sent everywhere they apply.
    if (client.jar case final jar?) {
      log.info('Jar holds ${jar.length} cookies');
    }

    // Streamed download with progress, written atomically through a `.part`.
    final bar = Progress(total: 100, unit: ProgressUnit.bytes, message: 'GET');
    await client.download(
      'https://httpbin.org/bytes/65536'.url,
      'output/blob.bin',
      onProgress: (received, total) {
        if (total > 0) bar.update(received, total: total);
      },
    );
    bar.done('Downloaded.');

    // Many URLs at once, bounded, results in input order.
    final pages = await concurrent.run(
      ['https://httpbin.org/get', 'https://httpbin.org/uuid'],
      (url) => client.get(url.url),
      size: 2,
    );
    for (final page in pages) {
      log.info('${page.status} ${page.url} ${page.type}');
    }
  } finally {
    await client.close();
  }
}

const _page = '''
<html>
  <head><link rel="canonical" href="https://shop.test/p/1"></head>
  <body>
    <div id="product" data-sku="KB-1" data-brand="Acme">
      <h1>Mechanical Keyboard</h1>
      <img src="/img/kb.png">
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
      <form id="order" action="/cart" method="post">
        <input type="hidden" name="csrf" value="tok-7f3a">
        <input type="hidden" name="sku" value="KB-1-BLK">
        <input type="number" name="qty" value="1">
        <input type="checkbox" name="gift" value="yes">
        <input type="checkbox" name="insure" value="yes" checked>
        <select name="ship">
          <option value="std">Standard</option>
          <option value="exp" selected>Express</option>
        </select>
        <button type="submit" name="do" value="add">Add to cart</button>
      </form>
      <form class="search" action="/search"><input name="q"></form>
    </div>
  </body>
</html>
''';

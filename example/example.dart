// A tour of every domain, end to end.
//
//   dart run example/example.dart
//   dart run example/example.dart --concurrency 8 --force
//
// The crawl is served from an in-memory fixture, so this runs offline and
// finishes in a second. Swap the downloader for the real thing and the rest of
// the pipeline is unchanged — that is the point of `.downloader(...)`.
//
// For focused examples see the other files in this folder:
//   crawler.dart — a multi-stage crawl with routes, tags and depth limits
//   scrape.dart  — one-off requests, sessions, selectors, typed extraction
//   tool.dart    — a small CLI: declared flags, prompts, spinners, cleanup

import 'package:dart_toolkit/dart_toolkit.dart';

/// A product the crawl emits. Handlers are typed on this, so `collect` hands
/// back a `List<Product>` rather than a list of loose maps.
class Product {
  final String name;
  final num price;
  final String url;

  const Product(this.name, this.price, this.url);

  Map<String, Object?> toJson() => {'name': name, 'price': price, 'url': url};
}

void main(List<String> args) async {
  // ---------------------------------------------------------------- system
  // Declare the command line up front and `--help` writes itself.
  cli
    ..flag('force', alias: 'f', desc: 'Overwrite existing output')
    ..flag('help', alias: 'h', desc: 'Show this message')
    ..option('concurrency', alias: 'c', desc: 'Parallel fetches', def: 4)
    ..parse(args);

  if (cli.has('help')) {
    cli.help(syntax: 'example.dart [options]', desc: 'Domain tour.');
    return;
  }

  final size = cli.get('concurrency', 4);
  final force = cli.has('force');

  // `.env` fills in what the shell did not set; nothing here fails if absent.
  system.env.load();
  final label = system.env.get('RUN_LABEL', 'demo');

  final log = system.console.logger;
  final out = system.console.writer;
  final clock = util.time.clock();

  // Tracked partial files are removed if the run is interrupted. Registering a
  // hook starts the SIGINT watcher, which holds the process open — so a script
  // that registers one finishes with `system.shutdown()`, as this does below.
  system.on.exit(() => log.debug('Cleaning up...'));

  out.rule('dart-toolkit tour ($label)');

  // ------------------------------------------------------------------- net
  // A fixture downloader stands in for the network. Every other line of this
  // crawl is what you would write against a live site.
  log.step(1, 6, 'Crawling the catalogue...');

  final products =
      await net
          .crawl<Product>('https://shop.test/catalogue')
          .downloader(MapDownloader<Product>(_fixtures))
          .concurrent(size)
          .delay(util.rand.jitter(20.ms))
          .depth(2)
          .limit(20)
          .samehost()
          .route(RegExp(r'/catalogue'), _catalogue)
          .tag('product', _product)
          .collect();

  log.ok('Collected ${products.length} products.');

  // --------------------------------------------------------------- concurrent
  // Bounded concurrency: at most `size` in flight, results in input order.
  log.step(2, 6, 'Enriching...');

  final bar = Progress(total: products.length, message: 'Enriching');
  final enriched = await concurrent.run(products, (product) async {
    await util.time.wait(util.rand.jitter(30.ms));
    bar.tick(1, product.name);
    return (
      product: product,
      slug: util.text.slug(product.name),
      key: util.hash.short(product.url),
    );
  }, size: size);
  bar.done('Enriched ${enriched.length} products.');

  // -------------------------------------------------------------------- io
  log.step(3, 6, 'Writing output...');

  final dir = 'output';
  final summary = io.join(dir, 'summary.txt');

  if (!force && io.has(summary)) {
    log.warn('$summary exists; pass --force to overwrite.');
  } else {
    // Blocking writes on `io`, non-blocking on `io.async` — same names.
    io.write(
      summary,
      [for (final e in enriched) '${e.slug} ${e.key}'].join('\n'),
    );
    io.dump(io.join(dir, 'products.json'), [
      for (final e in enriched) e.product,
    ]);

    await io.csv.write(io.join(dir, 'products.csv'), [
      for (final e in enriched)
        {'name': e.product.name, 'price': '${e.product.price}', 'slug': e.slug},
    ]);

    await io.async.write(
      io.join(dir, 'run.log'),
      'finished ${util.time.iso()}',
    );
    log.ok('Wrote 4 files to $dir/');
  }

  // A tiny JSON store keeps state between runs: cursors, "last seen" markers.
  final db = io.store.open(io.join(dir, 'state.json'));
  final runs = (db.get<int>('runs', 0) ?? 0) + 1;
  db
    ..set('runs', runs)
    ..set('last', util.time.iso());
  await db.save();

  // ------------------------------------------------------------------- zip
  log.step(4, 6, 'Archiving...');

  final archive = io.join(dir, 'catalogue-${util.time.stamp()}.tar.gz');
  await tool.zip.pack(io.join(dir, 'products.json'), archive);
  final entries = await tool.zip.list(archive);
  log.ok(
    'Packed ${entries.length} entries, ${util.size.format(io.stat(archive).size)}.',
  );

  // ------------------------------------------------------------------- git
  log.step(5, 6, 'Checking the repository...');

  final branch = await tool.git.branch();
  if (branch.isEmpty) {
    log.debug('Not a git repository.');
  } else if (await tool.git.dirty()) {
    log.warn('On $branch with uncommitted changes.');
  } else {
    log.ok('On $branch, clean at ${await tool.git.hash()}.');
  }

  // --------------------------------------------------------------- console
  log.step(6, 6, 'Summary');

  final cheapest = [...products]..sort((a, b) => a.price.compareTo(b.price));
  out.table(
    Table(
      headers: ['Product', 'Price', 'Slug'],
      alignments: [ColumnAlign.left, ColumnAlign.right, ColumnAlign.left],
    )..addAll([
      for (final e in enriched.take(5))
        [e.product.name, '\$${e.product.price}', e.slug],
    ]),
  );

  out.box(
    [
      'Run       $runs',
      'Products  ${products.length}',
      'Cheapest  ${cheapest.first.name} at \$${cheapest.first.price}',
      'Elapsed   ${util.time.format(clock.elapsed)}',
    ].join('\n'),
    title: 'Result',
  );

  // Runs the exit hooks, kills tracked children, removes tracked partials.
  await system.shutdown();
}

// ---------------------------------------------------------------------------
// Handlers. A crawl is a set of these: each receives a response, emits items
// and queues more work. `route` matches the URL, `tag` matches what queued it.
// ---------------------------------------------------------------------------

/// The listing page: queue every product, then follow pagination.
void _catalogue(Response<Product> res) {
  for (final card in res.$('.product')) {
    // `meta` survives the round trip, so the detail handler knows the price
    // the listing showed without parsing it twice.
    res.follow(
      card.query.find('a').href ?? '',
      tag: 'product',
      meta: {'listed': util.text.number(card.query.find('.price').text)},
    );
  }

  final next = res.$('a.next').href;
  if (next != null) res.follow(next);
}

/// A product page. `pick` keeps the field's type; `extract` is the shorthand.
void _product(Response<Product> res) {
  final name = res.pick(Field.text('h1'));
  final price = util.text.number(res.pick(Field.text('.price')) ?? '');
  if (name == null || price == null) return;

  res.emit(Product(name, price, res.url.toString()));
}

// ---------------------------------------------------------------------------

const _fixtures = <String, String>{
  'https://shop.test/catalogue': r'''
    <div class="product"><a href="/p/keyboard">K</a><span class="price">$89.00</span></div>
    <div class="product"><a href="/p/mouse">M</a><span class="price">$29.50</span></div>
    <a class="next" href="/catalogue?page=2">Next</a>
  ''',
  'https://shop.test/catalogue?page=2': r'''
    <div class="product"><a href="/p/monitor">D</a><span class="price">$249.00</span></div>
  ''',
  'https://shop.test/p/keyboard':
      r'<h1>Mechanical Keyboard</h1><span class="price">$89.00</span>',
  'https://shop.test/p/mouse':
      r'<h1>Wireless Mouse</h1><span class="price">$29.50</span>',
  'https://shop.test/p/monitor':
      r'<h1>27" Monitor</h1><span class="price">$249.00</span>',
};

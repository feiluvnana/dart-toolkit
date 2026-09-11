// The pipeline: every domain, doing one job together.
//
//   dart run example/example.dart
//   dart run example/example.dart --concurrency 8 --force
//
// A catalogue is crawled, each product enriched in parallel, the results
// written as JSON and CSV, archived, and reported — with the run's own state
// carried between invocations. The crawl is served from a fixture, so this
// runs offline in a second; delete the `.downloader(...)` line and the rest of
// the pipeline is unchanged. That is the point of it.
//
// Each piece has a short example of its own next door:
//
//   scrape.dart    pull data out of one page
//   crawl.dart     walk a site in stages
//   form.dart      sign in and submit a form
//   http.dart      sessions, bodies, JSON, downloads
//   parallel.dart  bounded concurrency, retries, failures
//   files.dart     text, JSON, CSV, and state between runs
//   console.dart   logs, tables, bars, boxes
//   cli.dart       the command line a script presents
//   shell.dart     environment, subprocesses, archives, git

import 'package:dart_toolkit/dart_toolkit.dart';

/// What the crawl emits. Handlers are typed on it, so `collect` hands back a
/// `List<Product>` rather than a list of loose maps.
typedef Product = ({String name, num price, String url});

/// The price the listing page showed, read back on the detail page without
/// parsing it twice.
const listed = Slot<num>('listed');

/// What the run remembers between invocations.
const runs = Slot<int>('runs');
const last = Slot<String>('last');

void main(List<String> args) async {
  // ------------------------------------------------------------------- cli
  final force = cli.flag(
    'force',
    alias: 'f',
    desc: 'Overwrite existing output',
  );
  final help = cli.flag('help', alias: 'h', desc: 'Show this message');
  final size = cli.number(
    'concurrency',
    alias: 'c',
    desc: 'Parallel fetches',
    def: 4,
  );
  cli.parse(args);

  if (help()) {
    print(
      cli.usage(
        syntax: 'example.dart [options]',
        desc: 'The pipeline, end to end.',
      ),
    );
    return;
  }

  system.env.load();
  final label = system.env.get('RUN_LABEL', 'demo');

  final log = system.console.logger;
  final out = system.console.writer;
  final clock = (Stopwatch()..start());
  final dir = io.path.join('output', 'pipeline');

  // Tracked partial files are removed if the run is interrupted. Registering a
  // hook starts the SIGINT watcher, which holds the process open — so a script
  // that registers one finishes with `system.shutdown()`, as this does.
  system.on.exit(() => log.debug('Cleaning up...'));

  out.rule('dart-toolkit ($label)');

  // -------------------------------------------------------------- 1. crawl
  log.step(1, 5, 'Crawling the catalogue...');

  final crawl = net.crawl([Fetch('https://shop.test/catalogue'.url)].seq, _next)
    ..using(_fixture)
    ..concurrent(size())
    ..delay(util.rand.jitter(20.ms))
    ..samehost()
    ..depth(2)
    ..limit(20);

  // `settle` puts the failures in band, so one bad page is reported rather
  // than swallowed and the good ones still arrive.
  final products = await crawl.settle
      .transform(
        .tap((outcome) {
          if (outcome case Broke(:final error)) log.warn('crawl: $error');
        }),
      )
      .transform(.where.type<Done<Reply>>())
      .transform(.map((outcome) => outcome.value))
      .transform(.where((res) => res.fetch.tag == 'product'))
      .transform(.flat.map(_product))
      .collect(.seq());

  log.ok('Collected ${products.collect(.count())} products.');

  // --------------------------------------------------------- 2. concurrency
  log.step(2, 5, 'Enriching...');

  final bar = Progress(total: products.collect(.count()), message: 'Enriching');
  final enriched = await concurrent.run(products, (product) async {
    await util.time.wait(util.rand.jitter(30.ms));
    bar.tick(1, product.name);
    return (
      product: product,
      slug: util.text.slug(product.name),
      key: util.hash.sha(product.url).substring(0, 8),
    );
  }, size: size());
  bar.done();
  log.ok('Enriched ${enriched.collect(.count())} products.');

  // ----------------------------------------------------------------- 3. io
  log.step(3, 5, 'Writing output...');

  final summary = io.path.join(dir, 'summary.txt');
  if (!force() && io.has(summary)) {
    log.warn('$summary exists; pass --force to overwrite.');
  } else {
    io.write(
      summary,
      enriched
          .transform(.map((e) => '${e.slug} ${e.key}'))
          .collect(.join('\n')),
    );
    io.dump(io.path.join(dir, 'products.json'), [
      for (final e in enriched.collect(.list()))
        {'name': e.product.name, 'price': e.product.price, 'slug': e.slug},
    ]);
    io.csv.write(
      io.path.join(dir, 'products.csv'),
      [
        for (final e in enriched.collect(.list()))
          {'name': e.product.name, 'price': e.product.price, 'slug': e.slug},
      ].seq,
    );
    log.ok('Wrote 3 files to $dir/.');
  }

  // The state that outlives the run: a counter and a timestamp, under typed
  // keys so neither is a string on one side and an int on the other.
  final statePath = io.path.join(dir, 'state.json');
  final db = io.dictionary(statePath);
  final count = (db.read(runs) ?? 0) + 1;
  db
    ..write(runs, count)
    ..write(last, DateTime.now().toUtc().toIso8601String())
    ..dump(statePath);

  // --------------------------------------------------------------- 4. tool
  log.step(4, 5, 'Archiving...');

  final archive = io.path.join(
    'output',
    'catalogue-${util.time.stamp()}.tar.gz',
  );
  await format.zip.pack(io.path.join(dir, 'products.json'), archive);
  log.ok('Packed ${util.size.format(io.stat(archive)!.size)} into $archive.');

  // An executable is `system.run`, not a wrapper: `tool` holds formats only.
  final head = await system.run('git', ['rev-parse', '--abbrev-ref', 'HEAD']);
  if (!head.ok) {
    log.debug('Not a git repository.');
  } else {
    final dirty = await system.run('git', ['status', '--porcelain']);
    final state = dirty.out.trim().isEmpty ? ', clean' : ' (dirty)';
    log.info('On ${head.out.trim()}$state.');
  }

  // ------------------------------------------------------------ 5. console
  log.step(5, 5, 'Summary');

  final cheapest = products.transform(.sort.by((p) => p.price));
  out.write(
    (Table(
            headers: ['Product', 'Price', 'Slug'],
            alignments: [ColumnAlign.left, ColumnAlign.right, ColumnAlign.left],
          )
          ..add.all(
            [
              for (final e
                  in enriched.transform(.take.first(5)).collect(.list()))
                [e.product.name, '\$${e.product.price}', e.slug],
            ].seq,
          ))
        .render(),
  );

  out.box(
    [
      'Run       $count',
      'Products  ${products.collect(.count())}',
      'Cheapest  ${cheapest.collect(.first())?.name} at \$${cheapest.collect(.first())?.price}',
      'Elapsed   ${util.time.format(clock.elapsed)}',
    ].join('\n'),
    title: 'Result',
  );

  // Runs the exit hooks, kills tracked children, removes tracked partials.
  await system.shutdown();
}

/// The whole router: reply in, next requests out.
///
/// On the listing, queue every product and follow pagination — `meta` survives
/// the round trip, so the product stage knows the price the listing showed. A
/// product page is a leaf.
Sequence<Fetch> _next(Reply res) => switch (res.fetch.tag) {
  null =>
    res
        .parse(format.html)
        .$('.product')
        .elements
        .transform(
          .map(
            (card) => res.follow(
              card.query.$('a').attr('href') ?? '',
              tag: 'product',
              meta: [
                if (util.text.number(card.query.$('.price').text) case final p?)
                  listed(p),
              ],
            ),
          ),
        )
        .transform(
          .plus(
            [
              if (res.parse(format.html).$('a.next').attr('href')
                  case final next?)
                res.follow(next),
            ].seq,
          ),
        ),
  _ => const Sequence<Fetch>([]),
};

/// A product page, as zero or one product.
Sequence<Product> _product(Reply res) {
  final name = res.parse(format.html).pick(Field.text('h1'));
  final price = util.text.number(
    res.parse(format.html).pick(Field.text('.price')) ?? '',
  );
  if (name == null || price == null) return const Sequence<Product>([]);
  return Sequence([(name: name, price: price, url: res.url.toString())]);
}

/// The fixture transport, which is a closure over a map.
Future<Reply> _fixture(Fetch fetch) async {
  final body = _fixtures['${fetch.url}'];
  return Reply.text(body ?? '', fetch: fetch, status: body == null ? 404 : 200);
}

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

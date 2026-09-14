// The pipeline: end-to-end modern web scraping and data processing.
//
// Demonstrates dart-toolkit 9.0.0 conventions:
// - `Path` for every filesystem operation, with `/` composing and every
//   write atomic
// - `Http` and `crawl(...)` with each knob a named argument
// - A leading dot for every typed argument: `.perHost(…)`, `.sameHost`,
//   `.number('.price')`, `.csv`
// - CliParser for declared flags, options, and auto-help
// - Console status logging, Progress, and Table rendering
// - Bounded concurrency with parallelMap
// - Atomic, crash-safe JSON & CSV persistence, and an archive
//
// Run with:
//   dart run example/example.dart
//   dart run example/example.dart --concurrency 8 --force

import 'package:dart_toolkit/dart_toolkit.dart';

/// What the crawler emits: a typed Dart 3 record.
typedef Product = ({String name, num price, String url});

void main(List<String> args) async {
  // -------------------------------------------------- 1. Command line
  final cli = CliParser(
    syntax: 'dart run example/example.dart [options]',
    description: 'Complete web crawling and data processing pipeline.',
  );
  // Declaring hands back a typed handle; calling the handle reads the value.
  final force = cli.flag('force', abbr: 'f', help: 'Overwrite existing output');
  final concurrency = cli.number(
    'concurrency',
    abbr: 'c',
    defaultsTo: 4,
    help: 'Parallel enrichment tasks',
  );
  final output = cli.option(
    'output',
    abbr: 'o',
    defaultsTo: 'output/pipeline',
    help: 'Output directory',
  );
  cli.parse(args, autoHelp: true);

  final out = Path(output());

  loadEnv();
  Console.rule('dart-toolkit (${env.value('RUN_LABEL', 'demo')})');
  onExit(() => logger.info('Clean shutdown completed.'));

  // ------------------------------------------------------- 2. Crawler
  logger.step(1, 5, 'Crawling catalogue from offline fixtures...');

  // Every knob is a named argument, so an editor shows all of them with
  // their types and defaults — and none can change once the stream exists.
  final products = await crawl(
    ['https://shop.test/catalogue'],
    next: _next,
    concurrency: concurrency(),
    politeness: .every(20.ms.jittered()),
    scope: .sameHost,
    depth: 2,
    limit: 20,
    send: _fixture,
  ).expand(_products).toList();

  logger.ok('Discovered ${products.length} products.');

  // --------------------------------------------------- 3. Concurrency
  logger.step(2, 5, 'Enriching in parallel (concurrency: ${concurrency()})...');

  final enriched = await products.parallelMap(
    (product) async {
      await delay(25.ms.jittered());
      return (
        product: product,
        slug: product.name.toSlug(),
        sku: product.url.hash().substring(0, 8),
      );
    },
    concurrency: concurrency(),
    progress: 'Enriching',
  );

  logger.ok('Enriched ${enriched.length} products.');

  // ----------------------------------------------------------- 4. I/O
  logger.step(3, 5, 'Writing results atomically to $out/...');
  await out.makeDir();

  final summary = out / 'summary.txt';
  final json = out / 'products.json';
  final csv = out / 'products.csv';

  if (!force() && summary.exists) {
    logger.warn('$summary exists; pass --force to overwrite.');
  } else {
    final rows = [
      for (final e in enriched)
        {
          'name': e.product.name,
          'price': e.product.price,
          'slug': e.slug,
          'sku': e.sku,
        },
    ];

    await summary.writeText(
      enriched.map((e) => '${e.slug} [${e.sku}]').join('\n'),
    );
    await json.writeJson(rows);
    await csv.write(rows, as: .csv);

    logger.ok('Wrote summary.txt, products.json, and products.csv.');
  }

  // ----------------------------------------------------- 5. Archiving
  logger.step(4, 5, 'Compressing archive...');

  final archive = Path('output') / 'catalogue-${DateTime.now().timestamp}.zip';
  await json.zipTo(archive);
  logger.ok('Packed ${archive.size.formatBytes()} into $archive.');

  final git = await run('git', ['status', '--porcelain']);
  if (git.ok) {
    logger.info(
      'Workspace git status: ${git.stdout.trim().isEmpty ? 'clean' : 'dirty'}.',
    );
  }

  // ------------------------------------------------------- 6. Summary
  logger.step(5, 5, 'Summary table');

  final cheapest = products.sortedBy((p) => p.price).firstOrNull;
  Console.write(
    (Table(
          headers: ['Product', 'Price', 'Slug'],
          alignments: const [.left, .right, .left],
          style: .unicode,
        )..addAll([
          for (final e in enriched.take(5))
            [e.product.name, '\$${e.product.price}', e.slug],
        ]))
        .render(),
  );

  Console.box(
    [
      'Products  ${products.length}',
      'Cheapest  ${cheapest?.name} at \$${cheapest?.price}',
      'Archive   $archive',
    ].join('\n'),
    title: 'Result',
  );

  await shutdown();
}

/// The crawler router: given a reply, emit the requests that follow it.
///
/// A pure function — reply in, requests out — so it is testable with a
/// `Response.text` fixture and no crawl at all.
Iterable<Fetch> _next(Response res) {
  if (res.fetch.tag != null) return const [];

  // `?expr` drops the element when the expression is null — Dart 3.8's
  // null-aware elements, which is exactly the shape a scraped `href` has.
  final products = [
    for (final card in res.$$('.product')) ?card.$('a').attr('href'),
  ];
  final next = res.$('a.next').attr('href');

  return [
    for (final href in products) res.follow(href, tag: 'product'),
    if (next != null) res.follow(next),
  ];
}

/// Extracts products from product-page replies.
Iterable<Product> _products(Response res) {
  if (res.fetch.tag != 'product') return const [];
  final page = res.html;
  final name = page.pick(.text('h1'));
  final price = page.pick(.number('.price'));
  if (name == null || price == null) return const [];
  return [(name: name, price: price, url: '${res.url}')];
}

/// Offline fixture transport: a `Send` is a function, so this is a closure.
Future<Response> _fixture(Fetch fetch) async {
  final body = _fixtures['${fetch.url}'];
  return Response.text(
    body ?? '',
    fetch: fetch,
    statusCode: body == null ? 404 : 200,
  );
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

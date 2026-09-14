// The pipeline: end-to-end modern web scraping and data processing.
//
// Demonstrates dart-toolkit 8.1.0 conventions:
// - Top-level functions and extensions: one spelling per operation
// - CliParser for declared flags, options, and auto-help
// - Console status logging, ProgressBar, and Table rendering
// - crawler with fixtures for instant, offline reproducibility
// - DOM traversal and typed extraction (.$(), .$$(), .all(), .texts, Field)
// - Bounded concurrency with parallelMap
// - Atomic, crash-safe JSON & CSV persistence
// - Compression and archive creation with zip
//
// Run with:
//   dart run example/example.dart
//   dart run example/example.dart --concurrency 8 --force

import 'package:dart_toolkit/dart_toolkit.dart';

/// What the crawler emits: a typed Dart 3 record.
typedef Product = ({String name, num price, String url});

void main(List<String> args) async {
  // 1. Command-line argument parsing
  final parser = CliParser(
    syntax: 'dart run example/example.dart [options]',
    description: 'Complete web crawling and data processing pipeline.',
  );
  // Declaring hands back a typed handle; calling the handle reads the value.
  final force = parser.flag(
    'force',
    abbr: 'f',
    help: 'Overwrite existing output',
  );
  final concurrency = parser.number(
    'concurrency',
    abbr: 'c',
    defaultsTo: 4,
    help: 'Parallel enrichment tasks',
  );
  final output = parser.option(
    'output',
    abbr: 'o',
    defaultsTo: 'output/pipeline',
    help: 'Output directory',
  );

  parser.parse(args, autoHelp: true);
  final outDir = output();

  loadEnv();
  final label = env.get('RUN_LABEL', 'demo');

  consoleWriter.rule('dart-toolkit ($label)');

  // Tracked partial files and hooks
  onExit(() => logger.info('Clean shutdown completed.'));

  // -------------------------------------------------------------- 1. Crawler
  logger.step(1, 5, 'Crawling catalogue from offline fixtures...');

  final crawler = crawl([Fetch('https://shop.test/catalogue'.url)], _next)
    ..using(_fixture)
    ..concurrent(concurrency())
    ..delay(jitter(const Duration(milliseconds: 20)))
    ..sameHost()
    ..depth(2)
    ..limit(20);

  final products = await crawler.flow.expand(_extractProducts).toList();

  logger.ok('Discovered ${products.length} products.');

  // -------------------------------------------------------- 2. Concurrency
  logger.step(
    2,
    5,
    'Enriching items in parallel (concurrency: ${concurrency()})...',
  );

  final bar = ProgressBar(total: products.length, message: 'Enriching');
  final enriched = await products.parallelMap((product) async {
    await delay(jitter(const Duration(milliseconds: 25)));
    bar.tick(1, product.name);
    return (
      product: product,
      slug: slugify(product.name),
      sku: sha256Hash(product.url).substring(0, 8),
    );
  }, concurrency: concurrency());
  bar.done();
  logger.ok('Enriched ${enriched.length} products.');

  // ----------------------------------------------------------------- 3. I/O
  logger.step(3, 5, 'Writing results atomically to $outDir/...');

  await makeDir(outDir);
  final jsonPath = joinPath(outDir, 'products.json');
  final csvPath = joinPath(outDir, 'products.csv');
  final summaryPath = joinPath(outDir, 'summary.txt');

  if (!force() && pathExists(summaryPath)) {
    logger.warn('$summaryPath exists; pass --force to overwrite.');
  } else {
    // 1. Plain text
    await writeText(
      summaryPath,
      enriched.map((e) => '${e.slug} [${e.sku}]').join('\n'),
    );

    // 2. Atomic JSON
    await writeJson(jsonPath, [
      for (final e in enriched)
        {
          'name': e.product.name,
          'price': e.product.price,
          'slug': e.slug,
          'sku': e.sku,
        },
    ]);

    // 3. Atomic CSV
    await writeCsv(
      csvPath,
      Stream.fromIterable([
        for (final e in enriched)
          {
            'name': e.product.name,
            'price': e.product.price,
            'slug': e.slug,
            'sku': e.sku,
          },
      ]),
      headers: ['name', 'price', 'slug', 'sku'],
    );

    logger.ok('Wrote summary.txt, products.json, and products.csv.');
  }

  // ---------------------------------------------------------- 4. Archiving
  logger.step(4, 5, 'Compressing archive...');

  final archivePath = joinPath('output', 'catalogue-${timestamp()}.zip');
  await zip(jsonPath, archivePath);
  final stat = fileStat(archivePath);
  logger.ok('Packed ${formatBytes(stat?.size ?? 0)} into $archivePath.');

  // Check git if in repo
  final gitRes = await run('git', ['status', '--porcelain']);
  if (gitRes.ok) {
    final status = gitRes.stdout.trim().isEmpty ? 'clean' : 'dirty';
    logger.info('Workspace git status: $status.');
  }

  // ------------------------------------------------------------ 5. Summary
  logger.step(5, 5, 'Summary table');

  final cheapest = products.sortedBy((p) => p.price);
  consoleWriter.write(
    (Table(
          headers: ['Product', 'Price', 'Slug'],
          alignments: [ColumnAlign.left, ColumnAlign.right, ColumnAlign.left],
          style: TableStyle.unicode,
        )..addAll([
          for (final e in enriched.take(5))
            [e.product.name, '\$${e.product.price}', e.slug],
        ]))
        .render(),
  );

  consoleWriter.box(
    [
      'Products  ${products.length}',
      'Cheapest  ${cheapest.firstOrNull?.name} at \$${cheapest.firstOrNull?.price}',
      'Archive   $archivePath',
    ].join('\n'),
    title: 'Result',
  );

  await shutdown();
}

/// The crawler router: given a reply, emit subsequent URLs to visit.
Iterable<Fetch> _next(Response res) {
  final html = res.parse(DocumentFormat.html);
  return switch (res.fetch.tag) {
    null => [
      // Follow each product card
      ...html.all(
        '.product',
        (card) => res.follow(card.$('a').attr('href') ?? '', tag: 'product'),
      ),
      // Follow pagination
      if (html.$('a.next').attr('href') case final next?) res.follow(next),
    ],
    _ => const <Fetch>[],
  };
}

/// Extracts products from product page replies.
Iterable<Product> _extractProducts(Response res) {
  if (res.fetch.tag != 'product') return const [];
  final html = res.parse(DocumentFormat.html);
  final name = html.pick(Field.text('h1'));
  final price = extractNumber(html.pick(Field.text('.price')) ?? '');
  if (name == null || price == null) return const [];
  return [(name: name, price: price, url: res.url.toString())];
}

/// Offline fixture transport: simulates web server responses offline.
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

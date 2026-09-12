// Shape the data between fetching and writing: IterableExtensions, Json, YAML.
//
//   dart run example/shape.dart
//
// This is the middle of a real script — the part that used to send a caller to
// `package:collection` for grouping and `dart:convert` for JSON. Everything
// here runs offline: the "response" is a `Reply.text`, which behaves exactly
// like one off the wire.

import 'package:dart_toolkit/dart_toolkit.dart';

typedef Sale = ({String region, String product, num amount, DateTime at});

void main() async {
  final log = system.console.logger;
  final out = system.console.writer;

  // -------------------------------------------------------------------- JSON
  // One typed cursor, three doors: a response, a string, a file. Nothing is cast,
  // and a path that is not there reads empty rather than throwing.
  final res = Reply.text(_payload, fetch: Fetch('https://api.example.com'.url));
  final doc = res.json;

  log.info('total    ${doc.at('data.total').number()}');
  log.info('cursor   ${doc.at('data').text('cursor')}');
  log.info(
    'missing  ${doc.at('data.nope.deeper').text() ?? '(empty)'}',
  );

  // `all` gives one typed value per array element.
  final sales = doc
      .at('data.sales')
      .all(
        (row) => (
          region: row.text('region') ?? '',
          product: row.text('product') ?? '',
          amount: row.number('amount') ?? 0,
          at: util.time.parse(row.text('at') ?? '') ?? DateTime(2000),
        ),
      );
  log.ok('Read ${sales.length} sales.');

  // JSONPath is the other navigator: `at` walks one path to one node, this
  // runs a query and hands back every match.
  final cheap = doc
      .at('')
      .jsonpath(r'$.data.sales[?(@.amount < 100)]')
      .mapNotNull((s) => s.text('product'))
      .toList();
  log.info('under 100: ${cheap.join(', ')}');
  log.info('every region: ${doc.jsonpath(r'$..region').length}');

  // ---------------------------------------------------------------- shaping
  // Fluent, expressive Iterable extensions: zero overhead, zero dynamic.
  final top = sales.sortedByDescending((s) => s.amount).take(3);
  log.info('top three: ${top.map((s) => s.product).join(', ')}');

  // The daily-report shape, in one expression. `groupBy` gives a
  // Map<K, List<T>>, and `sum`, `avg`, `maxBy` finish it.
  final regionalRows = sales
      .groupBy((s) => s.region)
      .entries
      .map(
        (e) => (
          region: e.key,
          orders: e.value.length,
          revenue: e.value.sum((s) => s.amount),
          best: e.value.maxBy((s) => s.amount)?.product ?? '',
        ),
      )
      .toList()
      .sortedBy((r) => r.region);

  out.write(
    (Table(
      headers: ['Region', 'Orders', 'Revenue', 'Best'],
      alignments: [.left, .right, .right, .left],
      style: .unicode,
    )..addAll([
        for (final row in regionalRows)
          [
            row.region,
            row.orders,
            row.revenue.toStringAsFixed(2),
            row.best,
          ],
      ])).render(),
  );

  // `countBy` produces a counted report in one call; `util.time.day` groups by day.
  log.info(
    'per day:    ${sales.countBy((s) => util.time.day(s.at)).length} days',
  );
  log.info(
    'mean order: ${sales.avg((s) => s.amount)?.toStringAsFixed(2)}',
  );

  // `split` partitions elements into a typed (matches, nonMatches) record.
  final (big, small) = sales.split((s) => s.amount >= 100);
  log.info('${big.length} large, ${small.length} small');

  // `chunk` batches elements for concurrency.
  for (final batch in sales.chunk(2)) {
    await concurrent.run(batch, _send, size: 2);
  }
  log.ok('Sent ${sales.length} rows in batches of two.');

  // Fluent filtering, deduplication, and sorting on any Iterable.
  final cleaned = sales
      .where((s) => s.amount > 0)
      .unique((s) => s.product)
      .sortedBy((s) => s.product);

  log.info(
    'cleaned:    ${cleaned.length} of ${sales.length}',
  );
  log.info(
    'top two:    ${cleaned.take(2).map((s) => s.product).join(', ')}',
  );

  final names = sales.map((s) => s.product).unique().toList();
  log.info('distinct products: ${names.length}');

  // ---------------------------------------------------- the other two formats
  // Same cursor, same three members: parse, read, format.
  final dir = io.dir.make(io.path.join('output', 'shape')).path;
  final config = io.path.join(dir, 'report.yaml');
  io.write(
    config,
    format.yaml.format({
      'title': 'Regional sales',
      'regions': sales.map((s) => s.region).unique().sorted(),
      'limits': {'rows': sales.length, 'currency': 'USD'},
    }),
  );

  final back = await format.yaml.read(config);
  log.ok(
    'Wrote and re-read ${io.path.filename(config)}: ${back.text('title')}',
  );
  log.info(
    'regions:    '
    '${back.at('regions').all((r) => r.text()).nonNull.join(', ')}',
  );
  log.info('rows:       ${back.number('limits.rows')}');

  // And a template, for the text a script generates rather than reads.
  log.info(
    util.text.render('{title}: {rows} rows across {regions} regions', {
      'title': back.text('title'),
      'rows': back.number('limits.rows'),
      'regions': back.at('regions').count,
    }),
  );
}

Future<void> _send(Sale sale) => util.time.wait(5.ms);

const _payload = '''
{
  "data": {
    "total": 6,
    "cursor": "eyJwYWdlIjoyfQ",
    "sales": [
      {"region": "EU", "product": "keyboard", "amount": 149.5, "at": "2024-03-09"},
      {"region": "EU", "product": "mouse",    "amount": 39.0,  "at": "2024-03-09"},
      {"region": "US", "product": "monitor",  "amount": 429.0, "at": "2024-03-10"},
      {"region": "US", "product": "cable",    "amount": 12.5,  "at": "2024-03-10"},
      {"region": "APAC", "product": "dock",   "amount": 219.0, "at": "2024-03-11"},
      {"region": "APAC", "product": "hub",    "amount": 89.0,  "at": "2024-03-11"}
    ]
  }
}
''';

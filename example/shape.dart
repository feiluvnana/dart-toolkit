// Shape the data between fetching and writing: Sequence, Dictionary, Json, YAML.
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
  // One cursor, three doors: a response, a string, a file. Nothing is cast,
  // and a path that is not there reads empty rather than throwing.
  final res = Reply.text(_payload, requested: 'https://api.example.com'.url);

  log.info('total    ${res.parse(format.json).at('data.total').number()}');
  log.info('cursor   ${res.parse(format.json).at('data').text('cursor')}');
  log.info(
    'missing  ${res.parse(format.json).at('data.nope.deeper').text() ?? '(empty)'}',
  );

  // `all` gives one typed value per array element — the JSON half of
  // `Markup.all`, and it returns a Sequence.
  final doc = res.parse(format.json);

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
  log.ok('Read ${sales.collect(.count())} sales.');

  // JSONPath is the other navigator: `at` walks one path to one node, this
  // runs a query and hands back every match.
  final cheap = doc
      .at('')
      .jsonpath(r'$.data.sales[?(@.amount < 100)]')
      .transform(.map.nonnull((s) => s.text('product')));
  log.info('under 100: ${cheap.collect(.join(', '))}');
  log.info('every region: ${doc.jsonpath(r'$..region').collect(.count())}');

  // ---------------------------------------------------------------- shaping
  // Two members: `transform` takes a Transformer, `collect` takes a Collector.
  // Every operation is a factory on one of those, which is what lets each of
  // them keep its ordinary name — `map`, `where`, `sort.by`, `take.first`.
  // `sort` and `flip` are collectors: neither can name a first element before
  // the source has ended, which is the line between the two types.
  final top = sales
      .collect(.sort.by((s) => s.amount))
      .collect(.flip())
      .transform(.take.first(3));
  log.info('top three: ${top.collect(.join(', ', of: (s) => s.product))}');

  // The daily-report shape, in one expression. `group.by` gives a
  // Dictionary<K, Sequence<T>>, `.pairs` turns it back into records, and
  // `sum`, `avg`, `max.by` and `count.by` finish it.
  out.table(
    Table(
      headers: ['Region', 'Orders', 'Revenue', 'Best'],
      alignments: [
        ColumnAlign.left,
        ColumnAlign.right,
        ColumnAlign.right,
        ColumnAlign.left,
      ],
    )..addAll([
      for (final row
          in sales
              .collect(.group.by((s) => s.region))
              .pairs
              .transform(
                .map(
                  (e) => (
                    region: e.$1,
                    orders: e.$2.collect(.count()),
                    revenue: e.$2.collect(.sum((s) => s.amount)),
                    best: e.$2.collect(.max.by((s) => s.amount))?.product ?? '',
                  ),
                ),
              )
              .collect(.sort.by((e) => e.region))
              .collect(.list()))
        [row.region, row.orders, row.revenue.toStringAsFixed(2), row.best],
    ]),
  );

  // `count.by` is a counted report in one call; `util.time.day` is the
  // grouping primitive `dart:core` has no one-liner for.
  log.info(
    'per day:    ${sales.collect(.count.by((s) => util.time.day(s.at))).count} days',
  );
  log.info(
    'mean order: ${sales.collect(.avg((s) => s.amount))?.toStringAsFixed(2)}',
  );

  // `split` and `unzip` come back as records, never a Pair type.
  final (big, small) = sales.collect(.split((s) => s.amount >= 100));
  log.info('${big.collect(.count())} large, ${small.collect(.count())} small');

  // `chunk` pairs directly with a bounded pool: batch, then send.
  for (final batch in sales.transform(.chunk(2)).collect(.list())) {
    await concurrent.run(batch.collect(.list()), _send, size: 2);
  }
  log.ok('Sent ${sales.collect(.count())} rows in batches of two.');

  // A chain is a value, so the standard cleanup is written once and used
  // twice. This is the thing a method chain cannot offer at any price.
  final cleanup = Transformer.where<Sale>((s) => s.amount > 0)
      .then(Transformer.unique.by((s) => s.product))
      .into(Collector.sort.by((s) => s.product));

  log.info(
    'cleaned:    ${sales.collect(cleanup).collect(.count())} of '
    '${sales.collect(.count())}',
  );
  log.info(
    'top two:    ${sales.collect(cleanup).transform(.take.first(2)).collect(.join(', ', of: (s) => s.product))}',
  );

  // `.list` is the one word at the boundary to anything outside this library —
  // a `List` parameter, a spread, `expect`. Inside the boundary there is one
  // vocabulary, which is why Sequence is deliberately not an Iterable.
  final names = <String>[
    ...sales
        .transform(.map((s) => s.product))
        .transform(.unique())
        .collect(.list()),
  ];
  log.info('distinct products: ${names.length}');

  // ---------------------------------------------------- the other two formats
  // Same cursor, same three members: parse, read, format.
  final dir = io.dir.make(io.path.join('output', 'shape')).path;
  final config = io.path.join(dir, 'report.yaml');
  io.write(
    config,
    format.yaml.format({
      'title': 'Regional sales',
      'regions': sales
          .transform(.map((s) => s.region))
          .transform(.unique())
          .collect(.sort())
          .collect(.list()),
      'limits': {'rows': sales.collect(.count()), 'currency': 'USD'},
    }),
  );

  final back = await format.yaml.read(config);
  log.ok(
    'Wrote and re-read ${io.path.filename(config)}: ${back.text('title')}',
  );
  log.info('regions:    ${back.at('regions').texts().collect(.join(', '))}');
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

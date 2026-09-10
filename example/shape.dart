// Shape the data between fetching and writing: Sequence, Json, YAML.
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
  log.ok('Read ${sales.count()} sales.');

  // JSONPath is the other navigator: `at` walks one path to one node, this
  // runs a query and hands back every match.
  final cheap = doc
      .at('')
      .jsonpath(r'$.data.sales[?(@.amount < 100)]')
      .sift((s) => s.text('product'));
  log.info('under 100: ${cheap.join(', ')}');
  log.info('every region: ${doc.jsonpath(r'$..region').count()}');

  // ---------------------------------------------------------------- shaping
  // Lazy: the chain below reads three rows, not all of them.
  final top = sales.sort((s) => s.amount).flip.head(3);
  log.info('top three: ${top.join(', ', of: (s) => s.product)}');

  // The daily-report shape, in one expression. `group` gives a
  // Map<K, Sequence<T>>, `.seq` turns a map back into records, and `sum`,
  // `avg`, `best` and `tally` finish it.
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
              .group((s) => s.region)
              .seq
              .to(
                (e) => (
                  region: e.$1,
                  orders: e.$2.count(),
                  revenue: e.$2.sum((s) => s.amount),
                  best: e.$2.best((s) => s.amount)?.product ?? '',
                ),
              )
              .sort((e) => e.region)
              .list)
        [row.region, row.orders, row.revenue.toStringAsFixed(2), row.best],
    ]),
  );

  // `tally` is a counted report in one call; `util.time.day` is the grouping
  // primitive `dart:core` has no one-liner for.
  log.info(
    'per day:    ${sales.tally((s) => util.time.day(s.at)).length} days',
  );
  log.info('mean order: ${sales.avg((s) => s.amount)?.toStringAsFixed(2)}');

  // `split` and `unzip` come back as records, never a Pair type.
  final (big, small) = sales.split((s) => s.amount >= 100);
  log.info('${big.count()} large, ${small.count()} small');

  // `chunks` pairs directly with a bounded pool: batch, then send.
  for (final batch in sales.chunks(2).list) {
    await concurrent.run(batch.list, _send, size: 2);
  }
  log.ok('Sent ${sales.count()} rows in batches of two.');

  // `.list` is the one word at the boundary to anything outside this library —
  // a `List` parameter, a spread, `expect`. Inside the boundary there is one
  // vocabulary, which is why Sequence is deliberately not an Iterable.
  final names = <String>[...sales.to((s) => s.product).unique().list];
  log.info('distinct products: ${names.length}');

  // ---------------------------------------------------- the other two formats
  // Same cursor, same three members: parse, read, format.
  final dir = io.mkdir(io.join('output', 'shape')).path;
  final config = io.join(dir, 'report.yaml');
  io.write(
    config,
    format.yaml.format({
      'title': 'Regional sales',
      'regions': sales.to((s) => s.region).unique().sort().list,
      'limits': {'rows': sales.count(), 'currency': 'USD'},
    }),
  );

  final back = await format.yaml.read(config);
  log.ok('Wrote and re-read ${io.base(config)}: ${back.text('title')}');
  log.info('regions:    ${back.at('regions').texts().join(', ')}');
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

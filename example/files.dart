// Put results on disk: text, JSON, CSV, and state that outlives the run.
//
//   dart run example/files.dart
//
// Every write here stages through a `.part` file and is renamed into place
// only once it has flushed, so an interrupted run never leaves a truncated
// file behind. `io.*` blocks; `io.async.*` carries the same names as futures,
// which is what a crawl handler or a pool worker wants — one blocking read
// stalls every task in flight.

import 'package:dart_toolkit/dart_toolkit.dart';

// The store's keys are slots: `runs` is an int on the way in and on the way
// out, and no two call sites can spell the key differently.
const runs = Slot<int>('runs');
const last = Slot<String>('last');

void main() async {
  final log = system.console.logger;
  final dir = io.join('output', 'files');

  final rows = [
    {'name': 'Mechanical Keyboard', 'price': 89.0},
    {'name': 'Wireless Mouse', 'price': 29.5},
    {'name': '27" Monitor', 'price': 249.0},
  ];

  // -------------------------------------------------------------- text & JSON
  // Parent directories are created as needed.
  io.write(
    io.join(dir, 'names.txt'),
    [for (final row in rows) util.text.slug('${row['name']}')].join('\n'),
  );
  io.dump(io.join(dir, 'products.json'), rows);
  io.save(io.join(dir, 'blob.bin'), [1, 2, 3]);

  final back = io.json<List<Object?>>(io.join(dir, 'products.json'));
  log.ok('Wrote and re-read ${back.length} products.');

  // ---------------------------------------------------------------------- CSV
  await io.csv.write(io.join(dir, 'products.csv'), rows);
  final records = await io.csv.maps(io.join(dir, 'products.csv'));
  log.ok('CSV columns: ${records.first.keys.join(', ')}');

  // `records` streams rather than loading the file, and `pipe` is its twin for
  // writing: it turns a crawl of any size into a spreadsheet without the rows
  // ever meeting in memory.
  //
  //   await io.csv.pipe('out.csv', crawl.stream(handler), headers: [...]);
  await for (final record in io.csv.records(io.join(dir, 'products.csv'))) {
    log.debug('${record['name']} at ${record['price']}');
  }

  // ------------------------------------------------------------------- paths
  log.info('join   ${io.join(dir, 'a', 'b.txt')}');
  log.info('base   ${io.base('a/b/c.tar.gz')}  ext ${io.ext('a/b/c.tar.gz')}');
  log.info('clean  ${io.sanitize('Report: Q3/Q4 <final>.txt')}');

  // `has` is "exists and is non-empty", which is the question a resumable
  // script actually asks.
  log.info('has    ${io.has(io.join(dir, 'products.json'))}');
  log.info(
    'size   ${util.size.format(io.stat(io.join(dir, 'products.json')).size)}',
  );
  log.info('sha    ${io.hash(io.join(dir, 'products.json')).substring(0, 12)}');

  final found = io.find(dir, pattern: RegExp(r'\.(json|csv)$'));
  log.ok('Found ${found.length}: ${[for (final f in found) io.base(f.path)]}');

  // ------------------------------------------------------------- non-blocking
  await io.async.write(io.join(dir, 'run.log'), 'finished ${util.time.iso()}');
  log.info(
    'Async read: ${(await io.async.read(io.join(dir, 'run.log'))).trim()}',
  );

  // ------------------------------------------------------------------- store
  // A tiny JSON document for what a run has to remember: cursors, "last seen"
  // markers, a resume point.
  final db = io.store.open(io.join(dir, 'state.json'));
  final count = (db.get(runs) ?? 0) + 1;
  db
    ..set(runs, count)
    ..set(last, util.time.iso());
  await db.save();
  log.ok('Run #$count (last ${db.get(last)}).');
}

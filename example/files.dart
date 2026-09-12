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
  final dir = io.path.join('output', 'files');
  final productsPath = io.path.join(dir, 'products.json');
  final csvPath = io.path.join(dir, 'products.csv');

  final rows = [
    {'name': 'Mechanical Keyboard', 'price': 89.0},
    {'name': 'Wireless Mouse', 'price': 29.5},
    {'name': '27" Monitor', 'price': 249.0},
  ];

  // -------------------------------------------------------------- text & JSON
  // Parent directories are created as needed.
  io.write(
    io.path.join(dir, 'names.txt'),
    [for (final row in rows) util.text.slug('${row['name']}')].join('\n'),
  );
  io.dump(productsPath, rows);
  io.bytes.write(io.path.join(dir, 'blob.bin'), [1, 2, 3]);

  final back = await format.json.read(productsPath);
  log.ok('Wrote and re-read ${back.count} products.');
  log.info('First name: ${back.text('0.name')}');
  log.info(
    'Every name: ${back.jsonpath(r'$[*].name').mapNotNull((n) => n.text()).toList()}',
  );

  // ---------------------------------------------------------------------- CSV
  io.csv.write(csvPath, rows);
  final sheet = await format.csv.read(csvPath);
  log.ok('CSV columns: ${sheet.headers.join(', ')}');

  // `records` streams rather than loading the entire file into memory.
  await for (final record in io.async.csv.records(csvPath)) {
    log.debug('${record['name']} at ${record['price']}');
  }

  // ------------------------------------------------------------------- paths
  log.info('join   ${io.path.join(dir, 'a', 'b.txt')}');
  log.info(
    'base   ${io.path.filename('a/b/c.tar.gz')}  ext ${io.path.ext('a/b/c.tar.gz')}',
  );
  log.info('clean  ${io.path.sanitize('Report: Q3/Q4 <final>.txt')}');

  // `has` is "exists and is non-empty", which is the question a resumable
  // script actually asks.
  log.info('has    ${io.has(productsPath)}');
  log.info(
    'size   ${util.size.format(io.stat(productsPath)!.size)}',
  );
  log.info(
    'sha    ${io.hash(productsPath).substring(0, 12)}',
  );

  final found = io.dir.walk(dir, only: .file, match: '*.{json,csv}').toList();
  log.ok(
    'Found ${found.length}: ${[for (final f in found) io.path.filename(f.path)]}',
  );

  // ------------------------------------------------------------- non-blocking
  await io.async.write(
    io.path.join(dir, 'run.log'),
    'finished ${DateTime.now().toUtc().toIso8601String()}',
  );
  log.info(
    'Async read: ${(await io.async.read(io.path.join(dir, 'run.log'))).trim()}',
  );

  // ------------------------------------------------------------------- lock
  // The moment a script goes on a schedule, two copies of it eventually run at
  // once. Atomic writes make the file safe; they do not stop the result from
  // being whichever process finished last. Released on return, on a throw, and
  // on Ctrl-C.
  await io.lock(io.path.join(dir, '.files.lock'), () async {
    log.ok('Holding the lock; a second copy would get a LockedError.');
    // A second attempt while we hold it, to show the contract.
    try {
      await io.lock(io.path.join(dir, '.files.lock'), () async {});
    } on LockedError catch (error) {
      log.info('$error');
    }
  });

  // ------------------------------------------------------------------- state
  // Self-flushing typed state persistence using io.state.
  final statePath = io.path.join(dir, 'state.json');
  final state = io.state(statePath);
  final count = (state.read(runs) ?? 0) + 1;
  state
    ..write(runs, count)
    ..write(last, DateTime.now().toUtc().toIso8601String())
    ..save();
  log.ok('Run #$count (last ${state.read(last)}).');
}

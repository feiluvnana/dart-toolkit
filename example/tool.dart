// A small, complete CLI: declared commands, prompts, progress, cleanup.
//
//   dart run example/tool.dart --help
//   dart run example/tool.dart build --out dist -c 8
//   dart run example/tool.dart clean --yes
//
// This is the shape of a real script: declare the interface once and let `run`
// parse it, print `--help`, validate it, pick the handler and turn what the
// handler returns into an exit code — leaving nothing behind if interrupted.

import 'package:dart_toolkit/dart_toolkit.dart';

final log = system.console.logger;
final out = system.console.writer;

void main(List<String> args) async {
  // `.env` fills in what the shell did not, so `--token` stays required in the
  // declaration while `API_TOKEN` satisfies it in practice.
  system.env.load();

  // Declare once. `--help`, `--version` and validation all read these, and an
  // alias given here is honoured by every later `get` and `has`.
  system.cli
    ..flag('verbose', alias: 'v', desc: 'Log every step')
    ..flag('yes', alias: 'y', desc: 'Skip confirmation prompts')
    ..option('out', alias: 'o', desc: 'Output directory', def: 'dist')
    ..option('token', desc: 'API token', env: 'API_TOKEN', required: true);

  // Each command carries the arguments only it uses.
  system.cli.handle('build', _build, desc: 'Build every target')
    ..option('concurrency', alias: 'c', desc: 'Parallel workers', def: 4)
    ..option(
      'mode',
      desc: 'Build mode',
      allowed: ['debug', 'release'],
      def: 'debug',
    );
  system.cli.handle('clean', _clean, desc: 'Remove the output directory');
  system.cli.handle('report', _report, desc: 'Summarise what was built');

  // Anything tracked here is cleaned up on Ctrl-C as well as on a normal exit.
  system.on.exit(() async {
    log.debug('Removing scratch files...');
    await io.async.delete(io.temp('tool_').path, recursive: true);
  });

  // `run` returns the exit code: whatever the handler returned, or 64 for a
  // command line it could not make sense of.
  await system.shutdown(
    await system.cli.run(
      args,
      syntax: 'tool.dart <command> [options]',
      desc: 'A worked example of the CLI, console and concurrency domains.',
      version: '1.1.0',
      strict: true,
    ),
  );
}

// ---------------------------------------------------------------------------

Future<bool> _build(Cli cli) async {
  if (cli.has('verbose')) log.level = LogLevel.debug;

  // Defaults live in the declaration, so reading one takes no second copy.
  final dest = cli.get('out', '');
  final size = cli.get('concurrency', 0);
  final targets =
      cli.list().isEmpty ? const ['app', 'worker', 'cli'] : cli.list();

  out.rule('build (${cli.get('mode', '')})');

  // A spinner for work with no measurable total.
  final spinner = system.console.spinner()..start('Resolving dependencies');
  await util.time.wait(300.ms);
  spinner.ok('Dependencies resolved.');

  // A progress bar for work that does. `settle` runs everything to completion
  // and reports per-item outcomes rather than failing on the first error.
  final bar = Progress(total: targets.length, message: 'Building');
  final pool = Pool<String>(size: size);
  pool.on.progress((_) => bar.tick());

  final results = await pool.settle(targets, (target) async {
    await util.time.wait(util.rand.jitter(200.ms));
    if (target == 'worker' && util.rand.chance(0.3)) {
      throw StateError('$target failed to link');
    }
    io.write(io.join(dest, '$target.txt'), 'built ${util.time.iso()}');
    return target;
  });
  bar.done('Build finished.');

  final failed = results.where((r) => !r.ok).toList();
  out.table(
    Table(headers: ['Target', 'Result'])..addAll([
      for (final (i, r) in results.indexed)
        [targets[i], r.ok ? 'ok' : '${r.error}'],
    ]),
  );

  if (failed.isEmpty) {
    log.ok('Built ${targets.length} targets into $dest/');
    return true;
  }
  log.error('${failed.length} of ${targets.length} targets failed.');
  return false;
}

Future<bool> _clean(Cli cli) async {
  final dest = cli.get('out', '');
  if (!io.has(io.join(dest, 'app.txt')) && io.find(dest).isEmpty) {
    log.info('Nothing to clean.');
    return true;
  }

  // Prompt unless --yes. Interactive input lives on the console reader.
  if (!cli.has('yes')) {
    final go = await system.console.reader.confirm('Delete $dest/?');
    await system.console.reader.close();
    if (!go) {
      log.warn('Cancelled.');
      return true;
    }
  }

  final removed = await io.async.delete(dest, recursive: true);
  log.ok('Removed $removed files.');
  return true;
}

Future<bool> _report(Cli cli) async {
  final dest = cli.get('out', '');
  final files = await io.async.find(dest);
  if (files.isEmpty) {
    log.warn('No build output in $dest/. Run `build` first.');
    return false;
  }

  var total = 0;
  final rows = <List<Object?>>[];
  for (final file in files) {
    final size = (await io.async.stat(file.path)).size;
    total += size;
    rows.add([
      io.base(file.path),
      util.size.format(size),
      util.hash.short(await io.async.read(file.path)),
    ]);
  }

  out.table(Table(headers: ['File', 'Size', 'Digest'])..addAll(rows));
  out.box(
    'Files  ${files.length}\nTotal  ${util.size.format(total)}',
    title: 'report',
  );
  return true;
}

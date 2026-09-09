// A small, complete CLI: declared arguments, prompts, progress, cleanup.
//
//   dart run example/tool.dart --help
//   dart run example/tool.dart build --out dist -c 8
//   dart run example/tool.dart clean --yes
//
// This is the shape of a real script: declare the interface once, validate it,
// dispatch on the subcommand, and leave nothing behind if it is interrupted.

import 'package:dart_toolkit/dart_toolkit.dart';

final log = system.console.logger;
final out = system.console.writer;

void main(List<String> args) async {
  // Declare once. `--help` and validation both read these declarations, and an
  // alias given here is honoured by every later `get` and `has`.
  system.cli
    ..flag('help', alias: 'h', desc: 'Show this message')
    ..flag('verbose', alias: 'v', desc: 'Log every step')
    ..flag('yes', alias: 'y', desc: 'Skip confirmation prompts')
    ..option('out', alias: 'o', desc: 'Output directory', def: 'dist')
    ..option('concurrency', alias: 'c', desc: 'Parallel workers', def: 4)
    ..option('token', desc: 'API token', required: true)
    ..parse(args);

  if (system.cli.has('help') || system.cli.command == null) {
    system.cli.help(
      syntax: 'tool.dart <build|clean|report> [options]',
      desc: 'A worked example of the CLI, console and concurrency domains.',
    );
    return;
  }

  // `.env` fills in what the shell did not, so `--token` can be optional in
  // practice while staying required in the declaration.
  system.env.load();
  if (!system.cli.has('token') && system.env.has('API_TOKEN')) {
    log.debug('Using API_TOKEN from the environment.');
  } else {
    // Throws with a readable message naming what is missing.
    try {
      system.cli.require();
    } on ArgumentError catch (error) {
      log.error(error.message.toString());
      return;
    }
  }

  if (system.cli.has('verbose')) log.level = LogLevel.debug;

  // Anything tracked here is cleaned up on Ctrl-C as well as on a normal exit.
  system.on.exit(() async {
    log.debug('Removing scratch files...');
    await io.async.delete(io.temp('tool_').path, recursive: true);
  });

  final ok = switch (system.cli.command) {
    'build' => await _build(),
    'clean' => await _clean(),
    'report' => await _report(),
    final unknown => _unknown(unknown),
  };

  await system.shutdown(ok ? 0 : 1);
}

// ---------------------------------------------------------------------------

Future<bool> _build() async {
  final dest = system.cli.get('out', 'dist');
  final size = system.cli.get('concurrency', 4);
  final targets =
      system.cli.rest.isEmpty
          ? const ['app', 'worker', 'cli']
          : system.cli.rest;

  out.rule('build');

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

Future<bool> _clean() async {
  final dest = system.cli.get('out', 'dist');
  if (!io.has(io.join(dest, 'app.txt')) && io.find(dest).isEmpty) {
    log.info('Nothing to clean.');
    return true;
  }

  // Prompt unless --yes. Interactive input lives on the console reader.
  if (!system.cli.has('yes')) {
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

Future<bool> _report() async {
  final dest = system.cli.get('out', 'dist');
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

bool _unknown(String? command) {
  log.error('Unknown command: $command');
  system.cli.help(syntax: 'tool.dart <build|clean|report> [options]');
  return false;
}

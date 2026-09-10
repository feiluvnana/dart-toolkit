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
final writer = system.console.writer;

// The interface this script presents. Declaring an option hands back an
// `Opt<T>`; calling it reads the value. Nothing downstream repeats the type or
// the default, and nothing downstream can ask for the wrong one.
//
// The declarations sit in `_declare`, called first thing in `main`, rather
// than in the initialisers of these variables: a top-level `final` in Dart is
// lazy, so nothing would be declared until something read it — and `--help`
// would print an empty list of options.
late final Opt<bool> verbose;
late final Opt<bool> yes;
late final Opt<String> dest;
late final Opt<String> token;
late final Opt<int> workers;
late final Opt<Mode> mode;

void _declare() {
  verbose = cli.flag('verbose', alias: 'v', desc: 'Log every step');
  yes = cli.flag('yes', alias: 'y', desc: 'Skip confirmation prompts');
  dest = cli.option('out', alias: 'o', desc: 'Output directory', def: 'dist');
  token = cli.option(
    'token',
    desc: 'API token',
    env: 'API_TOKEN',
    required: true,
  );

  // A command's own options are declared on it, and read from the scope its
  // handler is given.
  final build = cli.handle('build', _build, desc: 'Build every target');
  workers = build.number(
    'concurrency',
    alias: 'c',
    desc: 'Parallel workers',
    def: 4,
  );
  mode = build.choice('mode', Mode.values, def: Mode.debug, desc: 'Build mode');

  cli.handle('clean', _clean, desc: 'Remove the output directory');
  cli.handle('report', _report, desc: 'Summarise what was built');
}

/// How a build is compiled.
enum Mode {
  /// Unoptimised, with assertions on.
  debug,

  /// Optimised.
  release,
}

void main(List<String> args) async {
  // `.env` fills in what the shell did not, so `--token` stays required in the
  // declaration while `API_TOKEN` satisfies it in practice.
  system.env.load();

  // Declare the whole interface before anything reads it: `--help`,
  // `--version`, `strict` and `require` all work off these declarations.
  _declare();

  // Anything tracked here is cleaned up on Ctrl-C as well as on a normal exit.
  system.on.exit(() async {
    log.debug('Removing scratch files...');
    await io.async.delete(io.temp('tool_').path, recursive: true);
  });

  // `run` returns the exit code: whatever the handler returned, or 64 for a
  // command line it could not make sense of.
  await system.shutdown(
    await cli.run(
      args,
      syntax: 'tool.dart <command> [options]',
      desc: 'A worked example of the CLI, console and concurrency domains.',
      version: '1.1.0',
      strict: true,
    ),
  );
}

// ---------------------------------------------------------------------------

Future<int> _build(Cli cli) async {
  if (verbose()) log.level = LogLevel.debug;

  // No fallback, no type argument, no cast: the declaration said all of it.
  final into = dest();
  final size = workers();
  final targets = cli.args.isEmpty ? const ['app', 'worker', 'cli'] : cli.args;

  writer.rule('build (${mode().name})');

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
    io.write(io.join(into, '$target.txt'), 'built ${util.time.iso()}');
    return target;
  });
  bar.done('Build finished.');

  final failed = results.where((r) => !r.ok).toList();
  writer.table(
    Table(headers: ['Target', 'Result'])..addAll([
      for (final (i, result) in results.indexed)
        [
          targets[i],
          switch (result) {
            Done() => 'ok',
            Broke(:final error) => '$error',
          },
        ],
    ]),
  );

  if (failed.isEmpty) {
    log.ok(
      'Built ${targets.length} targets into $into/ with ${token().isEmpty ? 'no' : 'an'} API token',
    );
    return 0;
  }
  log.error('${failed.length} of ${targets.length} targets failed.');
  return 1;
}

Future<int> _clean(Cli cli) async {
  final into = dest();
  if (!io.has(io.join(into, 'app.txt')) && io.find(into).isEmpty) {
    log.info('Nothing to clean.');
    return 0;
  }

  // Prompt unless --yes. Interactive input lives on the console reader.
  if (!yes()) {
    final go = await system.console.reader.confirm('Delete $into/?');
    await system.console.reader.close();
    if (!go) {
      log.warn('Cancelled.');
      return 0;
    }
  }

  final removed = await io.async.delete(into, recursive: true);
  log.ok('Removed $removed files.');
  return 0;
}

Future<int> _report(Cli cli) async {
  final into = dest();
  final files = await io.async.find(into);
  if (files.isEmpty) {
    log.warn('No build output in $into/. Run `build` first.');
    return 1;
  }

  var total = 0;
  final rows = <List<Object?>>[];
  for (final file in files) {
    final bytes = (await io.async.stat(file.path)).size;
    total += bytes;
    rows.add([
      io.base(file.path),
      util.size.format(bytes),
      util.hash.short(await io.async.read(file.path)),
    ]);
  }

  writer.table(Table(headers: ['File', 'Size', 'Algo'])..addAll(rows));
  writer.box(
    'Files  ${files.length}\nTotal  ${util.size.format(total)}',
    title: 'report',
  );
  return 0;
}

// Present a command line.
//
//   dart run example/cli.dart --help
//   dart run example/cli.dart build --mode release -c 8
//   dart run example/cli.dart clean --yes
//
// Declare the interface once and `cli.run` does the rest: parse it, print
// `--help`, reject what no declaration covers, dispatch to the handler and
// turn what it returns into an exit code.

import 'package:dart_toolkit/dart_toolkit.dart';

final log = system.console.logger;

// Declaring an option hands back the `Opt<T>` that reads it, so the name, the
// type and the default live in one place and nothing downstream repeats them.
// `--concurrency=fast` is a parse error rather than a silent 4.
//
// The declarations sit in `_declare` rather than in these initialisers: a
// top-level `final` in Dart is lazy, so nothing would be declared until
// something read it — and `--help` would print an empty list of options.
late final Opt<bool> verbose;
late final Opt<bool> yes;
late final Opt<String> dest;
late final Opt<String> token;
late final Opt<int> workers;
late final Opt<Mode> mode;

/// How a build is compiled.
enum Mode {
  /// Unoptimised, with assertions on.
  debug,

  /// Optimised.
  release,
}

void _declare() {
  verbose = cli.flag('verbose', alias: 'v', desc: 'Log every step');
  yes = cli.flag('yes', alias: 'y', desc: 'Skip confirmation prompts');
  dest = cli.option('out', alias: 'o', desc: 'Output directory', def: 'dist');

  // `env` names the variable that satisfies a required option, so `--token`
  // stays required in the declaration and `API_TOKEN` supplies it in practice.
  token = cli.option(
    'token',
    desc: 'API token',
    env: 'API_TOKEN',
    required: true,
  );

  // A command's own options are declared on it, and read the same way.
  final build = cli.handle('build', _build, desc: 'Build every target');
  workers = build.number('concurrency', alias: 'c', desc: 'Workers', def: 4);
  mode = build.choice('mode', Mode.values, def: Mode.debug, desc: 'Build mode');

  cli.handle('clean', _clean, desc: 'Remove the output directory');
}

void main(List<String> args) async {
  system.env.load(); // `.env` fills in what the shell did not set.
  _declare(); // Before anything reads it: `--help` works off the declarations.

  await system.shutdown(
    await cli.run(
      args,
      syntax: 'cli.dart <command> [options]',
      desc: 'A worked example of the cli domain.',
      version: '2.0.0',
      strict: true, // Reject switches no declaration covers.
    ),
  );
}

/// A handler returns the exit code; anything it throws becomes one too.
Future<int> _build(Cli cli) async {
  if (verbose()) log.level = LogLevel.debug;

  // No fallback, no type argument, no cast: the declaration said all of it.
  final targets = cli.args.isEmpty ? const ['app', 'worker'] : cli.args;
  log.info(
    'Building ${targets.length} targets into ${dest()}/ '
    'as ${mode().name}, ${workers()} at a time.',
  );
  log.debug('Token ${token().isEmpty ? 'missing' : 'present'}.');

  for (final target in targets) {
    io.write(io.join(dest(), '$target.txt'), 'built ${util.time.iso()}');
  }
  log.ok('Built ${targets.join(', ')}.');
  return 0;
}

Future<int> _clean(Cli cli) async {
  if (io.find(dest()).empty) {
    log.info('Nothing to clean.');
    return 0;
  }
  if (!yes()) {
    final go = await system.console.reader.confirm('Delete ${dest()}/?');
    await system.console.reader.close();
    if (!go) {
      log.warn('Cancelled.');
      return 0;
    }
  }
  log.ok('Removed ${await io.async.sweep(dest(), recursive: true)} files.');
  return 0;
}

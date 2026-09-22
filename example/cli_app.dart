/// A command-line application: subcommands, the kinds of option, and the lifecycle
/// around them.
///
///   dart run example/cli_app.dart deploy --token abc --env staging -w 8
///   dart run example/cli_app.dart deploy --help
///   dart run example/cli_app.dart status
///   dart run example/cli_app.dart --version
library;

import 'package:dart_toolkit/dart_toolkit.dart';

enum Env { dev, staging, production }

// An option is a value. Its name is written here and nowhere else, and its type is the type
// `ctx(…)` gives back: `.or(…)` and `.required()` are what make that type non-nullable.
final verbose = Opt.flag('verbose', abbr: 'v', description: 'Log every step');
final env = Opt.among('env', Env.values, abbr: 'e', description: 'Target').or(Env.staging);
final token = Opt.text('token', abbr: 't', description: 'Deployment token').required();
final workers = Opt.number('workers', abbr: 'w', description: 'Parallel workers').or(4);
final dryRun = Opt.flag('dry-run', abbr: 'd', description: 'Say what would happen and stop');

Future<void> main(List<String> args) async {
  // `verbose` is on the root, so every subcommand can read it and `-v` works anywhere.
  final cli = Cli(
    name: 'deployer',
    description: 'Ship things somewhere',
    version: '1.2.0',
    options: [verbose],
    commands: [
      CliCommand('deploy', description: 'Roll out a release', options: [env, token, workers, dryRun], handler: rollOut),
      CliCommand('status', description: 'Show what is deployed', handler: showStatus),
    ],
  );

  // Parses, dispatches, then runs the exit hooks and releases the signal handlers so the
  // process can end. A usage error prints to stderr and exits 64.
  await cli.run(args);
}

Future<void> rollOut(CliContext ctx) async {
  if (ctx(verbose)) Logger.level = LogLevel.debug;

  // `env` is an `Env`, `parallel` an `int`, `secret` a `String` — the options said so, so
  // there is no lookup, no parse and no null check here.
  final target = ctx(env);
  final parallel = ctx(workers);
  final secret = ctx(token);
  Logger.debug('token of ${secret.length} chars, $parallel workers');

  // At end of input — a pipe, CI — a prompt takes its default instead of hanging.
  if (target == Env.production && !Console.confirm('Really deploy to production?', or: false)) {
    await die('Cancelled at the prompt.', exitCode: 3);
  }

  // Runs on SIGINT, SIGTERM, `die`, and when the action returns. Returns its own removal.
  final release = onExit(() => Logger.info('released the deploy lock'));

  final stage = Logger.stages(3);

  stage('Checking the target');
  await Console.spin('Contacting ${target.name}…', () => 200.ms.delay(), done: '${target.name} is reachable');

  stage('Uploading');
  if (ctx(dryRun)) {
    Logger.warn('dry run: nothing was uploaded');
    release();
    return;
  }

  // `ctx.cancel` is this run's token, already wired to Ctrl-C. Pass it to anything that takes
  // `Cli.run` opened a `Cancel.session` holding `ctx.cancel`, so `parallelize`, `download`
  // and `retry` below stop with it and none of them is passed a token.
  final files = [for (var i = 1; i <= 12; i++) 'chunk-$i.tar.gz'];
  final progress = Console.progress(files.length, message: 'Uploading');
  final uploaded = await files.parallelize((name) async {
    await (30 + name.length * 4).ms.delay();
    progress.tick(1, name);
    return name;
  }, concurrency: parallel);
  progress.done('${uploaded.rights.length} chunks uploaded');

  stage('Reporting');
  Table.cells(
    ['setting', 'value'],
    [
      ['environment', target.name],
      ['workers', parallel],
      ['chunks', uploaded.rights.length],
      ['failed', uploaded.lefts.length],
    ],
  ).show();
  Logger.ok('Deployed to ${target.name}.');
}

Future<void> showStatus(CliContext ctx) async {
  if (ctx(verbose)) Logger.level = LogLevel.debug;
  Logger.debug('reading the deployment record');

  Table.rows(
    [
      (env: 'production', version: '1.1.9', healthy: true),
      (env: 'staging', version: '1.2.0', healthy: true),
      (env: 'dev', version: '1.2.0-rc', healthy: false),
    ].map((row) => {'env': row.env, 'version': row.version, 'healthy': row.healthy ? 'yes' : 'NO'}),
  ).show();

  // Positional arguments, and everything after a `--`, arrive as `rest`.
  if (ctx.rest.isNotEmpty) Logger.info('also asked about: ${ctx.rest.join(', ')}');
}

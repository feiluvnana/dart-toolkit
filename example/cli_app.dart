import 'package:dart_toolkit/dart_toolkit.dart';

/// A command-line application: subcommands, the four kinds of option, and the lifecycle
/// around them.
///
///   dart run example/cli_app.dart deploy --token abc --env staging -w 8
///   dart run example/cli_app.dart deploy --help
///   dart run example/cli_app.dart status
///   dart run example/cli_app.dart --version
Future<void> main(List<String> args) async {
  final cli = Cli(name: 'deployer', description: 'Ship things somewhere', version: '1.2.0')
    // Declared on the root, so every subcommand can read it and `-v` works anywhere.
    ..flag('verbose', abbr: 'v', description: 'Log every step')
    ..command(
      'deploy',
      description: 'Roll out a release',
      build: (deploy) => deploy
        ..choice('env', ['dev', 'staging', 'production'], abbr: 'e', defaultTo: 'staging', description: 'Target')
        ..option('token', abbr: 't', required: true, description: 'Deployment token')
        ..number('workers', abbr: 'w', defaultTo: 4, description: 'Parallel workers')
        ..flag('dry-run', abbr: 'd', description: 'Say what would happen and stop')
        ..action(rollOut),
    )
    ..command('status', description: 'Show what is deployed', handler: showStatus);

  // Parses, dispatches, then runs the exit hooks and releases the signal handlers so the
  // process can end. A usage error prints to stderr and exits 64.
  await cli.run(args);
}

Future<void> rollOut(CliContext ctx) async {
  if (ctx.flag('verbose')) Logger.level = LogLevel.debug;

  // A declared default or `required: true` means these cannot be missing, so they are not
  // nullable. `optionOrNull` is there for the ones that may be.
  final env = ctx.option('env');
  final workers = ctx.number('workers');
  final token = ctx.option('token');
  Logger.debug('token of ${token.length} chars, $workers workers');

  // At end of input — a pipe, CI — a prompt takes its default instead of hanging.
  if (env == 'production' && !Console.confirm('Really deploy to production?', false)) {
    await die('Cancelled at the prompt.', exitCode: 3);
  }

  // Runs on SIGINT, SIGTERM, `die`, and when the action returns. Returns its own removal.
  final release = onExit(() => Logger.info('released the deploy lock'));

  final stage = Logger.stages(3);

  stage('Checking the target');
  await Console.spin('Contacting $env…', () => 200.ms.delay(), done: '$env is reachable');

  stage('Uploading');
  if (ctx.flag('dry-run')) {
    Logger.warn('dry run: nothing was uploaded');
    release();
    return;
  }

  // `ctx.cancel` is this run's token, already wired to Ctrl-C. Pass it to anything that takes
  // one — `parallelize`, `downloadAll`, `cancelWith` — and a script needs no token of its own.
  final files = [for (var i = 1; i <= 12; i++) 'chunk-$i.tar.gz'];
  final progress = Console.progress(files.length, message: 'Uploading');
  final uploaded = await files.parallelize(
    (name) async {
      await (30 + name.length * 4).ms.delay();
      progress.tick(1, name);
      return name;
    },
    concurrency: workers,
    cancelToken: ctx.cancel,
  );
  progress.done('${uploaded.rights.length} chunks uploaded');

  stage('Reporting');
  Console.table(
    headers: ['setting', 'value'],
    rows: [
      ['environment', env],
      ['workers', workers],
      ['chunks', uploaded.rights.length],
      ['failed', uploaded.lefts.length],
    ],
  );
  Logger.ok('Deployed to $env.');
}

Future<void> showStatus(CliContext ctx) async {
  if (ctx.flag('verbose')) Logger.level = LogLevel.debug;
  Logger.debug('reading the deployment record');

  Table.records([
    (env: 'production', version: '1.1.9', healthy: true),
    (env: 'staging', version: '1.2.0', healthy: true),
    (env: 'dev', version: '1.2.0-rc', healthy: false),
  ], (row) => {'env': row.env, 'version': row.version, 'healthy': row.healthy ? 'yes' : 'NO'}).show();

  // Positional arguments, and everything after a `--`, arrive as `rest`.
  if (ctx.rest.isNotEmpty) Logger.info('also asked about: ${ctx.rest.join(', ')}');
}

import 'package:dart_toolkit/cli/cli.dart';
import 'package:dart_toolkit/util/util.dart';

void main(List<String> args) async {
  final cli = Cli(name: 'deployer', description: 'Sample Deployment Tool')
    ..choice('env', ['dev', 'staging', 'production'], abbr: 'e', defaultTo: 'production')
    ..option('token', abbr: 't', required: true, description: 'Deployment token')
    ..number('workers', abbr: 'w', defaultTo: 4)
    ..flag('dry-run', abbr: 'd', description: 'Simulate without executing')
    ..action((ctx) async {
      // Declared defaults arrive here; a required option cannot be missing.
      final env = ctx.option('env');
      final workers = ctx.number('workers');
      final isDryRun = ctx.flag('dry-run');

      final stage = Logger.stages(2);

      stage('Checking target');
      Logger.info('Deploying to $env with $workers workers (dry-run: $isDryRun)');

      stage('Rolling out');
      final progress = Console.progress(5, message: 'Deploy steps');
      for (var i = 1; i <= 5; i++) {
        await Future<void>.delayed(50.ms);
        progress.tick(1, 'Step $i');
      }
      progress.done('Deployment finished.');
    });

  // A usage error prints and exits 64; exit hooks run and the process ends when this returns.
  await cli.run(args);
}

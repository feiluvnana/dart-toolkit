import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> args) async {
  final cli = Cli(name: 'deployer', description: 'Sample Deployment Tool')
    ..option('env', abbr: 'e', defaultTo: 'production', choices: ['dev', 'staging', 'production'])
    ..number('workers', abbr: 'w', defaultTo: 4)
    ..flag('dry-run', abbr: 'd', description: 'Simulate without executing')
    ..action((ctx) async {
      final env = ctx.option('env')!;
      final workers = ctx.number('workers')!;
      final isDryRun = ctx.flag('dry-run');

      Logger.info('Deploying to $env with $workers workers (dry-run: $isDryRun)');

      final progress = Console.progress(5, message: 'Deploy steps');
      for (var i = 1; i <= 5; i++) {
        await Future<void>.delayed(50.ms);
        progress.tick(1, 'Step $i');
      }
      progress.done('Deployment finished.');
    });

  await cli.run(args);
}

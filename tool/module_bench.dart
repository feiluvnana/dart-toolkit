// What each module costs to import under `dart run file.dart`, as a delta over a bare script.
//
//   dart run tool/module_bench.dart            # every module, six rounds
//   dart run tool/module_bench.dart http html  # a subset
//   dart run tool/module_bench.dart --exit     # each probe exits, as `Cli.run` does
//
// A probe that returns from `main` also waits for the front end's last background optimisations,
// which jump in bands; one that exits does not, so `--exit` reads what is compiled more steadily.
//
// Timings drift by tens of milliseconds, so rounds alternate order and the table reports the
// median and the minimum over bare. Read the deltas, not the totals.
library;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/collection.dart';
import 'package:dart_toolkit/path.dart';
import 'package:dart_toolkit/process.dart';

const modules = [
  'core',
  'native',
  'path',
  'archive',
  'hash',
  'collection',
  'async',
  'process',
  'cli',
  'pick',
  'tui',
  'html',
  'xml',
  'xpath',
  'json',
  'torrent',
  'http',
  'scrape',
  'chrome',
  'image',
];

final targets = Arg.of<String>('modules', 'Specific modules to benchmark').many().or(modules);
final roundsOpt = Option.of<int>('rounds', 'Number of measurement rounds', short: 'r').or(6);
final exitOpt = Option.flag('exit', 'Each probe exits rather than returning from main');

void main(List<String> args) => Cli(
  'Benchmark startup / import cost per module over a bare script and over core.',
  values: [targets, roundsOpt, exitOpt],
  handler: (ctx) async {
    final selected = ctx(targets);
    final rounds = ctx(roundsOpt);
    final main = ctx(exitOpt)
        ? "import 'dart:io' as io;\nvoid main() { print(0); io.exit(0); }\n"
        : 'void main() => print(0);\n';

    await Path.tempDir((dir) async {
      final pkg = (Path.cwd / '.dart_tool' / 'package_config.json').absolute;
      await (dir / 'bare.dart').writeText(main);
      for (final m in selected) {
        await (dir / '$m.dart').writeText("import 'package:dart_toolkit/$m.dart';\n$main");
      }

      Future<int> time(String name) async {
        final clock = Stopwatch()..start();
        await Shell.run('dart', args: ['run', '--packages=$pkg', dir / '$name.dart']);
        return clock.elapsedMilliseconds;
      }

      Console.info('Warming VM cache...');
      await time('bare'); // warm the VM cache once

      final names = ['bare', ...selected];
      final samples = {for (final n in names) n: <int>[]};

      Console.info('Running $rounds benchmark rounds...');
      for (var r = 0; r < rounds; r++) {
        for (final n in r.isEven ? names : names.reversed) {
          samples[n]!.add(await time(n));
        }
      }

      int median(List<int> xs) => (xs.toList()..sort())[xs.length ~/ 2];
      int least(List<int> xs) => xs.reduce((a, b) => a < b ? a : b);
      String over(String base, String n, int Function(List<int>) f) =>
          n == base || !samples.containsKey(base) ? '—' : '+${f(samples[n]!) - f(samples[base]!)} ms';

      Console.line();
      await Table.rows([
        for (final n in names)
          {
            'import': n,
            'median': '${median(samples[n]!)} ms',
            'over bare': over('bare', n, median),
            'min over bare': over('bare', n, least),
            'over core': n == 'bare' ? '—' : over('core', n, median),
          },
      ]).show();
    });
  },
).run(args);

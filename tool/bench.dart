// What each module costs to import under `dart run file.dart`, as a delta over a bare script.
//
//   dart run tool/bench.dart            # every module, six rounds
//   dart run tool/bench.dart http html  # a subset
//
// Timings drift by tens of milliseconds, so rounds alternate order and the table reports the
// median and the minimum over bare. Read the deltas, not the totals.
library;

import 'package:dart_toolkit/dart_toolkit.dart';

const modules = ['core', 'formats', 'collection', 'async', 'cli', 'fs', 'hash', 'process', 'http', 'chrome', 'tui'];

final targets = Arg.text('modules', 'Specific modules to benchmark (default: all)').many();
final roundsOpt = Opt.number('rounds', 'Number of measurement rounds').abbr('r').or(6);

void main(List<String> args) => Cli(
  description: 'Benchmark startup / import cost per module over a bare script.',
  values: [targets, roundsOpt],
  handler: (ctx) async {
    final selectedModules = ctx(targets);
    final selected = selectedModules.isEmpty ? modules : selectedModules;
    final rounds = ctx(roundsOpt);

    await Path.tempDir((dir) async {
      final pkg = (Path.current / '.dart_tool' / 'package_config.json').absolute;
      (dir / 'bare.dart').writeTextSync('void main() => print(0);\n');
      for (final (name, lib) in [for (final m in selected) (m, m), ('barrel', 'dart_toolkit')]) {
        (dir / '$name.dart').writeTextSync("import 'package:dart_toolkit/$lib.dart';\nvoid main() => print(0);\n");
      }

      Future<int> time(String name) async {
        final sw = Stopwatch()..start();
        await run('dart', args: ['run', '--packages=${pkg.path}', (dir / '$name.dart').path], quiet: true);
        return sw.elapsedMilliseconds;
      }

      Console.info('Warming VM cache...');
      await time('bare'); // warm the VM cache once

      final names = ['bare', ...selected, 'barrel'];
      final samples = {for (final n in names) n: <int>[]};

      Console.info('Running $rounds benchmark rounds...');
      for (var r = 0; r < rounds; r++) {
        for (final n in r.isEven ? names : names.reversed) {
          samples[n]!.add(await time(n));
        }
      }

      int median(List<int> xs) => (xs.toList()..sort())[xs.length ~/ 2];
      int least(List<int> xs) => xs.reduce((a, b) => a < b ? a : b);

      final bare = samples['bare']!;
      final rows = <List<Object?>>[];

      for (final n in names) {
        final xs = samples[n]!;
        String over(int Function(List<int>) f) => n == 'bare' ? '—' : '+${f(xs) - f(bare)} ms';
        rows.add([n, '${median(xs)} ms', over(median), over(least)]);
      }

      Console.info('');
      Table.cells(['import', 'median', 'over bare', 'min over'], rows).show();
    });
  },
).run(args);

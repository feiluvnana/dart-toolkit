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
//
// Plain `dart:` only (see tool/build_native.dart): probes import package topics,
// but this driver must run with no package surface of its own.
library;

import 'dart:io';

const modules = [
  'core',
  'native',
  'path',
  'archive',
  'hash',
  'async',
  'process',
  'cli',
  'tui',
  'html',
  'json',
  'http',
  'chrome',
  'image',
];

Future<void> main(List<String> args) async {
  final selected = <String>[];
  var rounds = 6;
  var exit = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--exit':
        exit = true;
      case '--rounds' || '-r':
        if (++i >= args.length) _fail('--rounds needs a number');
        rounds = int.tryParse(args[i]) ?? _fail('rounds is not a number: ${args[i]}');
      case '--help' || '-h':
        stdout.writeln('usage: dart run tool/module_bench.dart [modules...] [--exit] [--rounds N]');
        return;
      default:
        if (args[i].startsWith('-')) _fail('unknown flag ${args[i]} (see --help)');
        selected.add(args[i]);
    }
  }
  for (final m in selected) {
    if (!modules.contains(m)) _fail('no module $m (see --help)');
  }
  final subset = selected.isEmpty ? modules : selected;
  final main = exit ? "import 'dart:io' as io;\nvoid main() { print(0); io.exit(0); }\n" : 'void main() => print(0);\n';

  final dir = await Directory.systemTemp.createTemp('module_bench_');
  try {
    final pkg =
        '${Directory.current.path}${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}package_config.json';
    await File('${dir.path}${Platform.pathSeparator}bare.dart').writeAsString(main);
    for (final m in subset) {
      await File(
        '${dir.path}${Platform.pathSeparator}$m.dart',
      ).writeAsString("import 'package:dart_toolkit/$m.dart';\n$main");
    }

    Future<int> time(String name) async {
      final clock = Stopwatch()..start();
      final r = await Process.run(Platform.resolvedExecutable, [
        'run',
        '--packages=$pkg',
        '${dir.path}${Platform.pathSeparator}$name.dart',
      ]);
      if (r.exitCode != 0) _fail('probe $name failed:\n${r.stderr}');
      return clock.elapsedMilliseconds;
    }

    stdout.writeln('Warming VM cache...');
    await time('bare'); // warm the VM cache once

    final names = ['bare', ...subset];
    final samples = {for (final n in names) n: <int>[]};
    stdout.writeln('Running $rounds benchmark rounds...');
    for (var r = 0; r < rounds; r++) {
      for (final n in r.isEven ? names : names.reversed) {
        samples[n]!.add(await time(n));
      }
    }

    int median(List<int> xs) => (xs.toList()..sort())[xs.length ~/ 2];
    int least(List<int> xs) => xs.reduce((a, b) => a < b ? a : b);
    String over(String base, String n, int Function(List<int>) f) =>
        n == base || !samples.containsKey(base) ? '—' : '+${f(samples[n]!) - f(samples[base]!)} ms';

    stdout.writeln('import        median   over bare  min over bare  over core');
    for (final n in names) {
      stdout.writeln(
        '${n.padRight(12)}  ${'${median(samples[n]!)} ms'.padRight(7)}  '
        '${over('bare', n, median).padRight(9)}  ${over('bare', n, least).padRight(13)}  ${n == 'bare' ? '—' : over('core', n, median)}',
      );
    }
  } finally {
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

Never _fail(String s) {
  stderr.writeln('error: $s');
  exit(1);
}

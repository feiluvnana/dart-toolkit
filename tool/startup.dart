// What each module costs to import under `dart run file.dart`, as a delta over a bare script.
//
//   dart run tool/startup.dart            # every module, six rounds
//   dart run tool/startup.dart http html  # a subset
//
// Timings drift by tens of milliseconds, so rounds alternate order and the table reports the
// median and the minimum over bare. Read the deltas, not the totals.
import 'dart:io';

const modules = ['core', 'formats', 'collection', 'async', 'cli', 'fs', 'hash', 'process', 'http', 'chrome'];

Future<void> main(List<String> args) async {
  final selected = args.isEmpty ? modules : args;
  final dir = Directory.systemTemp.createTempSync('toolkit_startup_');
  final pkg = File('.dart_tool/package_config.json').absolute.path;
  try {
    File('${dir.path}/bare.dart').writeAsStringSync('void main() => print(0);\n');
    for (final (name, lib) in [for (final m in selected) (m, m), ('barrel', 'dart_toolkit')]) {
      File(
        '${dir.path}/$name.dart',
      ).writeAsStringSync("import 'package:dart_toolkit/$lib.dart';\nvoid main() => print(0);\n");
    }

    Future<int> time(String name) async {
      final sw = Stopwatch()..start();
      await Process.run('dart', ['run', '--packages=$pkg', '${dir.path}/$name.dart']);
      return sw.elapsedMilliseconds;
    }

    await time('bare'); // warm the VM cache once
    final names = ['bare', ...selected, 'barrel'];
    final samples = {for (final n in names) n: <int>[]};
    const rounds = 6;
    for (var r = 0; r < rounds; r++) {
      for (final n in r.isEven ? names : names.reversed) {
        samples[n]!.add(await time(n));
      }
    }
    int median(List<int> xs) => (xs.toList()..sort())[xs.length ~/ 2];
    int least(List<int> xs) => xs.reduce((a, b) => a < b ? a : b);
    final bare = samples['bare']!;
    stdout.writeln(
      '${'import'.padRight(12)} ${'median'.padLeft(7)} ${'over bare'.padLeft(10)} ${'min over'.padLeft(9)}',
    );
    for (final n in names) {
      final xs = samples[n]!;
      String over(int Function(List<int>) f) => n == 'bare' ? '—' : '+${f(xs) - f(bare)}';
      stdout.writeln(
        '${n.padRight(12)} ${'${median(xs)}'.padLeft(7)} ${over(median).padLeft(10)} ${over(least).padLeft(9)}',
      );
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
}

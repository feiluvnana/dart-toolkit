// Measures what each module costs to import under `dart run`, as a delta against a
// bare script, so a change to a module's closure is measured rather than argued.
//
//   dart run tool/startup.dart            # every module, two rounds
//   dart run tool/startup.dart http html  # a subset
//
// Timings drift by tens of milliseconds between runs; read the deltas, not the totals.
//
// This measures `dart run file.dart`. A package executable — `dart run dart_toolkit:keybox` —
// goes through pub's incremental snapshot and pays none of this after the first run.
import 'dart:io';

const modules = ['core', 'formats', 'collection', 'async', 'cli', 'fs', 'hash', 'process', 'http'];

Future<void> main(List<String> args) async {
  final selected = args.isEmpty ? modules : args;
  final dir = Directory.systemTemp.createTempSync('toolkit_startup_');
  final pkg = File('.dart_tool/package_config.json').absolute.path;
  try {
    File('${dir.path}/bare.dart').writeAsStringSync('void main() => print(0);\n');
    for (final m in selected) {
      File(
        '${dir.path}/$m.dart',
      ).writeAsStringSync("import 'package:dart_toolkit/$m.dart';\nvoid main() => print(0);\n");
    }
    File(
      '${dir.path}/barrel.dart',
    ).writeAsStringSync("import 'package:dart_toolkit/dart_toolkit.dart';\nvoid main() => print(0);\n");

    Future<int> time(String name) async {
      final sw = Stopwatch()..start();
      await Process.run('dart', ['run', '--packages=$pkg', '${dir.path}/$name.dart']);
      return sw.elapsedMilliseconds;
    }

    await time('bare'); // warm the VM cache once
    final names = ['bare', ...selected, 'barrel'];
    final totals = {for (final n in names) n: 0};
    const rounds = 2;
    for (var r = 0; r < rounds; r++) {
      for (final n in names) {
        totals[n] = totals[n]! + await time(n);
      }
    }
    final bare = totals['bare']! ~/ rounds;
    stdout.writeln('${'import'.padRight(12)} ${'ms'.padLeft(6)} ${'over bare'.padLeft(10)}');
    for (final n in names) {
      final ms = totals[n]! ~/ rounds;
      stdout.writeln('${n.padRight(12)} ${'$ms'.padLeft(6)} ${(n == 'bare' ? '—' : '+${ms - bare}').padLeft(10)}');
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
}

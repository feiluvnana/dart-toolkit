import 'dart:convert';
import 'dart:io';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/path.dart';
import 'chrome_bench.dart';
import 'collection_bench.dart';
import 'formats_bench.dart';
import 'framework.dart';
import 'fs_async_native_bench.dart';
import 'hash_bench.dart';
import 'html_bench.dart';
import 'http_fs_process_bench.dart';
import 'image_bench.dart';
import 'io_bench.dart';
import 'torrent_bench.dart';

final baselinePath = (Path('tool') / 'bench' / 'baseline.json').path;

final modulesArg = Arg.of<String>('modules', 'Filter by module name').many().or(const <String>[]);
final roundsOpt = Option.of<int>('rounds', 'Number of measurement rounds', short: 'r').or(5);
final checkFlag = Option.flag('check', 'Check against baseline.json and fail on regression');
final saveBaselineFlag = Option.flag('save-baseline', 'Save results to baseline.json');
final caseOpt = Option.of<String>('case', 'Run only this case and print its result as JSON (used per child process)');

List<BenchmarkCase> get _allCases => [
  ...createHtmlBenchmarks(),
  ...createFormatsBenchmarks(),
  ...createCollectionBenchmarks(),
  ...createHashBenchmarks(),
  ...createImageBenchmarks(),
  ...createFsAsyncNativeBenchmarks(),
  ...createHttpFsProcessBenchmarks(),
  ...createIoBenchmarks(),
  ...createChromeBenchmarks(),
  ...createTorrentBenchmarks(),
];

/// Runs [name] in a fresh process, so its peak RSS and its JIT and GC state are its own.
Future<BenchmarkResult> _inChild(String name, int rounds) async {
  final aot = const bool.fromEnvironment('dart.vm.product');
  final res = await Process.run(Platform.resolvedExecutable, [
    if (!aot) Platform.script.toFilePath(),
    '--case',
    name,
    '--rounds',
    '$rounds',
  ]);
  if (res.exitCode != 0) throw StateError('benchmark $name failed (exit ${res.exitCode}): ${res.stderr}');
  final json = (res.stdout as String).trim().split('\n').last;
  return BenchmarkResult.fromJson(jsonDecode(json) as Map<String, dynamic>);
}

void main(List<String> args) => Cli(
  'Per-module throughput benchmarks against references and baseline.',
  values: [modulesArg, roundsOpt, checkFlag, saveBaselineFlag, caseOpt],
  handler: (ctx) async {
    final filter = ctx(modulesArg);
    final rounds = ctx(roundsOpt).toInt();
    final check = ctx(checkFlag);
    final save = ctx(saveBaselineFlag);

    if (ctx(caseOpt) case final only?) {
      final harness = BenchmarkHarness()..addAll(_allCases.where((c) => c.name == only));
      if (harness.cases.isEmpty) Console.exit('No benchmark case named $only');
      stdout.writeln(jsonEncode((await harness.run(rounds: rounds)).single.toJson()));
      return;
    }

    final filtered = filter.isEmpty
        ? _allCases
        : _allCases.where((c) => filter.any((f) => c.module.contains(f) || c.name.contains(f))).toList();
    if (filtered.isEmpty) Console.exit('No benchmark cases matched filter: ${filter.join(', ')}');

    Console.info('Running ${filtered.length} benchmark cases ($rounds rounds each, one process per case)...');
    final results = [for (final c in filtered) await _inChild(c.name, rounds)];

    Map<String, BenchmarkResult>? baseline;
    final bFile = File(baselinePath);
    if (bFile.existsSync()) {
      try {
        final jsonMap = jsonDecode(bFile.readAsStringSync()) as Map<String, dynamic>;
        baseline = {for (final e in jsonMap.entries) e.key: BenchmarkResult.fromJson(e.value as Map<String, dynamic>)};
      } catch (e) {
        Console.warn('Could not read baseline: $e');
      }
    }

    Console.info('');
    await BenchmarkHarness.printResults(results, baseline: baseline);

    if (save) {
      final jsonMap = {for (final r in results) r.name: r.toJson()};
      bFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(jsonMap));
      Console.info('Saved baseline to $baselinePath');
    }

    if (check && baseline != null) {
      var failing = BenchmarkHarness.regressions(results, baseline);
      // A case over the line once is often the machine; it fails only if it is over twice more.
      for (var retry = 0; retry < 2 && failing.isNotEmpty; retry++) {
        final again = [for (final r in failing) await _inChild(r.name, rounds)];
        failing = BenchmarkHarness.regressions(again, baseline);
      }
      if (failing.isNotEmpty) {
        for (final r in failing) {
          Console.error(BenchmarkHarness.describeRegression(r, baseline[r.name]!));
        }
        Console.exit('Benchmark regression check failed!');
      }
      Console.info('All benchmarks within baseline limits.');
    }
  },
).run(args);

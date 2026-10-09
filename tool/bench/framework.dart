import 'dart:io';
import 'package:dart_toolkit/collection.dart';

/// A single benchmark result measurement.
final class BenchmarkResult {
  final String name;
  final String module;
  final double timeUs;
  final double throughput;
  final String throughputUnit;
  final int peakRss;
  final double? referenceTimeUs;
  final double? referenceThroughput;

  const BenchmarkResult({
    required this.name,
    required this.module,
    required this.timeUs,
    required this.throughput,
    required this.throughputUnit,
    required this.peakRss,
    this.referenceTimeUs,
    this.referenceThroughput,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'module': module,
    'timeUs': timeUs,
    'throughput': throughput,
    'throughputUnit': throughputUnit,
    'peakRss': peakRss,
    if (referenceTimeUs != null) 'referenceTimeUs': referenceTimeUs,
    if (referenceThroughput != null) 'referenceThroughput': referenceThroughput,
  };

  factory BenchmarkResult.fromJson(Map<String, dynamic> json) => BenchmarkResult(
    name: json['name'] as String,
    module: json['module'] as String,
    timeUs: (json['timeUs'] as num).toDouble(),
    throughput: (json['throughput'] as num).toDouble(),
    throughputUnit: json['throughputUnit'] as String,
    peakRss: (json['peakRss'] as num).toInt(),
    referenceTimeUs: (json['referenceTimeUs'] as num?)?.toDouble(),
    referenceThroughput: (json['referenceThroughput'] as num?)?.toDouble(),
  );
}

/// Base class for a single benchmark case.
abstract class BenchmarkCase {
  final String name;
  final String module;
  final String throughputUnit;

  const BenchmarkCase(this.name, {required this.module, this.throughputUnit = 'ops/s'});

  Future<void> setup() async {}
  Future<void> teardown() async {}

  /// Runs the benchmark workload for [iterations] times and returns total units processed
  /// (e.g. bytes or items).
  Future<int> run(int iterations);

  /// Runs the reference implementation if available.
  Future<int>? runReference(int iterations) => null;

  /// Number of iterations per round.
  int get iterations => 100;

  /// Warmup iterations.
  int get warmupIterations => iterations ~/ 5;
}

/// Benchmark harness that executes cases and formats results.
class BenchmarkHarness {
  final List<BenchmarkCase> cases = [];

  void add(BenchmarkCase c) => cases.add(c);
  void addAll(Iterable<BenchmarkCase> cs) => cases.addAll(cs);

  Future<List<BenchmarkResult>> run({int rounds = 5, bool verbose = false}) async {
    final results = <BenchmarkResult>[];

    for (final c in cases) {
      await c.setup();
      try {
        // Warmup
        if (c.warmupIterations > 0) {
          await c.run(c.warmupIterations);
          final ref = c.runReference(c.warmupIterations);
          if (ref != null) await ref;
        }

        final timeSamples = <double>[];
        final throughputSamples = <double>[];
        final refTimeSamples = <double>[];
        final refThroughputSamples = <double>[];

        for (var r = 0; r < rounds; r++) {
          // Alternating run order between test and reference
          if (r.isEven) {
            final sw = Stopwatch()..start();
            final units = await c.run(c.iterations);
            sw.stop();
            final us = sw.elapsedMicroseconds.toDouble() / c.iterations;
            timeSamples.add(us);
            final sec = sw.elapsedMicroseconds / 1000000.0;
            throughputSamples.add(sec > 0 ? units / sec : 0);

            final rsw = Stopwatch()..start();
            final refFuture = c.runReference(c.iterations);
            if (refFuture != null) {
              final runits = await refFuture;
              rsw.stop();
              final rus = rsw.elapsedMicroseconds.toDouble() / c.iterations;
              refTimeSamples.add(rus);
              final rsec = rsw.elapsedMicroseconds / 1000000.0;
              refThroughputSamples.add(rsec > 0 ? runits / rsec : 0);
            }
          } else {
            final rsw = Stopwatch()..start();
            final refFuture = c.runReference(c.iterations);
            if (refFuture != null) {
              final runits = await refFuture;
              rsw.stop();
              final rus = rsw.elapsedMicroseconds.toDouble() / c.iterations;
              refTimeSamples.add(rus);
              final rsec = rsw.elapsedMicroseconds / 1000000.0;
              refThroughputSamples.add(rsec > 0 ? runits / rsec : 0);
            }

            final sw = Stopwatch()..start();
            final units = await c.run(c.iterations);
            sw.stop();
            final us = sw.elapsedMicroseconds.toDouble() / c.iterations;
            timeSamples.add(us);
            final sec = sw.elapsedMicroseconds / 1000000.0;
            throughputSamples.add(sec > 0 ? units / sec : 0);
          }
        }

        double median(List<double> xs) {
          final sorted = xs.toList()..sort();
          return sorted[sorted.length ~/ 2];
        }

        final medTime = median(timeSamples);
        final medThroughput = median(throughputSamples);
        final medRefTime = refTimeSamples.isNotEmpty ? median(refTimeSamples) : null;
        final medRefThroughput = refThroughputSamples.isNotEmpty ? median(refThroughputSamples) : null;
        final rss = ProcessInfo.maxRss;

        results.add(
          BenchmarkResult(
            name: c.name,
            module: c.module,
            timeUs: medTime,
            throughput: medThroughput,
            throughputUnit: c.throughputUnit,
            peakRss: rss,
            referenceTimeUs: medRefTime,
            referenceThroughput: medRefThroughput,
          ),
        );
      } finally {
        await c.teardown();
      }
    }

    return results;
  }

  static Future<void> printResults(List<BenchmarkResult> results, {Map<String, BenchmarkResult>? baseline}) async {
    final rows = <List<String>>[];
    for (final r in results) {
      final base = baseline?[r.name];
      final timeStr = r.timeUs < 1000
          ? '${r.timeUs.toStringAsFixed(1)} µs'
          : '${(r.timeUs / 1000).toStringAsFixed(2)} ms';

      final tpStr = r.throughputUnit == 'MB/s'
          ? '${(r.throughput / (1024 * 1024)).toStringAsFixed(2)} MB/s'
          : '${r.throughput.toStringAsFixed(0)} ${r.throughputUnit}';

      String deltaStr = '—';
      if (base != null) {
        final pct = slowdown(r, base);
        final sign = pct > 0 ? '+' : '';
        deltaStr = '$sign${pct.toStringAsFixed(1)}%';
      }

      String refStr = '—';
      if (r.referenceTimeUs != null && r.referenceTimeUs! > 0) {
        final speedup = r.referenceTimeUs! / r.timeUs;
        refStr = '${speedup.toStringAsFixed(2)}x';
      }

      final rssMb = (r.peakRss / (1024 * 1024)).toStringAsFixed(1);

      rows.add([r.module, r.name, timeStr, tpStr, refStr, deltaStr, '$rssMb MB']);
    }

    await Table.cells(['module', 'case', 'time', 'throughput', 'vs ref', 'vs baseline', 'peak RSS'], rows).show();
  }

  /// How much slower [r] is than [base], in percent: against its reference when both have one,
  /// which cancels the machine's load, else in absolute time.
  static double slowdown(BenchmarkResult r, BenchmarkResult base) {
    if (r.referenceTimeUs case final ref? when ref > 0 && (base.referenceTimeUs ?? 0) > 0) {
      return ((r.timeUs / ref) / (base.timeUs / base.referenceTimeUs!) - 1) * 100.0;
    }
    return (r.timeUs / base.timeUs - 1) * 100.0;
  }

  /// The results slower than their baseline beyond the threshold: 10% for a case with a
  /// reference (a ratio), 25% for one without (absolute time drifts with the machine).
  static List<BenchmarkResult> regressions(List<BenchmarkResult> results, Map<String, BenchmarkResult> baseline) => [
    for (final r in results)
      if (baseline[r.name] case final base?)
        if (slowdown(r, base) > (r.referenceTimeUs != null && base.referenceTimeUs != null ? 10.0 : 25.0)) r,
  ];

  /// One line naming [r]'s case, its slowdown and what it was measured against.
  static String describeRegression(BenchmarkResult r, BenchmarkResult base) {
    final against = r.referenceTimeUs != null && base.referenceTimeUs != null ? 'vs its reference' : 'absolute';
    return 'REGRESSION in ${r.module}/${r.name}: ${slowdown(r, base).toStringAsFixed(1)}% slower ($against)';
  }
}

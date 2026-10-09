part of '../core.dart';

/// Work that can outlive the program: a `Pool` whose jobs a runner process serves. `Cli(pools:)`
/// takes these, so a launch as a runner serves them instead of calling the handler.
///
/// {@category Concurrency}
abstract interface class Detachable {
  /// Where its jobs are kept: a folder for jobs to outlive the program.
  Store get store;
}

/// Not API: how `cli` reaches `async`'s `Pool.serve` without importing it. A pool sets [serve]
/// when it is made.
abstract final class DetachableBridge {
  /// Serves [pools] when this process is a runner (it then never returns), else returns at once.
  static Future<void> Function(List<Detachable> pools)? serve;
}

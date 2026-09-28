part of '../../async.dart';

/// Extension on closures to offload execution to a background [Isolate].
///
/// {@category Concurrency}
extension FunctionIsolateExtensions<T> on FutureOr<T> Function() {
  /// Executes this computation on a separate background [Isolate] using `Isolate.run`.
  Future<T> isolate() => Isolate.run(this);
}

import 'dart:ffi';
import 'package:dart_toolkit/async.dart';
import 'package:dart_toolkit/src/native.dart';
import 'framework.dart';

class AsyncParallelizeBenchmark extends BenchmarkCase {
  AsyncParallelizeBenchmark() : super('async_parallelize_500', module: 'async', throughputUnit: 'ops/s');

  @override
  int get iterations => 100;

  @override
  Future<int> run(int count) async {
    final items = List.generate(500, (i) => i);
    for (var i = 0; i < count; i++) {
      final results = await items.parallelize((n) async => n * 2, concurrency: 8);
      if (results.length != 500) throw StateError('fail');
    }
    return count;
  }
}

class NativeFfiBenchmark extends BenchmarkCase {
  NativeFfiBenchmark() : super('native_ffi_call_10k', module: 'native', throughputUnit: 'ops/s');

  late int Function() _versionFn;

  @override
  Future<void> setup() async {
    _versionFn = NativeBridge.main.require().lookupFunction<Uint32 Function(), int Function()>('tk_version');
  }

  @override
  int get iterations => 50;

  @override
  Future<int> run(int count) async {
    for (var i = 0; i < count; i++) {
      for (var j = 0; j < 5000; j++) {
        final ver = _versionFn();
        if (ver <= 0) throw StateError('fail');
      }
    }
    return count;
  }
}

List<BenchmarkCase> createFsAsyncNativeBenchmarks() {
  return [AsyncParallelizeBenchmark(), NativeFfiBenchmark()];
}

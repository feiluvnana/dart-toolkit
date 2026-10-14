/// pool: `runAll` fans CPU work over worker isolates, `map` fans I/O out on this one; both keep order.
///
/// `dart run examples/pool.dart`
library;

import 'package:dart_toolkit/pool.dart';

int fib(int n) => n < 2 ? n : fib(n - 1) + fib(n - 2);

Future<void> main() async {
  print(await Pool.runAll([30, 31, 32, 33], fib)); // on workers
  print(await Pool.map(['a', 'b', 'c'], (s) async => s.toUpperCase(), limit: 2)); // on this isolate
}

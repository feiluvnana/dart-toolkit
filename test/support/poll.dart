import 'dart:async';

/// Wait until [test] holds, checking every 20 ms, for at most [timeout];
/// returns whether it held. Use instead of a fixed sleep before an assert.
Future<bool> eventually(FutureOr<bool> Function() test, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    if (await test()) return true;
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

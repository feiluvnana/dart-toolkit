/// console: spinners, bars and log lines on stderr (stdout stays for data); prompts return their `or` when
/// stdin is closed. Try `dart run examples/console.dart < /dev/null`.
///
/// `dart run examples/console.dart`
library;

import 'package:dart_toolkit/console.dart';

Future<void> main() async {
  final n = await Console.spin('warming up', Future.delayed(Duration(milliseconds: 600), () => 42));
  final bar = Console.bar(n, label: 'working');
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration(milliseconds: 15));
    bar.tick();
    if (i == 20) Console.log('halfway there');
  }
  await bar.close();
  final name = await Console.ask('Name?', or: 'Ada');
  print('hello $name');
}

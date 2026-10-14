/// shell: run programs without a shell (a non-zero exit is a value); filter a stream through one.
///
/// `dart run examples/shell.dart`
library;

import 'package:dart_toolkit/shell.dart';

Future<void> main() async {
  print(await Shell.run(['echo', 'hello']).text());
  final out = await Shell.run(['sh', '-c', 'echo oops >&2; exit 3']);
  print('code=${out.code()} ok=${out.ok()} err=${out.err().trim()}');
  print(await (Reader.of('b\na\nc\n'.codeUnits) | Shell.filter(['sort'])).text());
}

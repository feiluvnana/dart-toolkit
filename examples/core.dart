/// core: any class with one member is a Reader, Writer or Pipe, and they compose with `|` and `>`.
///
/// `dart run examples/core.dart`
library;

import 'package:dart_toolkit/core.dart';

final class Upper with Pipe {
  @override
  Stream<List<int>> transform(Stream<List<int>> input) =>
      input.map((chunk) => [for (final b in chunk) b >= 97 && b <= 122 ? b - 32 : b]);
}

final class Count implements Writer {
  var bytes = 0;
  @override
  Future<void> consume(Stream<List<int>> input) async {
    await for (final chunk in input) {
      bytes += chunk.length;
    }
  }
}

Future<void> main() async {
  final count = Count();
  await (Reader.of('hello pipes'.codeUnits) | Upper() > count);
  print('${count.bytes} bytes through Upper');
  print(await (Reader.of('hello pipes'.codeUnits) | Upper()).text()); // HELLO PIPES
}

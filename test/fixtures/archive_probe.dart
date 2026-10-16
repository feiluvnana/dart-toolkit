// Child of the archive interrupt test: unarchives the archive at args[0]
// into args[1], printing `ready` once the input is read and the decode
// runs on its isolate, then is interrupted.
import 'dart:io';

import 'package:dart_toolkit/archive.dart';

Future<void> main(List<String> args) async {
  final [archive, dir] = args;
  Stream<List<int>> input() async* {
    yield* File(archive).openRead();
    stdout.writeln('ready');
  }

  await Archive.unarchive(dir).consume(input());
  stdout.writeln('finished');
}

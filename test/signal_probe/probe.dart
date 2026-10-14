// Child of the archive/fs interrupt tests: starts a write that never
// finishes, prints `ready`, and waits to be interrupted.
import 'dart:io';

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';

Stream<List<int>> _hang(List<int> first) async* {
  yield first;
  stdout.writeln('ready');
  await Future<void>.delayed(const Duration(seconds: 30));
}

List<int> _tarHeader() {
  final b = List<int>.filled(512, 0);
  b.setRange(0, 5, 'a.bin'.codeUnits);
  b.setRange(100, 107, '0000644'.codeUnits);
  b.setRange(124, 135, '00000001000'.codeUnits);
  b[156] = 0x30;
  b.setRange(257, 263, 'ustar\x00'.codeUnits);
  b.setRange(148, 156, List.filled(8, 0x20));
  final sum = b.fold<int>(0, (a, c) => a + c);
  b.setRange(148, 155, '${sum.toRadixString(8).padLeft(6, '0')}\x00'.codeUnits);
  return b;
}

Future<void> main(List<String> args) async {
  final [mode, dir] = args;
  if (mode == 'write') {
    await Fs.file('$dir/out.bin').consume(_hang([1, 2, 3]));
  } else {
    await Archive.unarchive('$dir/out').consume(_hang([..._tarHeader(), ...List.filled(100, 7)]));
  }
}

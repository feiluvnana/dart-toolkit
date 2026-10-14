/// cli + pool + hash + fs: `dir` is an argument, the files are hashed on worker isolates.
///
/// `dart run examples/combo_cli_pool_hash.dart lib --algo sha1`
library;

import 'dart:io' show exitCode;

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/pool.dart';

Future<String> digest((String algo, String path) job) async {
  final h = job.$1 == 'sha1' ? Hash.sha1() : Hash.sha256();
  await (Fs.file(job.$2) > h);
  return h.hex();
}

Future<void> main(List<String> args) async {
  final algo = Opt<String>('algo', 'sha1 or sha256.', short: 'a', or: 'sha256');
  final dir = Arg<String>('dir', 'Folder to hash.', or: 'lib');
  exitCode = await Command(
    'hashdir',
    'Checksum every file in a folder.',
    params: [algo, dir],
    handler: (c) async {
      final files = [
        for (final e in await Fs.dir(c(dir)).list(recursive: true))
          if (e is File) e.path(),
      ];
      final sums = await Pool.runAll([for (final f in files) (c(algo), f)], digest);
      for (final (i, f) in files.indexed.take(5)) {
        print('${sums[i].substring(0, 12)}  $f');
      }
      print('${files.length} files hashed with ${c(algo)}');
    },
  ).run(args);
}

/// hash: one Hasher is a digest, a writer and a pipe, so a file can be stored and checksummed in one pass.
///
/// `dart run examples/hash.dart`
library;

import 'dart:io' show Directory;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/hash.dart';

Future<void> main() async {
  print(Hash.sha256().add('hello').hex());
  final dir = Fs.dir(Directory.systemTemp.createTempSync('hash_example').path);
  final src = await dir.file('a.txt').write('hello');
  final h = Hash.md5();
  await (src | h > dir.file('copy.txt')); // tee: copy and checksum in one pass
  print('copy md5 ${h.hex()}');
  final w = Hash.sha1();
  await (src > w); // as a writer
  print('sha1 ${w.hex()}');
  await dir.delete();
}

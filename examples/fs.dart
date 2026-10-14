/// fs: files, folders and links as values; writes are atomic and create parents.
///
/// `dart run examples/fs.dart`
library;

import 'dart:io' show Directory;

import 'package:dart_toolkit/fs.dart';

Future<void> main() async {
  final dir = Fs.dir(Directory.systemTemp.createTempSync('fs_example').path);
  await dir.file('notes/a.txt').write('one\n');
  await dir.file('notes/a.txt').append('two\n');
  await dir.file('notes/a.txt').copy(dir.file('b.txt').path());
  print(await dir.file('b.txt').text());
  for (final e in await dir.list(recursive: true)) {
    print(switch (e) {
      File f => 'file ${f.name()} ${await f.size()} bytes',
      Dir d => 'dir  ${d.name()}',
      Link l => 'link ${l.name()}',
    });
  }
  await dir.delete();
  print('gone: ${!await dir.exists()}');
}

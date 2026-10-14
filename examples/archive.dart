/// archive: pack a folder into zip/tar/tgz, unpack into another, gzip any stream.
///
/// `dart run examples/archive.dart`
library;

import 'dart:io' show Directory;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';

Future<void> main() async {
  final tmp = Fs.dir(Directory.systemTemp.createTempSync('archive_example').path);
  await tmp.file('site/index.html').write('<h1>hi</h1>');
  await tmp.file('site/css/app.css').write('h1{color:red}');

  await (Archive.pack(tmp.dir('site').path(), .tgz) > tmp.file('site.tgz'));
  await (tmp.file('site.tgz') > Archive.unpack(tmp.dir('out').path()));
  print((await tmp.dir('out').list(recursive: true)).map((e) => e.name()).toList());

  await (tmp.file('site/index.html') | Archive.gzip() > tmp.file('index.gz'));
  print(await (tmp.file('index.gz') | Archive.gunzip()).text());
  await tmp.delete();
}

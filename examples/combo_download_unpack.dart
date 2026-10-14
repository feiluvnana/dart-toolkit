/// http | bar | hash > fs > archive: download a tarball with progress and a checksum, then unpack it.
/// A loopback server hands out a generated tgz.
///
/// `dart run examples/combo_download_unpack.dart`
library;

import 'dart:io' show Directory, HttpServer;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/http.dart';

Future<void> main() async {
  final tmp = Fs.dir(Directory.systemTemp.createTempSync('combo_unpack').path);
  for (var i = 0; i < 20; i++) {
    await tmp.file('src/file$i.txt').write('content $i\n' * 5000);
  }
  final tgz = await Archive.pack(tmp.dir('src').path(), .tgz).bytes();
  final server = await HttpServer.bind('localhost', 0);
  server.listen((req) async {
    req.response.headers.contentLength = tgz.length;
    req.response.add(tgz);
    await req.response.close();
  });

  final res = await Http.get('http://localhost:${server.port}/release.tgz', check: true), sha = Hash.sha256();
  final file = tmp.file('release.tgz');
  await (res | Console.bar(res.size(), label: 'release.tgz') | sha > file);
  print('sha256 ${sha.hex()}');
  await (file > Archive.unpack(tmp.dir('vendor').path()));
  print('unpacked ${(await tmp.dir('vendor').list()).length} files');
  await server.close(force: true);
  await tmp.delete();
}

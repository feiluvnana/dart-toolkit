// Pinned tool downloads against a loopback server, and the user cache.
import 'dart:io' hide File;
import 'dart:io' as io show File;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/src/cache.dart' as cache;
import 'package:dart_toolkit/src/media.dart' as media;
import 'package:dart_toolkit/src/tool_fetch.dart' as fetch;
import 'package:test/test.dart';

import 'support/child.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  late String url;
  final served = <String, List<int>>{};
  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('tool_test');
    await Fs.file('${tmp.path}/src/bin/tool').write('#!/bin/sh\necho hi\n');
    await (Archive.archive(['bin'], dir: '${tmp.path}/src') > Fs.file('${tmp.path}/tool.zip'));
    served['/tool.zip'] = await io.File('${tmp.path}/tool.zip').readAsBytes();
    served['/raw'] = 'raw tool'.codeUnits;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}';
    server.listen((r) {
      final body = served[r.uri.path];
      r.response.statusCode = body == null ? 404 : 200;
      if (body != null) r.response.add(body);
      r.response.close();
    });
  });
  tearDownAll(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  String sha(List<int> b) => Hash.sha256().addBytes(b).hex();

  Future<Directory> fresh(String name) => Directory('${tmp.path}/$name').create(recursive: true);

  group('T1: tool_fetch', () {
    test('unpacks a zip whose sha256 matches', () async {
      final dir = await fresh('ok');
      await fetch.fetch('$url/tool.zip', sha(served['/tool.zip']!), raw: false, dir: dir.path, name: 'tool');
      expect(await io.File('${dir.path}/bin/tool').readAsString(), contains('echo hi'));
    });

    test('a zip that does not match its sha256 unpacks nothing', () async {
      final dir = await fresh('bad');
      await expectLater(
        fetch.fetch('$url/tool.zip', '0' * 64, raw: false, dir: dir.path, name: 'tool'),
        throwsA(anything),
      );
      expect(dir.listSync(recursive: true), isEmpty);
    });

    test('a raw download is written only when its sha256 matches', () async {
      final dir = await fresh('raw');
      await expectLater(
        fetch.fetch('$url/raw', '0' * 64, raw: true, dir: dir.path, name: 'tool'),
        throwsA(isA<ContentException>()),
      );
      expect(dir.listSync(), isEmpty);
      await fetch.fetch('$url/raw', sha(served['/raw']!), raw: true, dir: dir.path, name: 'tool');
      expect(await io.File('${dir.path}/tool').readAsString(), 'raw tool');
    });

    test('A3: the isolate reports a failure as text, success as null', () async {
      final dir = await fresh('iso');
      expect(
        await cache.fetchInIsolate('tool_fetch.dart', ['$url/missing', '0' * 64, 'raw', dir.path, 'tool']),
        contains('404'),
      );
      expect(await cache.fetchInIsolate('tool_fetch.dart', ['$url/raw', sha(served['/raw']!), 'raw', dir.path, 't']), isNull);
    });
  });

  test('P1: no HOME is an error, never a shared temp folder', () async {
    final r = await runDart(
      '''
import 'package:dart_toolkit/src/cache.dart';
void main() {
  try {
    print(userCacheDir());
  } on UnsupportedError catch (e) {
    print('refused: \${e.message}');
  }
}
''',
      env: {'HOME': '', 'XDG_CACHE_HOME': ''},
    );
    expect(r.stdout, contains('refused: no user cache folder'), reason: '${r.stderr}');
  }, testOn: '!windows');

  test('S8: spooled media lands in an owner-only folder of the user cache', () async {
    final path = await media.spool(Stream.value([1, 2, 3]));
    addTearDown(() => io.File(path).delete());
    expect(path, startsWith(cache.userCacheDir()));
    final mode = (await io.File(path).parent.stat()).mode & 0x1ff;
    expect(mode.toRadixString(8), '700');
  }, testOn: '!windows');
}

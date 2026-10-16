// Pinned tool downloads against a loopback server, and the user cache.
import 'dart:io' hide File;
import 'dart:isolate';
import 'dart:io' as io show File;

import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/src/cache.dart' as cache;
import 'package:dart_toolkit/src/fetch.dart' as fetch;
import 'package:dart_toolkit/src/media.dart' as media;
import 'package:dart_toolkit/src/retry.dart' as retry;
import 'package:dart_toolkit/src/tool.dart' as tool;
import 'package:dart_toolkit/utils.dart';
import 'package:test/test.dart';

import 'support/child.dart';

void main() {
  test('P6: the download lock excludes isolates of one process, not only other processes', () async {
    final dir = await Directory.systemTemp.createTemp('tool_lock');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/.lock';
    // Each isolate logs in/out around a held stretch; overlap means no lock.
    final spans = await Future.wait([
      for (var i = 0; i < 3; i++)
        Isolate.run(
          () => cache.downloadLock(path, () async {
            final start = DateTime.now().microsecondsSinceEpoch;
            await Future<void>.delayed(const Duration(milliseconds: 300));
            return (start, DateTime.now().microsecondsSinceEpoch);
          }),
        ),
    ]);
    spans.sort((a, b) => a.$1.compareTo(b.$1));
    for (var k = 1; k < spans.length; k++) {
      expect(spans[k].$1, greaterThanOrEqualTo(spans[k - 1].$2), reason: '$spans');
    }
    expect(dir.listSync().map((e) => e.path.split('/').last), ['.lock']); // no sentinel left
  });

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

  String sha(List<int> b) => HashUtils.sha256().addBytes(b).hex();

  Future<Directory> fresh(String name) => Directory('${tmp.path}/$name').create(recursive: true);

  group('T1: fetch', () {
    test('unpacks a zip whose sha256 matches', () async {
      final dir = await fresh('ok');
      await fetch.fetch('$url/tool.zip', sha(served['/tool.zip']!), 'zip', dir.path);
      expect(await io.File('${dir.path}/bin/tool').readAsString(), contains('echo hi'));
    });

    test('a zip that does not match its sha256 unpacks nothing', () async {
      final dir = await fresh('bad');
      await expectLater(fetch.fetch('$url/tool.zip', '0' * 64, 'zip', dir.path), throwsA(isA<ContentException>()));
      expect(dir.listSync(recursive: true), isEmpty);
    });

    test('a raw download is written only when its sha256 matches', () async {
      final dir = await fresh('raw');
      await expectLater(
        fetch.fetch('$url/raw', '0' * 64, 'raw', dir.path, name: 'tool'),
        throwsA(isA<ContentException>()),
      );
      expect(dir.listSync(), isEmpty);
      await fetch.fetch('$url/raw', sha(served['/raw']!), 'raw', dir.path, name: 'tool');
      expect(await io.File('${dir.path}/tool').readAsString(), 'raw tool');
    });

    test('A3: the isolate reports a failure as text, success as null', () async {
      final dir = await fresh('iso');
      expect(
        await cache.fetchInIsolate('fetch.dart', ['$url/missing', '0' * 64, 'raw', dir.path, 'tool'], label: 'tool'),
        contains('404'),
      );
      expect(
        await cache.fetchInIsolate('fetch.dart', ['$url/raw', sha(served['/raw']!), 'raw', dir.path, 't'], label: 't'),
        isNull,
        reason: 'progress messages come first, then the answer',
      );
    });
  });

  test('a 7-Zip failure says whose fault: a password, the disk (retried by pool) or the archive (B13)', () {
    expect(tool.sevenZipFailure('exit 2: ERROR: Wrong password : a.txt'), isA<PasswordException>());
    expect(tool.sevenZipFailure('exit 2: ERROR: Data Error : a.txt'), isA<ContentException>());
    final full = tool.sevenZipFailure('exit 2: ERROR: No space left on device : a.txt');
    expect((full is IOException, full is ContentException), (true, false));
  });

  test('S13: a Chrome zip unpacks only when it matches its pinned sha256', () async {
    final bad = '${tmp.path}/cft/bad';
    await expectLater(fetch.fetch('$url/tool.zip', '0' * 64, 'app', bad), throwsA(isA<ContentException>()));
    expect(Directory(bad).existsSync(), isFalse);
    expect(Directory('${tmp.path}/cft').listSync().where((e) => e.path.contains('.tmp-')), isEmpty);
    final good = '${tmp.path}/cft/good';
    await fetch.fetch('$url/tool.zip', sha(served['/tool.zip']!), 'app', good);
    expect(await io.File('$good/bin/tool').readAsString(), contains('echo hi'));
  });

  // Children with their own HOME and a PATH without 7-Zip; a loopback
  // HTTPS_PROXY that refuses every tunnel stands in for the network.
  group('T3: the pinned tool download', () {
    late String pinned;
    late Map<String, String> env;
    setUp(() async {
      final home = (await fresh('home-${DateTime.now().microsecondsSinceEpoch}')).path;
      final caches = Platform.isMacOS ? '$home/Library/Caches' : '$home/.cache';
      pinned = '$caches/dart_toolkit/7zip-26.04/7zz';
      await Directory('$caches/dart_toolkit/7zip-26.04').create(recursive: true);
      final refuse = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(refuse.close);
      refuse.listen(
        (s) => s
          ..write('HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n')
          ..close(),
      );
      env = {
        'HOME': home,
        'XDG_CACHE_HOME': '',
        'PATH': '/usr/bin:/bin',
        'HTTPS_PROXY': 'http://127.0.0.1:${refuse.port}',
      };
    });

    test('a process waiting on the lock takes the binary the holder placed', () async {
      final lock = await io.File('${io.File(pinned).parent.path}/.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final child = await startDart('''
import 'package:dart_toolkit/src/tool.dart';
Future<void> main() async {
  print('start');
  final sw = Stopwatch()..start();
  print('got \${await tool(Tool.sevenzip)} after \${sw.elapsedMilliseconds}');
}
''', env: env);
      final lines = linesOf(child);
      await lines.firstWhere((l) => l == 'start').timeout(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(seconds: 1)); // the child blocks on the lock
      await io.File(pinned).writeAsString('placed');
      await lock.close(); // releases the lock
      final got = await lines.firstWhere((l) => l.startsWith('got ')).timeout(const Duration(seconds: 30));
      expect(got, startsWith('got $pinned after '));
      expect(int.parse(got.split(' ').last), greaterThanOrEqualTo(900), reason: 'it waited for the lock');
      expect(await child.exitCode, 0);
    }, testOn: '!windows');

    test(
      'a failed download leaves no temp folder and is not remembered',
      () async {
        final r = await runDart(
          '''
import 'dart:io';
import 'package:dart_toolkit/src/tool.dart';
Future<void> main(List<String> args) async {
  try {
    await tool(Tool.sevenzip);
    print('no failure');
  } on Exception catch (e) {
    print('failed: \${e is IOException} \${'\$e'.contains('download failed')}');
  }
  print('temps: \${File(args[0]).parent.listSync().where((e) => e.path.contains('.dl-')).length}');
  File(args[0]).writeAsStringSync('placed');
  print('then \${await tool(Tool.sevenzip)}');
}
''',
          args: [pinned],
          env: env,
          timeout: const Duration(seconds: 60),
        );
        expect(r.stdout, 'failed: true true\ntemps: 0\nthen $pinned\n', reason: '${r.stderr}');
      },
      testOn: '!windows',
      tags: 'slow',
    );
  });

  test('P1: no HOME is an error, never a shared temp folder', () async {
    final r = await runDart(
      '''
import 'package:dart_toolkit/core.dart';
import 'package:dart_toolkit/src/cache.dart';
void main() {
  try {
    print(userCacheDir());
  } on ToolkitException catch (e) {
    print('refused: \${e.message}');
  }
}
''',
      env: {'HOME': '', 'XDG_CACHE_HOME': ''},
    );
    expect(r.stdout, contains('refused: no user cache folder'), reason: '${r.stderr}');
  }, testOn: '!windows');

  test('E8: a download isolate that cannot start is a SetupException, not "compiled exe" under dart run', () async {
    await expectLater(
      cache.fetchInIsolate('no_such_library.dart', const [], label: 'thing'),
      throwsA(
        isA<SetupException>().having(
          (e) => e.message,
          'message',
          allOf(contains('could not start the download of thing'), isNot(contains('compiled exe'))),
        ),
      ),
    );
    expect(retry.isPermanent(const SetupException('x')), isTrue);
  });

  test(
    'E8: a compiled exe says so',
    () async {
      final dir = await Directory.systemTemp.createTemp('aot');
      addTearDown(() => dir.delete(recursive: true));
      await io.File('${dir.path}/main.dart').writeAsString('''
import 'package:dart_toolkit/core.dart';
import 'package:dart_toolkit/src/cache.dart';
Future<void> main() async {
  try {
    await fetchInIsolate('fetch.dart', const [], label: 'ffmpeg');
  } on SetupException catch (e) {
    print(e.message);
  }
}
''');
      final exe = '${dir.path}/main.exe';
      final c = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '-o',
        exe,
        '${dir.path}/main.dart',
      ]);
      expect(c.exitCode, 0, reason: '${c.stderr}${c.stdout}');
      final r = await Process.run(exe, const []);
      expect(r.stdout, contains('a compiled exe cannot download ffmpeg'), reason: '${r.stderr}');
    },
    tags: 'slow',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('S8: spooled media lands in an owner-only folder of the user cache', () async {
    final path = await media.spool(Stream.value([1, 2, 3]));
    addTearDown(() => io.File(path).delete());
    expect(path, startsWith(cache.userCacheDir()));
    final mode = (await io.File(path).parent.stat()).mode & 0x1ff;
    expect(mode.toRadixString(8), '700');
  }, testOn: '!windows');
}

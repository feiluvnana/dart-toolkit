// Ctrl-C (SIGINT) fails pending toolkit work with InterruptedException, so
// a script's `finally` runs before it exits 130. Every test signals only a
// child script it started.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/src/retry.dart' show isPermanent;
import 'package:dart_toolkit/shell.dart';
import 'package:test/test.dart';

import 'support/child.dart';

/// Run [source] (with `DIR` replaced by a fresh folder) as a child, send it
/// one SIGINT per entry of [signals] (each after its delay, the first once
/// it prints `busy`), and return its exit code, output and the folder.
Future<(int, String, Directory, Duration)> interrupted(
  String source, {
  List<Duration> signals = const [Duration.zero],
}) async {
  final dir = await Directory.systemTemp.createTemp('interrupt');
  addTearDown(() => dir.delete(recursive: true));
  // `busyWhen(path)` prints `busy` once [path] exists: a child that made
  // it is running, so our watcher is in place before the signal.
  final p = await startDart(
    "import 'dart:async';\nimport 'dart:io' as busy_io;\n${source.replaceAll('DIR', dir.path)}\n"
    'Future<void> busyWhen(String path) async {\n'
    '  while (!busy_io.File(path).existsSync()) {\n'
    '    await Future<void>.delayed(const Duration(milliseconds: 10));\n'
    '  }\n'
    "  print('busy');\n"
    '}\n',
  );
  final out = StringBuffer();
  final err = p.stderr.transform(utf8.decoder).join();
  final busy = Completer<void>();
  p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    out.writeln(line);
    if (line == 'busy' && !busy.isCompleted) busy.complete();
  });
  await busy.future.timeout(const Duration(seconds: 30));
  final sw = Stopwatch()..start();
  for (final delay in signals) {
    await Future<void>.delayed(delay);
    sw.reset();
    p.kill(ProcessSignal.sigint);
  }
  final code = await p.exitCode.timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  final took = sw.elapsed;
  return (code, '$out${await err}', dir, took);
}

String read(Directory dir, String name) {
  final f = File('${dir.path}/$name');
  return f.existsSync() ? f.readAsStringSync() : '';
}

void main() {
  test('Shell.run fails with InterruptedException, the finally saves, exit 130', () async {
    final (code, out, dir, _) = await interrupted(r'''
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/shell.dart';
Future<void> main() async {
  var why = 'none';
  try {
    unawaited(busyWhen('DIR/up'));
    await Shell.run(['sh', '-c', 'touch DIR/up; exec sleep 30']);
  } catch (e) {
    why = '${e.runtimeType}';
    rethrow;
  } finally {
    await Fs.file('DIR/state').write('saved $why');
  }
}
''');
    expect((code, read(dir, 'state')), (130, 'saved InterruptedException'), reason: out);
    expect(out, isNot(contains('Unhandled exception')));
  });

  test('a request and a pipeline into a file fail; the temp file is removed', () async {
    final (code, out, dir, _) = await interrupted(
      r'''
import 'dart:io' as io;
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/http.dart';
Future<void> main() async {
  final server = await io.HttpServer.bind('127.0.0.1', 0);
  server.listen((r) async {
    if (r.uri.path == '/hang') await Future<void>.delayed(const Duration(seconds: 30));
    r.response.contentLength = 1 << 30;
    while (true) {
      r.response.add(List.filled(1 << 16, 1));
      await r.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  final http = Http.client();
  final base = 'http://127.0.0.1:${server.port}';
  final hang = http.get('$base/hang').then((_) => 'done', onError: (Object e) => '${e.runtimeType}');
  try {
    print('busy');
    await (http.get('$base/body') > Fs.file('DIR/body.bin'));
  } catch (e) {
    await Fs.file('DIR/state').write('${e.runtimeType} ${await hang}');
    rethrow;
  }
}
''',
      signals: const [Duration(milliseconds: 300)],
    );
    expect((code, read(dir, 'state')), (130, 'InterruptedException InterruptedException'), reason: out);
    expect(dir.listSync().map((e) => e.uri.pathSegments.last), ['state'], reason: 'no temp or body left');
  });

  test('Pool.map with retries: an interrupted job is never retried, workers end', () async {
    final (code, out, dir, _) = await interrupted(
      r'''
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/pool.dart';
import 'package:dart_toolkit/shell.dart';
var tries = 0;
int spin(int n) {
  var x = 0;
  for (var i = 0; i < 1 << 40; i++) {
    x ^= i;
  }
  return x;
}
Future<void> main() async {
  try {
    print('busy');
    await Future.wait([
      Pool.map([1, 2, 3, 4], (int n) async {
        tries++;
        await Shell.run(['sleep', '30']);
      }, retries: 3),
      Pool.map([1, 2], spin, isolates: true),
    ]);
  } on InterruptedException {
    await Fs.file('DIR/state').write('tries $tries');
    rethrow;
  }
}
''',
      signals: const [Duration(milliseconds: 500)],
    );
    expect((code, read(dir, 'state')), (130, 'tries 4'), reason: out);
  });

  test('a script that catches it and goes on: new waits fail at once, exit 130 when idle', () async {
    final (code, out, dir, took) = await interrupted(r'''
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/shell.dart';
Future<void> main() async {
  var failed = 0;
  unawaited(busyWhen('DIR/up'));
  for (var i = 0; i < 1000; i++) {
    try {
      await Shell.run(['sh', '-c', 'touch DIR/up; exec sleep 30']);
    } catch (e) {
      failed++;
    }
  }
  await Fs.file('DIR/state').write('failed $failed');
  await Future<void>.delayed(const Duration(seconds: 30)); // not toolkit work
  await Fs.file('DIR/state').write('kept going');
}
''');
    expect((code, read(dir, 'state')), (130, 'failed 1000'), reason: out);
    expect(took, lessThan(const Duration(seconds: 5)));
  });

  test('a second Ctrl-C exits at once, and the exit hooks still clean up', () async {
    final (code, out, dir, took) = await interrupted(
      r'''
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/shell.dart';
Future<void> main() async {
  try {
    unawaited(busyWhen('DIR/up'));
    await Shell.run(['sh', '-c', 'touch DIR/up; exec sleep 30']);
  } finally {
    // Toolkit work in flight holds the exit after the first Ctrl-C.
    await Fs.tempDir((d) async {
      await Fs.file('DIR/temp').write(d.path);
      await Future<void>.delayed(const Duration(seconds: 30));
    });
  }
}
''',
      signals: const [Duration.zero, Duration(seconds: 1)],
    );
    expect(code, 130, reason: out);
    expect(took, lessThan(const Duration(seconds: 3)));
    final temp = read(dir, 'temp');
    expect(temp, isNotEmpty);
    expect(Directory(temp).existsSync(), isFalse, reason: 'the temp-dir hook ran');
  });

  test('Command.run: the handler\'s finally runs, exit 130, nothing printed', () async {
    final (code, out, dir, _) = await interrupted(r'''
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/shell.dart';
Future<void> main(List<String> args) => Command('job', 'a long job', handler: (_) async {
  try {
    unawaited(busyWhen('DIR/up'));
    await Shell.run(['sh', '-c', 'touch DIR/up; exec sleep 30']);
  } finally {
    await Fs.file('DIR/state').write('saved');
  }
}).run(args);
''');
    expect((code, read(dir, 'state'), out.trim()), (130, 'saved', 'busy'));
  });

  test('off a terminal, a child that died of SIGINT is just its exit code', () async {
    final r = await runDart(r'''
import 'package:dart_toolkit/shell.dart';
Future<void> main() async {
  final o = await Shell.run(['sh', '-c', r'kill -INT $$']);
  print('code ${o.code()}');
}
''');
    expect((r.exitCode, '${r.stdout}'.trim()), (0, 'code -2'), reason: '${r.stderr}');
  });

  test(
    'on our terminal, a child that died of its Ctrl-C interrupts the script',
    () async {
      final dir = await Directory.systemTemp.createTemp('interrupt');
      addTearDown(() => dir.delete(recursive: true));
      final script = File('${dir.path}/main.dart');
      // The child's SIGINT stands in for the terminal's Ctrl-C reaching it
      // before our watcher hears ours: this process gets no signal at all.
      await script.writeAsString(r'''
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/shell.dart';
Future<void> main(List<String> args) async {
  print('ready');
  try {
    await Shell.run(['sh', '-c', r'kill -INT $$']);
    print('went on');
  } on InterruptedException {
    print('interrupted');
    rethrow;
  } finally {
    await Fs.file('${args[0]}/state').write('saved');
  }
}
''');
      final root = Directory.current.path;
      final res = await Process.run('python3', [
        '$root/test/console_pty/drive.py',
        '--size', '24', '80', //
        '--ready', 'ready',
        '--',
        Platform.resolvedExecutable,
        '--packages=$root/.dart_tool/package_config.json',
        script.path,
        dir.path,
      ]);
      final code = RegExp(r'exit=(-?\d+)').firstMatch('${res.stderr}')?.group(1);
      expect(code, '130', reason: '${res.stdout}${res.stderr}');
      expect('${res.stdout}', contains('interrupted'));
      expect(read(dir, 'state'), 'saved');
    },
    tags: ['pty'],
    skip: noPty,
  );

  test(
    'a pending Chrome call fails with InterruptedException and the exit is 130, not 255',
    () async {
      final (code, out, dir, _) = await interrupted(
        r'''
import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/fs.dart';
Future<void> main() async {
  final browser = await Chrome.launch();
  final page = await browser.open('data:text/html,<p>hi</p>', timeout: const Duration(seconds: 60));
  try {
    print('busy');
    await page.wait('#never');
  } catch (e) {
    await Fs.file('DIR/state').write('${e.runtimeType}');
    rethrow;
  }
}
''',
        signals: const [Duration(milliseconds: 300)],
      );
      expect((code, read(dir, 'state')), (130, 'InterruptedException'), reason: out);
    },
    tags: ['chrome'],
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test('pool never retries an InterruptedException', () {
    expect(isPermanent(const InterruptedException()), isTrue);
    expect(const InterruptedException(), isA<ToolkitException>());
  });
}

import 'dart:async';
import 'dart:io' as io;

import 'package:dart_toolkit/path.dart';
import 'package:dart_toolkit/process.dart';
import 'package:test/test.dart';

void main() {
  group('process two-ended pipe', () {
    late io.Directory tmp;
    late String dart;
    setUp(() async {
      tmp = await io.Directory.systemTemp.createTemp('tk_proc_');
      dart = io.Platform.executable;
      io.File('${tmp.path}/slow.dart').writeAsStringSync('''
Future<void> main() async {
  for (var i = 0; i < 5; i++) {
    print('line\$i');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
''');
      io.File('${tmp.path}/echo.dart').writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    print('got:\$line');
  }
}
''');
      io.File('${tmp.path}/sleep.dart').writeAsStringSync('''
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 60));
}
''');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('line() yields before exit; lines() streams the rest', () async {
      final p = Process(dart, ['${tmp.path}/slow.dart']);
      expect(await p.line(), 'line0');
      final rest = <String>[];
      await for (final l in p.lines()) {
        rest.add(l);
      }
      expect(rest, ['line1', 'line2', 'line3', 'line4']);
      await p.wait();
    });

    test('write/line round-trip; writer close gives null at EOF', () async {
      final p = Process(dart, ['${tmp.path}/echo.dart']);
      await p.write('hello\n');
      expect(await p.line(), 'got:hello');
      await expectLater(p.write(42), throwsArgumentError);
      await (await p.writer()).close();
      expect(await p.line(), isNull);
      await p.wait();
    });

    test('p1.pipe(p2) then text()', () async {
      final p1 = Process(dart, ['${tmp.path}/slow.dart']);
      final p2 = Process(dart, ['${tmp.path}/echo.dart']);
      expect(await p1.pipe(p2), greaterThan(0));
      final out = await p2.text();
      expect(out.split('\n').first.trim(), 'got:line0');
      await p1.wait();
      await p2.wait();
    });

    test('wait(timeout:) throws TimeoutException and reaps the child', () async {
      final p = Process(dart, ['${tmp.path}/sleep.dart']);
      await expectLater(p.wait(timeout: const Duration(seconds: 2)), throwsA(isA<TimeoutException>()));
      await expectLater(p.wait(), throwsA(isA<ProcessException>()));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('close() kills and reaps; second close is quiet', () async {
      final p = Process(dart, ['${tmp.path}/sleep.dart']);
      final exit = _exitOf(p); // starts the child; the exit is awaited below
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await p.close();
      expect(await exit, isNot(0));
      await p.close();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a missing executable is ProcessException 127', () async {
      await expectLater(
        Process('definitely-not-a-real-binary-xyz', []).wait(),
        throwsA(isA<ProcessException>().having((e) => e.code, 'code', 127)),
      );
    });

    test('one-shot captures through text()', () async {
      expect(await Process(dart, ['--version']).check(), isTrue);
    });

    test('dir: takes a Located working directory', () async {
      io.File('${tmp.path}/pwd.dart').writeAsStringSync(r'''
import 'dart:io';
Future<void> main() async {
  print(Directory.current.path);
}
''');
      final fromDir = await Process(dart, ['${tmp.path}/pwd.dart'], dir: Dir(tmp.path)).text();
      // macOS symlinks /var to /private/var: compare resolved.
      expect(fromDir.trim(), io.Directory(tmp.path).resolveSymbolicLinksSync());
    });
  });

  group('process tree kill', () {
    late io.Directory tmp;
    late String dart;
    setUp(() async {
      tmp = await io.Directory.systemTemp.createTemp('tk_phasec_proc_');
      dart = io.Platform.executable;
      io.File('${tmp.path}/sleep.dart').writeAsStringSync('''
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 120));
}
''');
      // level2 spawns a sleeper grandchild, records both pids, then waits.
      io.File('${tmp.path}/level2.dart').writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final sleeper = await Process.start(Platform.executable, [args[0]]);
  await File(args[1]).writeAsString('\$pid \${sleeper.pid}');
  await sleeper.exitCode;
}
''');
      // level1 spawns level2, then waits: a 3-level chain below the test.
      io.File('${tmp.path}/level1.dart').writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final mid = await Process.start(Platform.executable, [args[0], args[1], args[2]]);
  await mid.exitCode;
}
''');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('close() reaps a 3-level chain', () async {
      final pids = '${tmp.path}/pids.txt';
      final p = Process(dart, ['${tmp.path}/level1.dart', '${tmp.path}/level2.dart', '${tmp.path}/sleep.dart', pids]);
      final exit = _exitOf(p); // starts the child; the chain records its pids below
      // Wait for the chain to record its pids.
      for (var i = 0; i < 100 && !io.File(pids).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(io.File(pids).existsSync(), isTrue, reason: 'chain did not start');
      final parts = (await io.File(pids).readAsString()).trim().split(' ');
      final mid = int.parse(parts[0]), leaf = int.parse(parts[1]);
      expect(await _alive(mid), isTrue);
      expect(await _alive(leaf), isTrue);
      await p.close();
      expect(await _alive(mid), isFalse);
      expect(await _alive(leaf), isFalse);
      expect(await exit, isNot(0));
      await p.close(); // second close is quiet
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('process objects', () {
    test("echo text() is its line", () async {
      expect(await Process('echo', ['hi']).text(), 'hi\n');
    }, testOn: '!windows');

    test('a failing command throws code and stderr', () async {
      await expectLater(
        Process('sh', ['-c', 'echo e >&2; exit 3']).text(),
        throwsA(isA<ProcessException>().having((e) => e.code, 'code', 3).having((e) => e.err, 'err', contains('e'))),
      );
    }, testOn: '!windows');

    test('check() answers yes or no', () async {
      expect(await Process('true', []).check(), isTrue);
      expect(await Process('false', []).check(), isFalse);
    }, testOn: '!windows');

    test('a missing executable check() is ProcessException 127', () async {
      await expectLater(
        Process('definitely-not-a-real-binary-xyz', []).check(),
        throwsA(isA<ProcessException>().having((e) => e.code, 'code', 127)),
      );
    });

    test('a process starts on its first call', () async {
      Future<bool> running() async => (await io.Process.run('pgrep', ['-f', 'ping 127.0.0.1'])).exitCode == 0;
      final proc = Process('ping', ['127.0.0.1']);
      expect(await running(), isFalse);
      expect(await proc.line(), isNotNull);
      expect(await running(), isTrue);
      await proc.close();
    }, testOn: '!windows');

    test('input feeds stdin: sort', () async {
      expect(await Process('sort', [], input: 'b\na\n').text(), 'a\nb\n');
    }, testOn: '!windows');

    test('a file pipes into a process stdin', () async {
      final dir = await Dir.temp();
      try {
        final f = dir.file('words.txt');
        await f.write('b\na\n');
        final proc = Process('sort', []);
        await f.pipe(proc);
        await proc.wait();
        expect(await proc.text(), 'a\nb\n');
      } finally {
        await dir.drop();
      }
    }, testOn: '!windows');
  });

  group('hang regressions', () {
    test(
      'line() waits for new data when stdout ends without a newline',
      () async {
        final p = Process('sh', ['-c', 'printf abc; sleep 1; printf "def\\n"']);
        expect(await p.line(), 'abcdef');
        await p.wait();
      },
      testOn: '!windows',
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'input larger than the pipe buffer streams: sort of 10 MB',
      () async {
        final input = 'x\n' * (5 * 1024 * 1024);
        expect(await Process('sort', [], input: input).text(), input);
      },
      testOn: '!windows',
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'input to a child that exits early is not a broken pipe',
      () async {
        expect(await Process('true', [], input: 'y\n' * (512 * 1024)).check(), isTrue);
      },
      testOn: '!windows',
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'readings close stdin: cat text() is empty, not a hang',
      () async {
        expect(await Process('cat', []).text(), '');
      },
      testOn: '!windows',
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'errors() after stderr ended yields the tail and ends',
      () async {
        final p = Process('sh', ['-c', 'echo oops >&2']);
        await p.wait();
        expect(await p.errors().toList(), ['oops']);
      },
      testOn: '!windows',
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'close() after a normal exit is quiet and keeps the exit',
      () async {
        final p = Process('sh', ['-c', 'exit 3']);
        await expectLater(p.wait(), throwsA(isA<ProcessException>().having((e) => e.code, 'code', 3)));
        await p.close();
        await expectLater(p.wait(), throwsA(isA<ProcessException>().having((e) => e.code, 'code', 3)));
      },
      testOn: '!windows',
      timeout: const Timeout(Duration(seconds: 5)),
    );
  });
}

/// Whether [pid] still names a live process.
Future<bool> _alive(int pid) async {
  if (io.Platform.isWindows) {
    final r = await io.Process.run('tasklist', ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH']);
    return '${r.stdout}'.contains('"$pid"');
  }
  final r = await io.Process.run('ps', ['-p', '$pid']);
  return r.exitCode == 0;
}

/// [p]'s exit code through `wait()` (which starts it): 0, or the failing code.
Future<int> _exitOf(Process p) => p.wait().then((_) => 0, onError: (Object e) => e is ProcessException ? e.code : -1);

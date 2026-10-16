import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/shell.dart';
import 'package:dart_toolkit/utils.dart';
import 'package:test/test.dart';

import 'support/child.dart';
import 'support/io.dart';
import 'support/poll.dart';

void main() {
  timeoutTests();
  group('Shell.run', () {
    test('runs a program and returns stdout', () async {
      final out = await Shell.run(['echo', 'hi']);
      expect(out.code(), 0);
      expect((await out.text()).trim(), 'hi');
    });

    test('text() drops one trailing newline; bytes() stays verbatim', () async {
      final out = await Shell.run(['printf', 'a\n']);
      expect(await out.text(), 'a');
      expect(await out.bytes(), [97, 10]);
      final crlf = await Shell.run(['printf', 'a\r\n']);
      expect(await crlf.text(), 'a');
    });

    test('a non-zero exit is an Output', () async {
      final out = await Shell.run(['sh', '-c', 'exit 3']);
      expect(out.code(), 3);
      expect(out.ok(), isFalse);
    });

    test('err carries stderr', () async {
      final out = await Shell.run(['sh', '-c', 'echo oops >&2']);
      expect(out.err(), contains('oops'));
    });

    test('env overlays the parent; null unsets', () async {
      final out = await Shell.run(['sh', '-c', 'pwd; echo \$MARK'], dir: '/tmp', env: {'MARK': 'here'});
      expect(await out.text(), contains('/tmp'));
      expect(await out.text(), contains('here'));
    });

    test('read streams stdout as it prints; nothing starts until read', () async {
      final dir = await Directory.systemTemp.createTemp('read');
      addTearDown(() => dir.delete(recursive: true));
      final mark = '${dir.path}/ran';
      final reader = Shell.read(['sh', '-c', 'touch "$mark"; echo one; sleep 0.2; echo three']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await Fs.file(mark).exists(), isFalse);
      expect(await reader.lines().toList(), ['one', 'three']);
    });

    test('read: a non-zero exit fails it with the stderr; stderr shows as it runs', () async {
      final r = await runDart(r'''
import 'package:dart_toolkit/shell.dart';
Future<void> main() async {
  try {
    await (Shell.read(['sh', '-c', 'echo out; echo shown >&2; exit 5']) > null);
  } on ExitException catch (e) {
    print('code=${e.errorCode} ${e.message.contains('shown')}');
  }
}
''');
      expect(r.stdout, 'code=5 true\n');
      expect(r.stderr, 'shown\n');
    }, testOn: '!windows');

    test('run is a Task: a probe watches it', () async {
      final m = Meter();
      final out = await (Shell.run(['echo', 'hi']) & m);
      expect(await out.text(), 'hi');
    });

    test('check(): a non-zero exit throws with the code and stderr', () async {
      await expectLater(
        Shell.run(['sh', '-c', 'echo bad >&2; exit 4']).check(),
        throwsA(
          isA<ProcessException>()
              .having((e) => e.errorCode, 'code', 4)
              .having((e) => e.message, 'message', contains('bad')),
        ),
      );
      expect(await Shell.run(['echo', 'ok']).check().text(), 'ok');
    });

    test('check() keeps only the last 64 KB of stderr (regression: unbounded message)', () async {
      final e = await Shell.run([
        'sh',
        '-c',
        'i=0; while [ \$i -lt 4000 ]; do echo "noise line \$i ................................" >&2; i=\$((i+1)); done; echo LAST >&2; exit 3',
      ]).check().then<Object?>((_) => null, onError: (Object e) => e);
      final message = (e as ProcessException).message;
      expect(message.length, lessThan(66 * 1024));
      expect(message, startsWith('exit 3: …noise line'));
      expect(message, endsWith('LAST'));
    });

    test('a null env value unsets the variable', () async {
      // HOME is set in any real parent; null must hide it from the child.
      final unset = await Shell.run(['sh', '-c', 'echo "[\$HOME]"'], env: {'HOME': null});
      expect(await unset.text(), '[]');
      final kept = await Shell.run(['sh', '-c', 'echo "[\$MARK]"'], env: {'MARK': 'here'});
      expect(await kept.text(), '[here]');
    });

    test('read into Console.out() shows a program as it runs', () async {
      final r = await runDart('''
import 'dart:io';
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/shell.dart';
Future<void> main() async {
  await (Shell.read(['sh', '-c', 'echo live-out; echo live-err >&2']) > Console.out());
  try {
    await (Shell.read(['sh', '-c', 'exit 3']) > Console.out());
  } on ExitException catch (e) {
    exitCode = e.errorCode;
  }
}
''');
      expect(r.exitCode, 3);
      expect(r.stdout, 'live-out\n');
      expect(r.stderr, 'live-err\n');
    });

    test('ShellUtils.open never passes a target as a launcher option', () async {
      if (Platform.isWindows) return markTestSkipped('POSIX launchers only');
      final bin = await Directory.systemTemp.createTemp('fake_open');
      addTearDown(() => bin.delete(recursive: true));
      for (final name in ['open', 'xdg-open']) {
        await Fs.file('${bin.path}/$name').write('#!/bin/sh\nprintf "%s|" "\$@" > "${bin.path}/argv"\n');
        await Process.run('chmod', ['755', '${bin.path}/$name']);
      }
      final r = await runDart(
        '''
import 'package:dart_toolkit/utils.dart';
Future<void> main() => ShellUtils.open('-a/System/Applications/Calculator.app');
''',
        env: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(await Fs.file('${bin.path}/argv').text(), './-a/System/Applications/Calculator.app|');
    });

    test('ShellUtils.open returns and exits while the opened app keeps running', () async {
      if (Platform.isWindows) return markTestSkipped('POSIX launchers only');
      final bin = await Directory.systemTemp.createTemp('fake_open');
      addTearDown(() => bin.delete(recursive: true));
      for (final name in ['open', 'xdg-open']) {
        await Fs.file('${bin.path}/$name').write('#!/bin/sh\nsleep 20 &\nexit 0\n');
        await Process.run('chmod', ['755', '${bin.path}/$name']);
      }
      final sw = Stopwatch()..start();
      final r = await runDart(
        '''
import 'package:dart_toolkit/utils.dart';
Future<void> main() => ShellUtils.open('https://example.com');
''',
        env: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
        timeout: const Duration(seconds: 15),
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('a SIGTERM that ends the script ends its running child and grandchildren', () async {
      if (Platform.isWindows) return markTestSkipped('POSIX signals');
      final p = await startDart('''
import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/shell.dart';
Future<void> main() async {
  await (Shell.read(['sh', '-c', r'sleep 20 & echo \$!; wait']) > Console.out());
}
''');
      final first = await p.stdout.transform(const SystemEncoding().decoder).first;
      final child = first.trim();
      p.kill(); // SIGTERM to the script we spawned
      expect(await p.exitCode.timeout(const Duration(seconds: 10)), 143);
      final gone = await eventually(
        () async => '${(await Process.run('ps', ['-p', child, '-o', 'pid='])).stdout}'.trim().isEmpty,
      );
      expect(gone, isTrue, reason: 'sleep $child outlived the script');
    });

    test('bytes() is unmodifiable and the same each call', () async {
      final out = await Shell.run(['printf', 'abc']);
      final a = await out.bytes();
      final b = await out.bytes();
      expect(a, [97, 98, 99]);
      expect(b, [97, 98, 99]);
      expect(() => a.add(0), throwsUnsupportedError);
    });

    test('P2: a 7-Zip password stuck to -p is masked in the error', () async {
      final dir = await Directory.systemTemp.createTemp('fake7z');
      addTearDown(() => dir.delete(recursive: true));
      final fake = '${dir.path}/7zz';
      await Fs.file(fake).write('#!/bin/sh\nexit 2\n');
      await Process.run('chmod', ['+x', fake]);
      await expectLater(
        Shell.run([fake, 'x', '-pSECRET', 'a.7z']).check(),
        throwsA(isA<ProcessException>().having((e) => '$e', 'text', allOf(contains('-p***'), isNot(contains('SECRET'))))),
      );
    }, testOn: '!windows');

    test('E5: a non-zero exit with check() is an ExitException, a toolkit error', () async {
      final e = await Shell.run(['sh', '-c', 'echo boom >&2; exit 3']).check().then<Object>((_) => 'ran', onError: (Object e) => e);
      expect(e, isA<ExitException>().having((x) => x.errorCode, 'code', 3));
      expect(e, isA<ToolkitException>().having((x) => x.message, 'message', contains('boom')));
      await expectLater(Shell.run(['dart-toolkit-no-such-program-xyz']), throwsA(isNot(isA<ExitException>())));
    });

    test('a program that cannot start throws ProcessException', () async {
      expect(Shell.run(['dart-toolkit-no-such-program-xyz']), throwsA(isA<ProcessException>()));
    });

    test('Output is a Reader: json() works', () async {
      final out = await Shell.run(['echo', '{"a": 1}']);
      expect(await out.json().$('a').value<int>(), 1);
    });

    test('Future mirrors match', () async {
      final f = Shell.run(['sh', '-c', 'echo e; echo w >&2']);
      expect(await f.code(), 0);
      expect(await f.err(), contains('w'));
      expect((await f.text()).trim(), 'e');
    });
  });

  group('Shell.filter', () {
    test('a process as a Pipe', () async {
      final out = await Shell.run(['printf', 'a\nb\nc\n']);
      final filtered = Mem(await out.text()) | Shell.filter(['grep', 'b']);
      expect((await filtered.text()).trim(), 'b');
    });

    test('non-zero exit fails the run with a ProcessException', () async {
      expect(
        Mem('x') | Shell.filter(['sh', '-c', 'cat >&2; exit 2']) > null,
        throwsA(isA<ExitException>().having((e) => e.errorCode, 'code', 2)),
      );
    });

    test('an upstream error is rethrown, not masked', () async {
      expect(BoomReader() | Shell.filter(['cat']) > null, throwsStateError);
    });

    test('empty command is an ArgumentError', () {
      expect(() => Shell.filter([]), throwsArgumentError);
      expect(() => Shell.run([]), throwsArgumentError);
    });

    test('F4: a child that stops reading early is not an error', () async {
      final lines = List.generate(10000, (i) => 'line $i').join('\n');
      final tmp = await Directory.systemTemp.createTemp('shell_f4');
      try {
        await (Mem(lines) | Shell.filter(['head', '-n', '1']) > Fs.file('${tmp.path}/one.txt'));
        final first = await Fs.file('${tmp.path}/one.txt').text();
        expect(first.trim(), 'line 0');
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('a failing filter keeps the last 64 KB of stderr', () async {
      final big = List.generate(4000, (i) => 'noise line $i ................................').join('\n');
      final e = await (Mem('$big\nLAST\n') | Shell.filter(['sh', '-c', 'cat >&2; exit 2']) > null).then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      final message = (e as ProcessException).message;
      expect(message.length, lessThan(66 * 1024));
      expect(message.trim(), endsWith('LAST'));
    });

    test('F12: late stderr survives into the exception', () async {
      await expectLater(
        Mem('x') | Shell.filter(['sh', '-c', 'cat >/dev/null; sleep 0.3; echo late-stderr >&2; exit 2']) > null,
        throwsA(
          isA<ProcessException>().having((e) => e.message, 'message', allOf(contains('2'), contains('late-stderr'))),
        ),
      );
    });
  });
}

void timeoutTests() {
  group('timeout and which', () {
    test('timeout kills a run that takes too long and names the command', () async {
      final sw = Stopwatch()..start();
      await expectLater(
        Shell.run(['sleep', '5'], timeout: 300.milliseconds),
        throwsA(isA<TimeoutException>().having((e) => '$e', 'text', 'TimeoutException: sleep 5 ran over 300 ms')),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expect((await Shell.run(['echo', 'hi'], timeout: 5.seconds)).ok(), isTrue);
    });

    test('a timeout kills the grandchildren too, and the script exits at once', () async {
      if (Platform.isWindows) return markTestSkipped('POSIX process tree');
      final dir = await Directory.systemTemp.createTemp('shell_tree');
      addTearDown(() => dir.delete(recursive: true));
      final sw = Stopwatch()..start();
      final r = await runDart('''
import 'dart:async';
import 'package:dart_toolkit/shell.dart';
Future<void> main() async {
  try {
    await Shell.run(['sh', '-c', r'sleep 20 & echo \$! > ${dir.path}/pid; wait'], timeout: const Duration(milliseconds: 500));
  } on TimeoutException {
    print('timed out');
  }
}
''', timeout: const Duration(seconds: 8));
      expect((r.exitCode, '${r.stdout}'.trim()), (0, 'timed out'), reason: '${r.stderr}');
      expect(sw.elapsed, lessThan(const Duration(seconds: 6)));
      final pid = (await Fs.file('${dir.path}/pid').text()).trim();
      final ps = await Process.run('ps', ['-p', pid, '-o', 'pid=']);
      expect('${ps.stdout}'.trim(), isEmpty, reason: 'sleep $pid outlived the timeout');
    });

    test('check: and timeout: messages never show tokens, secret headers or URL credentials', () async {
      final args = [
        '-H',
        'Authorization: Bearer SECRET1',
        '-HCookie: sid=SECRET2',
        '--token=SECRET3',
        '--password',
        'SECRET4',
        'https://u:SECRET5@example.com/a?api_key=SECRET6&page=2',
        '-H',
        'Accept: text/html',
      ];
      final failed = await Shell.run([
        'sh',
        '-c',
        'exit 3',
        'sh',
        ...args,
      ]).check().then<Object?>((_) => null, onError: (Object e) => e);
      final timedOut = await Shell.run([
        'sh',
        '-c',
        'sleep 5',
        'sh',
        ...args,
      ], timeout: 200.milliseconds).then<Object?>((_) => null, onError: (Object e) => e);
      for (final e in [failed, timedOut]) {
        expect('$e', isNot(contains('SECRET')), reason: '$e');
        expect('$e', allOf(contains('Accept: text/html'), contains('page=2'), contains('api_key=***')));
      }
    });

    test('which finds installed programs on PATH, null otherwise', () async {
      expect(await ShellUtils.which('sh'), endsWith('/sh'));
      expect(await ShellUtils.which('definitely-not-a-program-x9'), isNull);
      expect(await ShellUtils.which('/bin/sh'), '/bin/sh');
      expect(await ShellUtils.which('/etc/hosts'), isNull, reason: 'not executable');
    });
  });

  group('cancel and the child tree', () {
    Future<bool> alive(String pid) async =>
        '${(await Process.run('ps', ['-p', pid.trim(), '-o', 'pid='])).stdout}'.trim().isNotEmpty;

    test('cancel kills the run and its grandchildren and returns what was captured', () async {
      if (Platform.isWindows) return markTestSkipped('POSIX process tree');
      final dir = await Directory.systemTemp.createTemp('cancel');
      addTearDown(() => dir.delete(recursive: true));
      final pidFile = Fs.file('${dir.path}/pid');
      final stop = Completer<void>();
      final sw = Stopwatch()..start();
      final run = Shell.run(['sh', '-c', 'sleep 20 & echo \$! > "${pidFile.path}"; echo \$!; wait'], cancel: stop.future);
      expect(await eventually(() async => (await pidFile.text(or: '')).trim().isNotEmpty), isTrue);
      final pid = (await pidFile.text()).trim();
      stop.complete();
      final out = await run.timeout(const Duration(seconds: 5));
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      expect(out.code(), -9);
      expect(await out.text(), pid);
      expect(await eventually(() async => !await alive(pid)), isTrue, reason: 'sleep $pid outlived the cancel');
    });

    test('B2: a read left early kills the tree', () async {
      if (Platform.isWindows) return markTestSkipped('POSIX process tree');
      final r = await runDart(r'''
import 'dart:io';
import 'package:dart_toolkit/shell.dart';
Future<void> main() async {
  String? pid;
  await for (final l in Shell.read(['sh', '-c', r'sleep 20 & echo $!; echo boom; wait']).lines()) {
    pid ??= l;
    if (l == 'boom') {
      print('caught bad line');
      break;
    }
  }
  var alive = true;
  for (var i = 0; i < 100 && alive; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    alive = '${(await Process.run('ps', ['-p', pid!, '-o', 'pid='])).stdout}'.trim().isNotEmpty;
  }
  print('alive=$alive');
}
''', timeout: const Duration(seconds: 15));
      expect(r.stdout, contains('caught bad line'), reason: '${r.stderr}');
      expect(r.stdout, contains('alive=false'));
      expect(r.exitCode, 0);
    });

    test('a cancel after the run ended changes nothing', () async {
      final stop = Completer<void>();
      final out = await Shell.run(['echo', 'hi'], cancel: stop.future);
      stop.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((out.code(), await out.text()), (0, 'hi'));
      final failed = Completer<void>()..completeError(StateError('stop'));
      expect((await Shell.run(['sleep', '5'], cancel: failed.future)).ok(), isFalse);
    });

    test('a filter whose reader is cancelled kills its grandchildren', () async {
      if (Platform.isWindows) return markTestSkipped('POSIX process tree');
      final lines = (Reader.of(const []) | Shell.filter(['sh', '-c', r'sleep 20 & echo $!; wait'])).lines();
      final pid = await lines.first.timeout(const Duration(seconds: 5));
      expect(await eventually(() async => !await alive(pid)), isTrue, reason: 'sleep $pid outlived the filter');
    });

    test('a SIGTERM that ends the script ends a running filter and its grandchildren', () async {
      if (Platform.isWindows) return markTestSkipped('POSIX signals');
      final p = await startDart('''
import 'package:dart_toolkit/shell.dart';
Future<void> main() async {
  await for (final line in (Reader.of(const []) | Shell.filter(['sh', '-c', r'sleep 20 & echo \$!; wait'])).lines()) {
    print(line);
  }
}
''');
      final child = (await p.stdout.transform(const SystemEncoding().decoder).first).trim();
      p.kill(); // SIGTERM to the script we spawned
      expect(await p.exitCode.timeout(const Duration(seconds: 10)), 143);
      expect(await eventually(() async => !await alive(child)), isTrue, reason: 'sleep $child outlived the script');
    });
  });
}

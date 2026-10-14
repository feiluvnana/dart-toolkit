import 'dart:io';

import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/shell.dart';
import 'package:test/test.dart';

import 'support/child.dart';

void main() {
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

    test('onLine gets stdout and stderr lines as they arrive', () async {
      final seen = <String>[];
      final out = await Shell.run(['sh', '-c', 'echo one; echo two >&2; sleep 0.2; echo three'], onLine: seen.add);
      expect(seen..sort(), ['one', 'three', 'two']);
      expect(await out.text(), 'one\nthree');
      expect(out.err().trim(), 'two');
    });

    test('check: a non-zero exit throws with the code and stderr', () async {
      await expectLater(
        Shell.run(['sh', '-c', 'echo bad >&2; exit 4'], check: true),
        throwsA(
          isA<ProcessException>()
              .having((e) => e.errorCode, 'code', 4)
              .having((e) => e.message, 'message', contains('bad')),
        ),
      );
      expect(await Shell.run(['echo', 'ok'], check: true).text(), 'ok');
    });

    test('a null env value unsets the variable', () async {
      // HOME is set in any real parent; null must hide it from the child.
      final unset = await Shell.run(['sh', '-c', 'echo "[\$HOME]"'], env: {'HOME': null});
      expect(await unset.text(), '[]');
      final kept = await Shell.run(['sh', '-c', 'echo "[\$MARK]"'], env: {'MARK': 'here'});
      expect(await kept.text(), '[here]');
    });

    test('live tees to our stdout/stderr while capturing', () async {
      final r = await runDart('''
import 'dart:io';
import 'package:dart_toolkit/shell.dart';
Future<void> main() async {
  final out = await Shell.run(['sh', '-c', 'echo live-out; echo live-err >&2'], live: true);
  stdout.writeln('[\${await out.text()}|\${out.err().trim()}]');
  exitCode = (await Shell.run(['sh', '-c', 'exit 3'], live: true)).code();
}
''');
      expect(r.exitCode, 3);
      expect(r.stdout, 'live-out\n[live-out|live-err]\n');
      expect(r.stderr, 'live-err\n');
    });

    test('Shell.open never passes a target as a launcher option', () async {
      if (Platform.isWindows) markTestSkipped('POSIX launchers only');
      final bin = await Directory.systemTemp.createTemp('fake_open');
      addTearDown(() => bin.delete(recursive: true));
      for (final name in ['open', 'xdg-open']) {
        await Fs.file('${bin.path}/$name').write('#!/bin/sh\nprintf "%s|" "\$@" > "${bin.path}/argv"\n');
        await Process.run('chmod', ['755', '${bin.path}/$name']);
      }
      final r = await runDart(
        '''
import 'package:dart_toolkit/shell.dart';
Future<void> main() => Shell.open('-a/System/Applications/Calculator.app');
''',
        env: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(await Fs.file('${bin.path}/argv').text(), './-a/System/Applications/Calculator.app|');
    });

    test('Shell.open returns and exits while the opened app keeps running', () async {
      if (Platform.isWindows) markTestSkipped('POSIX launchers only');
      final bin = await Directory.systemTemp.createTemp('fake_open');
      addTearDown(() => bin.delete(recursive: true));
      for (final name in ['open', 'xdg-open']) {
        await Fs.file('${bin.path}/$name').write('#!/bin/sh\nsleep 20 &\nexit 0\n');
        await Process.run('chmod', ['755', '${bin.path}/$name']);
      }
      final sw = Stopwatch()..start();
      final r = await runDart(
        '''
import 'package:dart_toolkit/shell.dart';
Future<void> main() => Shell.open('https://example.com');
''',
        env: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
        timeout: const Duration(seconds: 15),
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('a SIGTERM that ends the script ends its running child', () async {
      if (Platform.isWindows) markTestSkipped('POSIX signals');
      final dir = await Directory.systemTemp.createTemp('shell_orphan');
      addTearDown(() => dir.delete(recursive: true));
      await Fs.file('${dir.path}/main.dart').write('''
import 'package:dart_toolkit/shell.dart';
Future<void> main() async {
  await Shell.run(['sh', '-c', r'echo \$\$; exec sleep 20'], live: true);
}
''');
      final p = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${dir.path}/main.dart',
      ]);
      final first = await p.stdout.transform(const SystemEncoding().decoder).first;
      final child = first.trim();
      p.kill(); // SIGTERM to the script we spawned
      expect(await p.exitCode.timeout(const Duration(seconds: 10)), 143);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final ps = await Process.run('ps', ['-p', child, '-o', 'pid=']);
      expect('${ps.stdout}'.trim(), isEmpty, reason: 'sleep $child outlived the script');
    });

    test('bytes() is a view, not a copy', () async {
      final out = await Shell.run(['printf', 'abc']);
      final a = await out.bytes();
      final b = await out.bytes();
      expect(a, [97, 98, 99]);
      expect(b, [97, 98, 99]);
      expect(() => a.add(0), throwsUnsupportedError);
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
      final filtered = _Mem(await out.text()) | Shell.filter(['grep', 'b']);
      expect((await filtered.text()).trim(), 'b');
    });

    test('non-zero exit fails the run with a ProcessException', () async {
      expect(
        _Mem('x') | Shell.filter(['sh', '-c', 'cat >&2; exit 2']) > null,
        throwsA(isA<ProcessException>().having((e) => e.message, 'message', contains('2'))),
      );
    });

    test('an upstream error is rethrown, not masked', () async {
      expect(_Boom() | Shell.filter(['cat']) > null, throwsStateError);
    });

    test('empty command is an ArgumentError', () {
      expect(() => Shell.filter([]), throwsArgumentError);
      expect(() => Shell.run([]), throwsArgumentError);
    });

    test('F4: a child that stops reading early is not an error', () async {
      final lines = List.generate(10000, (i) => 'line $i').join('\n');
      final tmp = await Directory.systemTemp.createTemp('shell_f4');
      try {
        await (_Mem(lines) | Shell.filter(['head', '-n', '1']) > Fs.file('${tmp.path}/one.txt'));
        final first = await Fs.file('${tmp.path}/one.txt').text();
        expect(first.trim(), 'line 0');
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('F12: late stderr survives into the exception', () async {
      await expectLater(
        _Mem('x') | Shell.filter(['sh', '-c', 'cat >/dev/null; sleep 0.3; echo late-stderr >&2; exit 2']) > null,
        throwsA(
          isA<ProcessException>().having((e) => e.message, 'message', allOf(contains('2'), contains('late-stderr'))),
        ),
      );
    });
  });
}

final class _Mem with Reader {
  _Mem(this._text);
  final String _text;
  @override
  Stream<List<int>> stream() => Stream.value(_text.codeUnits);
}

final class _Boom with Reader {
  @override
  Stream<List<int>> stream() async* {
    yield [1, 2, 3];
    throw StateError('reader blew up mid-write');
  }
}

import 'dart:io';

import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/shell.dart';
import 'package:test/test.dart';

void main() {
  group('Shell.run', () {
    test('runs a program and returns stdout', () async {
      final out = await Shell.run(['echo', 'hi']);
      expect(out.exitCode(), 0);
      expect((await out.text()).trim(), 'hi');
    });

    test('text() drops one trailing newline; bytes() stays verbatim',
        () async {
      final out = await Shell.run(['printf', 'a\n']);
      expect(await out.text(), 'a');
      expect(await out.bytes(), [97, 10]);
      final crlf = await Shell.run(['printf', 'a\r\n']);
      expect(await crlf.text(), 'a');
    });

    test('a non-zero exit is an Output', () async {
      final out = await Shell.run(['sh', '-c', 'exit 3']);
      expect(out.exitCode(), 3);
    });

    test('errorText carries stderr', () async {
      final out = await Shell.run(['sh', '-c', 'echo oops >&2']);
      expect(out.errorText(), contains('oops'));
    });

    test('workingDir and env', () async {
      final out = await Shell.run(['sh', '-c', 'pwd; echo \$MARK'],
          workingDir: '/tmp', env: {'MARK': 'here'});
      expect(await out.text(), contains('/tmp'));
      expect(await out.text(), contains('here'));
    });

    test('a program that cannot start throws ProcessException', () async {
      expect(
        Shell.run(['dart-toolkit-no-such-program-xyz']),
        throwsA(isA<ProcessException>()),
      );
    });

    test('Output is a Reader: json() works', () async {
      final out = await Shell.run(['echo', '{"a": 1}']);
      expect(await out.json().$('a').value<int>(), 1);
    });

    test('Future mirrors match', () async {
      final f = Shell.run(['sh', '-c', 'echo e; echo w >&2']);
      expect(await f.exitCode(), 0);
      expect(await f.errorText(), contains('w'));
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
        throwsA(isA<ProcessException>().having(
          (e) => e.message,
          'message',
          contains('2'),
        )),
      );
    });

    test('an upstream error is rethrown, not masked', () async {
      expect(
        _Boom() | Shell.filter(['cat']) > null,
        throwsStateError,
      );
    });

    test('empty command is an ArgumentError', () {
      expect(() => Shell.filter([]), throwsArgumentError);
      expect(() => Shell.run([]), throwsArgumentError);
    });

    test('F4: a child that stops reading early is not an error', () async {
      final lines = List.generate(10000, (i) => 'line $i').join('\n');
      final tmp = await Directory.systemTemp.createTemp('shell_f4');
      try {
        await (_Mem(lines) |
                Shell.filter(['head', '-n', '1']) >
            Fs.file('${tmp.path}/one.txt'));
        final first = await Fs.file('${tmp.path}/one.txt').text();
        expect(first.trim(), 'line 0');
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('F12: late stderr survives into the exception', () async {
      await expectLater(
        _Mem('x') |
            Shell.filter([
              'sh',
              '-c',
              'cat >/dev/null; sleep 0.3; echo late-stderr >&2; exit 2',
            ]) >
                null,
        throwsA(isA<ProcessException>().having(
          (e) => e.message,
          'message',
          allOf(contains('2'), contains('late-stderr')),
        )),
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

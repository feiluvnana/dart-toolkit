import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:test/test.dart';

import 'support/child.dart';

void main() {
  group('Console.choose', () {
    test('empty items is an ArgumentError', () {
      expect(Console.choose('Pick', <String>[], label: (s) => s), throwsArgumentError);
    });

    test('an unknown keys binding is an ArgumentError, before any prompt', () {
      expect(Console.choose('Pick', ['a', 'b'], label: (s) => s, keys: {'notakey-xyz': 'a'}), throwsArgumentError);
    });

    test('an initial that is not an item is an ArgumentError', () {
      expect(Console.choose('Pick', ['a', 'b'], label: (s) => s, or: 'z'), throwsArgumentError);
    });
  });

  group('piped stdin', () {
    test('a line that arrives between prompts is kept', () async {
      final r = await runDart(
        '''
import 'package:dart_toolkit/console.dart';
Future<void> main() async {
  final a = await Console.ask('first?');
  await Future<void>.delayed(const Duration(milliseconds: 600));
  final b = await Console.ask('second?');
  print('a=\$a b=\$b');
}
''',
        stdin: const [(Duration.zero, 'one\n'), (Duration(milliseconds: 200), 'two\n')],
      );
      expect(r.stdout, contains('a=one b=two'));
      expect(r.exitCode, 0);
    });
  });

  group('Console.spin', () {
    test('returns the work result', () async {
      expect(await Console.spin('Work', Future.value(42)), 42);
    });

    test('rethrows the work error', () async {
      expect(Console.spin<void>('Work', Future.error(StateError('bad'))), throwsStateError);
    });
  });

  group('Bar', () {
    test('a bar ticked to its total closes itself; a second one may start', () async {
      final first = Console.bar(3, label: 'items');
      for (var i = 0; i < 3; i++) {
        first.tick();
      }
      await Future<void>.delayed(Duration.zero);
      final second = Console.bar(2)..tick(2);
      await Future<void>.delayed(Duration.zero);
      expect(() => Console.bar(1)..tick(), returnsNormally);
      await second.close();
    });

    test('two live bars name the fix', () async {
      final open = Console.bar(10);
      expect(() => Console.bar(5), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('close()'))));
      await open.close();
    });

    test('tick counts and stops at the total, returns the bar', () async {
      final bar = Console.bar(3, label: 'T');
      expect(identical(bar.tick(), bar), isTrue);
      bar.tick(5);
      await bar.close();
    });

    test('L3: counts past the total are kept, negative ticks ignored', () async {
      final root = Directory.current;
      final res = await Process.run(Platform.resolvedExecutable, [
        '${root.path}/test/console_pty/probe.dart',
        '${Directory.systemTemp.path}/probe_nosuch.log',
        'over',
      ], workingDirectory: root.path);
      expect(res.stderr, contains('5/3'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('L2: control characters in labels are neutralised', () async {
      final root = Directory.current;
      final proc = await Process.start(Platform.resolvedExecutable, [
        '${root.path}/test/console_pty/probe.dart',
        '${Directory.systemTemp.path}/probe_nosuch.log',
        'evil',
      ], workingDirectory: root.path);
      proc.stdin.write('1\n');
      await proc.stdin.close();
      final err = await proc.stderr.transform(utf8.decoder).join();
      await proc.exitCode;
      expect(err, contains('a\u{FFFD}[31mb\u{FFFD}c'));
      expect(err, isNot(contains('\x1b')));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('setTotal fills in a total that arrives later; log prints above', () async {
      final root = Directory.current;
      final res = await Process.run(Platform.resolvedExecutable, [
        '${root.path}/test/console_pty/probe.dart',
        '${Directory.systemTemp.path}/probe_nosuch.log',
        'total',
      ], workingDirectory: root.path);
      expect(res.stderr, contains('T 2/4'));
      expect(res.stderr, contains('logged above\n'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('null total means unknown, like 0', () async {
      final bar = Console.bar(null, label: 'U');
      bar.tick(11);
      await bar.close();
    });

    test('K2: a pipeline that fails before the bar runs frees the line', () async {
      final bar = Console.bar(5, label: 'stuck?');
      await expectLater(_Mem('hello') | bar > _ThrowBeforeRead(), throwsA(isA<ArgumentError>()));
      // The line must be free: the next bar builds without StateError.
      final next = Console.bar(1, label: 'free');
      await next.close();
    });

    test('unknown totals count up', () async {
      final bar = Console.bar(0);
      bar.tick();
      bar.tick(10);
      await bar.close();
    });

    test('close is idempotent', () async {
      final bar = Console.bar(1);
      await bar.close();
      await bar.close();
    });

    test('a second live line is a StateError', () async {
      final bar = Console.bar(1);
      expect(() => Console.bar(2), throwsStateError);
      expect(() => Console.spin('x', Future<void>.value()), throwsStateError);
      await bar.close();
      final ok = Console.bar(1);
      await ok.close();
    });

    test('as a Pipe it counts bytes and closes itself', () async {
      final bar = Console.bar(5, label: 'P');
      final out = await (_Mem('hello') | bar).bytes();
      expect(out, utf8.encode('hello'));
      await bar.close(); // already closed by the pipe: no-op
    });

    test('a failed run prints and rethrows', () async {
      final bar = Console.bar(5);
      await expectLater(_Mem('x') | bar | _Boom() > null, throwsStateError);
    });

    test('works in a download pipeline', () async {
      final dir = await Directory.systemTemp.createTemp('bar_pipe');
      addTearDown(() => dir.delete(recursive: true));
      final hash = Hash.sha256();
      await (_Mem('0123456789') | Console.bar(10) | hash > _Writer(File('${dir.path}/out.bin')));
      expect(hash.hex().length, 64);
    });
  });
}

final class _Mem with Reader {
  _Mem(this._text);
  final String _text;
  @override
  Stream<List<int>> stream() => Stream.value(utf8.encode(_text));
}

final class _Boom implements Pipe {
  @override
  Stream<List<int>> transform(Stream<List<int>> input) async* {
    await for (final _ in input) {
      throw StateError('boom');
    }
  }

  @override
  void abort(Object error) {}
}

final class _Writer implements Writer {
  _Writer(this._file);
  final File _file;
  @override
  Future<void> consume(Stream<List<int>> input) async {
    final sink = _file.openWrite();
    await sink.addStream(input);
    await sink.close();
  }
}

/// Fails before ever listening (an unopenable target).
final class _ThrowBeforeRead implements Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async {
    throw ArgumentError('cannot open target');
  }
}

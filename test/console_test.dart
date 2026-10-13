import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/console.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:test/test.dart';

void main() {
  group('Console.choose', () {
    test('empty choices is an ArgumentError', () {
      expect(Console.choose('Pick', []), throwsArgumentError);
    });
  });

  group('Console.spin', () {
    test('returns the work result', () async {
      expect(await Console.spin('Work', () async => 42), 42);
    });

    test('rethrows the work error', () async {
      expect(
        Console.spin<void>('Work', () => throw StateError('bad')),
        throwsStateError,
      );
    });
  });

  group('Bar', () {
    test('tick counts and stops at the total, returns the bar', () async {
      final bar = Console.bar(3, label: 'T');
      expect(identical(bar.tick(), bar), isTrue);
      bar.tick(5);
      await bar.close();
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
      expect(() => Console.spin('x', () async {}), throwsStateError);
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
      await expectLater(
        _Mem('x') | bar | _Boom() > null,
        throwsStateError,
      );
    });

    test('works in a download pipeline', () async {
      final file = File('${Directory.systemTemp.path}/bar_pipe.bin');
      try {
        final hash = Hash.sha256();
        await (_Mem('0123456789') | Console.bar(10) | hash > _Writer(file));
        expect(hash.hex().length, 64);
      } finally {
        if (await file.exists()) await file.delete();
      }
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

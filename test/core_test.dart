import 'dart:async';
import 'dart:convert';

import 'package:dart_toolkit/core.dart';

import 'support/io.dart';
import 'package:test/test.dart';

void main() {
  timeTests();
  group('Reader', () {
    test('lines() splits on LF, CRLF and CR, across chunks, for futures too', () async {
      final r = _TextChunks(['one\r', '\ntwo\nthr', 'ee\rfour']);
      expect(await r.lines().toList(), ['one', 'two', 'three', 'four']);
      expect(await Future<Reader>.value(Reader.of('a\nb'.codeUnits)).lines().toList(), ['a', 'b']);
    });

    test('stream is the one member to implement', () async {
      expect(await Mem.bytes([1, 2]).bytes(), [1, 2]);
    });

    test('bytes reads everything', () async {
      expect(
        await _Chunks([
          [1],
          [2, 3],
        ]).bytes(),
        [1, 2, 3],
      );
    });

    test('text decodes UTF-8, malformed replaced', () async {
      expect(await Mem.bytes(utf8.encode('héllo')).text(), 'héllo');
      expect(await Mem.bytes([0xff, 0xfe]).text(), '��');
    });

    test('pipe is lazy: nothing flows yet', () async {
      var ran = false;
      final r = Mem.bytes([1]) | _Tap(() => ran = true);
      expect(ran, isFalse);
      await (r > null);
      expect(ran, isTrue);
    });

    test('null pipe returns this reader unchanged', () {
      final r = Mem.bytes([1]);
      expect(identical(r | null, r), isTrue);
    });

    test('| groups like a shell', () async {
      final seen = <int>[];
      await (Mem.bytes([1]) | _Tap(() => seen.add(1)) | _Tap(() => seen.add(2)) > null);
      expect(seen, [1, 2]);
    });

    test('null writer runs upstream and discards', () async {
      var ran = false;
      await (Mem.bytes([1, 2]) | _Tap(() => ran = true) > null);
      expect(ran, isTrue);
    });

    test('method chain needs no parentheses', () async {
      final w = Collect();
      await (Mem.bytes([7]) | null > w);
      expect(w.data, [7]);
    });
  });

  group('pipelines', () {
    test('a probe passes bytes unchanged and counts them against the learned length', () async {
      final heard = <(int, int?)>[];
      final out = await (Reader.of([1, 2, 3]) & _Heard(heard)).bytes();
      expect(out, [1, 2, 3]);
      expect(heard.last, (3, 3));
    });

    test('& on a pipe chain: the probe sees the source through every stage', () async {
      final m = Meter();
      final out = await (Reader.of([1, 2, 3, 4]) & m | _Tap(() {})).bytes();
      expect(out, [1, 2, 3, 4]);
      expect((m.done(), m.total()), (4, 4));
    });

    test('a failing run ends its probes with the error', () async {
      final heard = <(int, int?)>[];
      await expectLater(Reader.of([1]) & _Heard(heard) > _Refuse(), throwsStateError);
      expect(heard, isNotEmpty);
    });

    test('ordering: bytes flow through stages in order', () async {
      final order = <String>[];
      final writer = _OrderWriter(order);
      await (Mem.bytes([1]) | _Tap(() => order.add('pipe')) > writer);
      expect(order, ['pipe', 'write']);
    });

    test('one-shot reader throws StateError when streamed twice', () async {
      final r = _OneShot([1]);
      await (r > null);
      expect(() => r.stream(), throwsStateError);
    });

    test('re-readable reader streams again', () async {
      final r = Mem.bytes([1]);
      await (r > null);
      expect(await r.bytes(), [1]);
    });

    test('an error anywhere fails the whole run', () async {
      expect(Mem.bytes([1]) | BoomPipe() > Collect(), throwsA(isA<StateError>()));
    });

    test('a writer that throws mid-run cancels the reader and rethrows', () async {
      final reader = _CancelReader();
      await expectLater(reader | null > BoomWriter(at: 2), throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(reader.cancelled, isTrue);
    });

    test('a pipe that throws mid-run fails the run', () async {
      expect(Mem.bytes([1]) | BoomPipe() > null, throwsStateError);
    });

    test('backpressure: writer pauses reader', () async {
      var maxInflight = 0;
      var inflight = 0;
      final slow = _SlowWriter(
        () {
          inflight++;
          if (inflight > maxInflight) maxInflight = inflight;
        },
        () {
          inflight--;
        },
      );
      await (_Many(50) > slow);
      expect(maxInflight, lessThanOrEqualTo(2));
    });
  });

  group('Origin', () {
    test('reads through methods; a plain reader is empty', () {
      const o = Origin(url: 'u', status: 200, name: 'n', path: 'p');
      expect([o.url(), o.status(), o.name(), o.path()], ['u', 200, 'n', 'p']);
      expect(Reader.of([1]).origin().url(), isNull);
    });
  });

  group('Future mirrors', () {
    test('Future<Reader> mirrors Reader', () async {
      final f = Future<Reader>.value(Mem.bytes(utf8.encode('x')));
      expect(await f.text(), 'x');
      expect(await f.bytes(), utf8.encode('x'));
      await (f | null > null);
      await (f > null);
    });

    test('a writer that fails before reading closes the source', () async {
      final r = _CloseReader();
      await expectLater(r | _Tap(() {}) > _ThrowFirst(), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(r.closed, isTrue);
      final f = _CloseReader();
      await expectLater(Future<Reader>.value(f) > _ThrowFirst(), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(f.closed, isTrue);
    });

    test('origin() on a Future<Reader> closes the response', () async {
      final r = _CloseReader();
      await Future<Reader>.value(r).origin();
      expect(r.closed, isTrue);
    });

    test('Future<Closeable> mirrors close', () async {
      final c = _Closable();
      await Future<Closeable>.value(c).close();
      expect(c.closed, isTrue);
      await Future<Closeable>.value(c).close();
    });
  });
}

final class _Chunks with Reader {
  _Chunks(this._chunks);
  final List<List<int>> _chunks;
  @override
  Stream<List<int>> stream() => Stream.fromIterable(_chunks);
}

final class _Many with Reader {
  _Many(this.n);
  final int n;
  @override
  Stream<List<int>> stream() async* {
    for (var i = 0; i < n; i++) {
      yield [i];
    }
  }
}

final class _OneShot with Reader {
  _OneShot(this._data);
  final List<int> _data;
  var _used = false;
  @override
  Stream<List<int>> stream() {
    if (_used) throw StateError('one-shot');
    _used = true;
    return Stream.value(_data);
  }
}

final class _Tap implements Pipe {
  _Tap(this._fn);
  final void Function() _fn;
  @override
  Stream<List<int>> transform(Stream<List<int>> input) async* {
    await for (final c in input) {
      _fn();
      yield c;
    }
  }

  @override
  void abort(Object error) {}
}

final class _OrderWriter with Writer {
  _OrderWriter(this.order);
  final List<String> order;
  @override
  Future<void> consume(Stream<List<int>> input) async {
    await for (final _ in input) {}
    order.add('write');
  }
}

final class _SlowWriter with Writer {
  _SlowWriter(this._onStart, this._onEnd);
  final void Function() _onStart;
  final void Function() _onEnd;
  @override
  Future<void> consume(Stream<List<int>> input) async {
    await for (final _ in input) {
      _onStart();
      await Future<void>.delayed(const Duration(milliseconds: 1));
      _onEnd();
    }
  }
}

final class _Closable implements Closeable {
  var closed = false;
  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _CancelReader with Reader {
  var cancelled = false;
  @override
  Stream<List<int>> stream() {
    final controller = StreamController<List<int>>();
    controller.onListen = () async {
      try {
        for (var i = 0; i < 100000; i++) {
          if (controller.isClosed) return;
          controller.add([i & 0xff]);
          await Future<void>.delayed(Duration.zero);
        }
        controller.close();
      } catch (_) {}
    };
    controller.onCancel = () {
      cancelled = true;
    };
    return controller.stream;
  }
}

final class _CloseReader with Reader implements Closeable {
  var closed = false;
  @override
  Stream<List<int>> stream() => Stream.value([1]);
  @override
  Future<void> close() async => closed = true;
}

final class _ThrowFirst with Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async => throw StateError('no');
}

final class _TextChunks with Reader {
  _TextChunks(this._parts);
  final List<String> _parts;
  @override
  Stream<List<int>> stream() => Stream.fromIterable(_parts.map((p) => p.codeUnits));
}

// Times and Spans (core).
void timeTests() {
  test('format and human', () {
    final t = DateTime(2026, 3, 4, 5, 6, 7, 89);
    expect(t.format('yyyy-MM-dd_HHmm ss.SSS'), '2026-03-04_0506 07.089');
    expect(t.format('day dd of MM'), 'day 04 of 03');
    expect(
      [
        850.milliseconds,
        4.2.seconds,
        3.seconds,
        665.seconds,
        11.minutes,
        123.minutes,
        76.hours,
        -2.seconds,
      ].map((d) => d.human()),
      ['850 ms', '4.2 s', '3 s', '11 min 5 s', '11 min', '2 h 3 min', '3 d 4 h', '-2 s'],
    );
  });
}

final class _Heard with Probe {
  _Heard(this._heard);
  final List<(int, int?)> _heard;
  @override
  void update(int done, int? total) => _heard.add((done, total));
}

final class _Refuse with Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async => throw StateError('no');
}

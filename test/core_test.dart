import 'dart:async';
import 'dart:convert';

import 'package:dart_toolkit/core.dart';
import 'package:test/test.dart';

void main() {
  group('Reader', () {
    test('lines() splits on LF, CRLF and CR, across chunks, for futures too', () async {
      final r = _TextChunks(['one\r', '\ntwo\nthr', 'ee\rfour']);
      expect(await r.lines().toList(), ['one', 'two', 'three', 'four']);
      expect(await Future<Reader>.value(Reader.of('a\nb'.codeUnits)).lines().toList(), ['a', 'b']);
    });

    test('stream is the one member to implement', () async {
      expect(await _Mem([1, 2]).bytes(), [1, 2]);
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
      expect(await _Mem(utf8.encode('héllo')).text(), 'héllo');
      expect(await _Mem([0xff, 0xfe]).text(), '��');
    });

    test('pipe is lazy: nothing flows yet', () async {
      var ran = false;
      final r = _Mem([1]).pipe(_Tap(() => ran = true));
      expect(ran, isFalse);
      await (r > null);
      expect(ran, isTrue);
    });

    test('null pipe returns this reader unchanged', () {
      final r = _Mem([1]);
      expect(identical(r.pipe(null), r), isTrue);
    });

    test('| groups like a shell', () async {
      final seen = <int>[];
      await (_Mem([1]) | _Tap(() => seen.add(1)) | _Tap(() => seen.add(2)) > null);
      expect(seen, [1, 2]);
    });

    test('null writer runs upstream and discards', () async {
      var ran = false;
      await (_Mem([1, 2]) | _Tap(() => ran = true) > null);
      expect(ran, isTrue);
    });

    test('method chain needs no parentheses', () async {
      final w = _Sink();
      await _Mem([7]).pipe(null).to(w);
      expect(w.data, [7]);
    });
  });

  group('pipelines', () {
    test('ordering: bytes flow through stages in order', () async {
      final order = <String>[];
      final writer = _OrderWriter(order);
      await (_Mem([1]) | _Tap(() => order.add('pipe')) > writer);
      expect(order, ['pipe', 'write']);
    });

    test('one-shot reader throws StateError when streamed twice', () async {
      final r = _OneShot([1]);
      await (r > null);
      expect(() => r.stream(), throwsStateError);
    });

    test('re-readable reader streams again', () async {
      final r = _Mem([1]);
      await (r > null);
      expect(await r.bytes(), [1]);
    });

    test('an error anywhere fails the whole run', () async {
      expect(_Mem([1]) | _Boom() > _Sink(), throwsA(isA<StateError>()));
    });

    test('a writer that throws mid-run cancels the reader and rethrows', () async {
      final reader = _CancelReader();
      await expectLater(reader | null > _BoomWriter(), throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(reader.cancelled, isTrue);
    });

    test('a pipe that throws mid-run fails the run', () async {
      expect(_Mem([1]) | _Boom() > null, throwsStateError);
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
      final f = Future<Reader>.value(_Mem(utf8.encode('x')));
      expect(await f.text(), 'x');
      expect(await f.bytes(), utf8.encode('x'));
      await (f | null > null);
      await f.to(null);
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

final class _Mem with Reader {
  _Mem(this._data);
  final List<int> _data;
  @override
  Stream<List<int>> stream() => Stream.value(_data);
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

final class _Sink implements Writer {
  final data = <int>[];
  @override
  Future<void> consume(Stream<List<int>> input) async {
    await for (final c in input) {
      data.addAll(c);
    }
  }
}

final class _OrderWriter implements Writer {
  _OrderWriter(this.order);
  final List<String> order;
  @override
  Future<void> consume(Stream<List<int>> input) async {
    await for (final _ in input) {}
    order.add('write');
  }
}

final class _SlowWriter implements Writer {
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

final class _BoomWriter implements Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async {
    var n = 0;
    await for (final _ in input) {
      n++;
      if (n == 2) throw StateError('writer blew up mid-write');
    }
  }
}

final class _CloseReader with Reader implements Closeable {
  var closed = false;
  @override
  Stream<List<int>> stream() => Stream.value([1]);
  @override
  Future<void> close() async => closed = true;
}

final class _ThrowFirst implements Writer {
  @override
  Future<void> consume(Stream<List<int>> input) async => throw StateError('no');
}

final class _TextChunks with Reader {
  _TextChunks(this._parts);
  final List<String> _parts;
  @override
  Stream<List<int>> stream() => Stream.fromIterable(_parts.map((p) => p.codeUnits));
}

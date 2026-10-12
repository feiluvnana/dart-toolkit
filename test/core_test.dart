import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/path.dart';
import 'package:dart_toolkit/process.dart';
import 'package:dart_toolkit/testing.dart';
import 'package:test/test.dart';

String hexOf(Uint8List b) => Digest(b).hex;

void main() {
  group('core pipe spine', () {
    test('a file pipes into a file with the byte count', () async {
      final dir = await Dir.temp();
      try {
        final src = dir.file('src.bin');
        await src.write([1, 2, 3]);
        final dst = dir.file('dst.bin');
        expect(await src.pipe(dst), 3);
        expect(await dst.bytes(), [1, 2, 3]);
      } finally {
        await dir.drop();
      }
    });

    test('bytes pipe as one write; awaitable bytes pipe once arrived', () async {
      final dir = await Dir.temp();
      try {
        final dst = dir.file('a.bin');
        expect(await Uint8List.fromList([9, 9]).pipe(dst), 2);
        expect(await dst.bytes(), [9, 9]);
        final dst2 = dir.file('b.bin');
        expect(await Future.value(Uint8List.fromList([7])).pipe(dst2), 1);
        expect(await dst2.bytes(), [7]);
      } finally {
        await dir.drop();
      }
    });

    test('onProgress is a display-only tap of bytes so far', () async {
      final dir = await Dir.temp();
      try {
        final src = dir.file('src.bin');
        await src.write(List.filled(100, 1));
        final seen = <int>[];
        await src.pipe(dir.file('dst.bin'), onProgress: (done, _) => seen.add(done));
        expect(seen.last, 100);
        expect(seen, orderedEquals(seen.toList()..sort()));
      } finally {
        await dir.drop();
      }
    });

    test('onProgress hears the whole size when the source knows it', () async {
      final totals = <int>{};
      await BufferReader(Uint8List(100)).pipe(BufferWriter(), onProgress: (_, total) => totals.add(total));
      expect(totals, {100});
    });

    test('BufferWriter takes bytes verbatim', () async {
      final w = BufferWriter();
      await w.write(Uint8List.fromList([...utf8.encode('hé'), 255]));
      await w.flush();
      expect(w.take(), [...utf8.encode('hé'), 255]);
    });

    test('lines() streams text line by line', () async {
      final dir = await Dir.temp();
      try {
        final f = dir.file('l.txt');
        await f.write('a\nb\nc');
        expect(await f.lines().toList(), ['a', 'b', 'c']);
      } finally {
        await dir.drop();
      }
    });

    test('a file hashes to the one-shot digest', () async {
      final dir = await Dir.temp();
      try {
        final data = Uint8List.fromList(List.generate(10000, (i) => i & 0xFF));
        final src = dir.file('x.bin');
        await src.write(data);
        expect(hexOf(await src.hash(Hash.sha256)), hexOf(Hash.sha256(data)));
      } finally {
        await dir.drop();
      }
    });

    test('pipe(resume: true) continues from the target size', () async {
      final dir = await Dir.temp();
      try {
        final src = dir.file('src.bin');
        await src.write(List.generate(1000, (i) => i & 0xFF));
        final dst = dir.file('dst.bin');
        await dst.write(List.generate(400, (i) => i & 0xFF)); // a partial copy
        final n = await src.pipe(dst, resume: true);
        expect(n, 600);
        expect(await dst.bytes(), await src.bytes());
      } finally {
        await dir.drop();
      }
    });

    test('large file pipes byte-identical past the 64 KiB chunk', () async {
      final dir = await Dir.temp();
      try {
        final rnd = Random(1234);
        final data = Uint8List.fromList(List.generate(50 * 1024 * 1024, (_) => rnd.nextInt(256)));
        final src = dir.file('src.bin');
        await io.File(src.path).writeAsBytes(data);
        final dst = dir.file('dst.bin');
        expect(await src.pipe(dst), data.length);
        expect(await dst.bytes(), data);
      } finally {
        await dir.drop();
      }
    });

    test('file pipes through cat into a file byte-identical', () async {
      final dir = await Dir.temp();
      try {
        final rnd = Random(7);
        final data = Uint8List.fromList(List.generate(8 * 1024 * 1024, (_) => rnd.nextInt(256)));
        final src = dir.file('src.bin');
        await io.File(src.path).writeAsBytes(data);
        final proc = Process('cat', []);
        final dst = dir.file('dst.bin');
        // src -> proc stdin, proc stdout -> dst, concurrently.
        final w = await proc.writer();
        final r = await proc.reader();
        final dw = await dst.writer();
        final chunk = Uint8List(64 * 1024);
        Future<void> pumpIn() async {
          final sr = await src.reader();
          try {
            while (true) {
              final n = await sr.read(chunk);
              if (n <= 0) break;
              await w.write(Uint8List.sublistView(chunk, 0, n));
            }
            await w.flush();
          } finally {
            await sr.close();
            await w.close();
          }
        }

        Future<void> pumpOut() async {
          try {
            while (true) {
              final n = await r.read(chunk);
              if (n <= 0) break;
              await dw.write(Uint8List.sublistView(chunk, 0, n));
            }
            await dw.flush();
          } finally {
            await r.close();
            await dw.close();
          }
        }

        await Future.wait([pumpIn(), pumpOut()]);
        await proc.wait();
        expect(await dst.bytes(), data);
      } finally {
        await dir.drop();
      }
    }, testOn: '!windows');

    test('in-memory source pipes into a file byte-identical', () async {
      final dir = await Dir.temp();
      try {
        final rnd = Random(5);
        final data = Uint8List.fromList(List.generate(1024 * 1024, (_) => rnd.nextInt(256)));
        final src = _MemorySource(data);
        final dst = dir.file('dst.bin');
        expect(await src.pipe(dst), data.length);
        expect(await dst.bytes(), data);
      } finally {
        await dir.drop();
      }
    });

    test('a failed pipe keeps the old file and no temp', () async {
      final dir = await Dir.temp();
      try {
        final dst = dir.file('dst.txt');
        await dst.write('OLD CONTENT');
        final src = _FailingSource(3);
        await expectLater(src.pipe(dst), throwsA('boom'));
        expect(await dst.text(), 'OLD CONTENT');
        expect((await dir.files()).map((f) => f.name), ['dst.txt']);
      } finally {
        await dir.drop();
      }
    });

    test('a rejected resume pipe closes its reader', () async {
      final dir = await Dir.temp();
      _TrackingSource? src;
      try {
        final f = dir.file('src.txt');
        await f.write('hello');
        src = _TrackingSource(f);
        final proc = Process('cat', []);
        await expectLater(src.pipe(proc, resume: true), throwsArgumentError);
        expect(src.closed, isTrue);
        await proc.close();
      } finally {
        await dir.drop();
      }
    });

    test('lines() streams NDJSON as sent, split multibyte intact', () async {
      // One line per chunk, and 'é' split across two chunks.
      final chunks = <Uint8List>[
        Uint8List.fromList(utf8.encode('{"a":1}\n{"b":')),
        Uint8List.fromList([0xC3]),
        Uint8List.fromList([0xA9, ...utf8.encode('x"}\n')]),
      ];
      final src = _ChunkedBytesSource(chunks);
      expect(await src.lines().toList(), ['{"a":1}', '{"b":éx"}']);
    });

    test('a break after line 1 stops reading the source', () async {
      final src = _CountingSource(Uint8List.fromList(utf8.encode(List.filled(40000, 'line\n').join())));
      expect(await src.lines().first, 'line');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final afterBreak = src.reads;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(src.reads, afterBreak);
    });
  });
}

/// A [Source] yielding fixed chunks (one read per chunk, in order).
final class _ChunkedBytesSource implements Source {
  final List<Uint8List> chunks;
  _ChunkedBytesSource(this.chunks);

  @override
  int? get lengthHint => null;

  @override
  Future<Reader> reader({int from = 0}) async => _ChunkedBytesReader(chunks, from);
}

final class _ChunkedBytesReader implements Reader {
  final Uint8List _all;
  final List<int> _bounds; // chunk end offsets in [_all]
  int _pos;

  _ChunkedBytesReader(List<Uint8List> chunks, int from)
    : _all = Uint8List.fromList([for (final c in chunks) ...c]),
      _bounds = (() {
        final o = <int>[];
        var n = 0;
        for (final c in chunks) {
          n += c.length;
          o.add(n);
        }
        return o;
      })(),
      _pos = from;

  @override
  Future<int> read(Uint8List buf) async {
    if (_pos >= _all.length) return 0;
    // One chunk per read: end at the current chunk boundary.
    var n = _bounds.firstWhere((b) => b > _pos) - _pos;
    if (n > buf.length) n = buf.length;
    buf.setRange(0, n, _all, _pos);
    _pos += n;
    return n;
  }

  @override
  Future<void> close() async {}
}

/// A [Source] counting its [Reader.read] calls.
final class _CountingSource implements Source {
  final Uint8List bytes;
  var reads = 0;
  _CountingSource(this.bytes);

  @override
  int? get lengthHint => bytes.length;

  @override
  Future<Reader> reader({int from = 0}) async => _CountingReader(this, from);
}

final class _CountingReader implements Reader {
  final _CountingSource owner;
  int pos;
  _CountingReader(this.owner, this.pos);

  @override
  Future<int> read(Uint8List buf) async {
    owner.reads++;
    if (pos >= owner.bytes.length) return 0;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final n = (owner.bytes.length - pos).clamp(0, 512).clamp(0, buf.length);
    buf.setRange(0, n, owner.bytes, pos);
    pos += n;
    return n;
  }

  @override
  Future<void> close() async {}
}

final class _MemorySource implements Source {
  final Uint8List _data;
  _MemorySource(this._data);

  @override
  int? get lengthHint => _data.length;

  @override
  Future<Reader> reader({int from = 0}) async => BufferReader(Uint8List.sublistView(_data, from));
}

final class _FailingSource implements Source {
  final int _chunksBeforeThrow;
  _FailingSource(this._chunksBeforeThrow);

  @override
  int? get lengthHint => null;

  @override
  Future<Reader> reader({int from = 0}) async => _FailingReader(_chunksBeforeThrow);
}

final class _FailingReader implements Reader {
  int _left;
  _FailingReader(this._left);

  @override
  Future<int> read(Uint8List buf) async {
    if (_left <= 0) throw 'boom';
    _left--;
    buf.fillRange(0, buf.length, 65);
    return buf.length;
  }

  @override
  Future<void> close() async {}
}

final class _TrackingSource implements Source {
  final File _file;
  bool closed = false;
  _TrackingSource(this._file);

  @override
  int? get lengthHint => null;

  @override
  Future<Reader> reader({int from = 0}) async {
    final inner = await _file.reader(from: from);
    return _TrackingReader(inner, this);
  }
}

final class _TrackingReader implements Reader {
  final Reader _inner;
  final _TrackingSource _owner;
  _TrackingReader(this._inner, this._owner);

  @override
  Future<int> read(Uint8List buf) => _inner.read(buf);

  @override
  Future<void> close() async {
    _owner.closed = true;
    await _inner.close();
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/path.dart';
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
        await src.pipe(dir.file('dst.bin'), onProgress: seen.add);
        expect(seen.last, 100);
        expect(seen, orderedEquals(seen.toList()..sort()));
      } finally {
        await dir.drop();
      }
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
  });
}

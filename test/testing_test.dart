import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_toolkit/core.dart';
import 'package:dart_toolkit/testing.dart';
import 'package:test/test.dart';

void main() {
  group('in-memory seams', () {
    test('a BufferReader is a Source: readings and pipe work on it', () async {
      final src = BufferReader(Uint8List.fromList(utf8.encode('a\nb\n')));
      expect(await src.text(), 'a\nb\n');
      expect(await src.lines().toList(), ['a', 'b']);
      final dst = BufferWriter();
      expect(await src.pipe(dst), 4);
      expect(utf8.decode(dst.take()), 'a\nb\n');
    });

    test('a BufferWriter resumes from its size and keeps its contents on abort', () async {
      final dst = BufferWriter();
      await BufferReader(Uint8List.fromList(utf8.encode('hello'))).pipe(dst);
      final w = await dst.writer();
      await w.write(Uint8List.fromList(utf8.encode('XX')));
      await w.abort();
      expect(await dst.size(), 5);
      final rest = BufferReader(Uint8List.fromList(utf8.encode('hello world')));
      expect(await rest.pipe(dst, resume: true), 6);
      expect(utf8.decode(dst.take()), 'hello world');
    });
  });
}

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('FS Automation Extensions', () {
    late Path testDir;

    setUp(() async {
      testDir = Path.temp / 'dart_toolkit_fs_auto_test';
      await testDir.mkdir();
    });

    tearDown(() async {
      if (await testDir.exists()) {
        await testDir.delete(recursive: true);
      }
    });

    test('Path static getters return valid paths', () {
      expect(Path.current.isNotEmpty, isTrue);
      expect(Path.temp.isNotEmpty, isTrue);
      expect(Path.home.isNotEmpty, isTrue);
    });

    test('Path sha256 and md5 checksums calculate correctly', () async {
      final file = testDir / 'test_hash.txt';
      await file.writeText('hello world');

      // echo -n "hello world" | sha256sum -> b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
      expect(await file.sha256(), equals('b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9'));

      // echo -n "hello world" | md5sum -> 5eb63bbbe01eeed093cb22bb8f5acdc3
      expect(await file.md5(), equals('5eb63bbbe01eeed093cb22bb8f5acdc3'));
    });

    test('streamed and in-memory digests agree across chunk boundaries', () async {
      // Larger than one read buffer, so the streaming path really does chunk.
      final file = testDir / 'big_hash.bin';
      await file.writeBytes(List<int>.generate(1 << 20, (i) => i % 251));

      expect(await file.sha256(), equals((await file.readBytes()).sha256));
      expect(await file.md5(), equals((await file.readBytes()).md5));
    });

    test('Path append and replace edit in-place', () async {
      final file = testDir / 'doc.txt';
      await file.writeText('title: Dart Toolkit\n');

      await file.append('author: feiluvnana\n');
      await file.append('version: 9.0.0\n');

      final lines = await file.readLines();
      expect(lines, equals(['title: Dart Toolkit', 'author: feiluvnana', 'version: 9.0.0']));

      await file.replaceInFile('9.0.0', '9.1.0');
      expect(await file.readText(), contains('version: 9.1.0'));
    });
  });
}

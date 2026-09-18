import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/hash.dart';
import 'package:test/test.dart';

/// The native digest and package:crypto must agree byte for byte, on bytes and on files.
void main() {
  final rnd = Random(3);
  final small = List.generate(1000, (_) => rnd.nextInt(256));
  final big = List.generate(5 << 20, (_) => rnd.nextInt(256)); // spans several 1 MB native buffers

  test('bytes: sha256 and md5 match package:crypto', () {
    for (final data in [
      <int>[],
      [0],
      small,
      big,
    ]) {
      expect(data.sha256, crypto.sha256.convert(data).toString());
      expect(data.md5, crypto.md5.convert(data).toString());
    }
  });

  test('files: streamed digests match package:crypto', () async {
    final dir = Directory.systemTemp.createTempSync('hash_');
    try {
      final f = Path(dir.path) / 'big.bin';
      await f.writeBytes(big);
      expect(await f.sha256(), crypto.sha256.convert(big).toString());
      expect(await f.md5(), crypto.md5.convert(big).toString());
      final empty = Path(dir.path) / 'empty.bin';
      await empty.writeBytes([]);
      expect(await empty.sha256(), crypto.sha256.convert([]).toString());
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('the native path is used on macOS and Linux', () {
    expect(isNativeHashing, Platform.isMacOS || Platform.isLinux);
  }, skip: !(Platform.isMacOS || Platform.isLinux) ? 'no native library expected here' : null);
}

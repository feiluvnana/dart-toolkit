import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('hash', () {
    final data = List.generate(70000, (i) => (i * 31) & 0xff);

    test('every algorithm matches package:crypto, on bytes and on strings', () {
      final refs = {
        Hash.md5: crypto.md5,
        Hash.sha1: crypto.sha1,
        Hash.sha224: crypto.sha224,
        Hash.sha256: crypto.sha256,
        Hash.sha384: crypto.sha384,
        Hash.sha512: crypto.sha512,
      };
      for (final MapEntry(key: h, value: ref) in refs.entries) {
        expect(data.hash(h), ref.convert(data).toString(), reason: '$h');
      }
      expect('hello'.sha1, crypto.sha1.convert(utf8.encode('hello')).toString());
      expect('hello'.sha512, crypto.sha512.convert(utf8.encode('hello')).toString());
      expect(data.sha384, data.hash(Hash.sha384));
    });

    test('crc32 and hmac', () async {
      expect(utf8.encode('The quick brown fox jumps over the lazy dog').crc32, 0x414fa339);
      expect('hello'.crc32, 0x3610a686);
      expect(
        'data'.hmac(Hash.sha256, 'key'),
        crypto.Hmac(crypto.sha256, utf8.encode('key')).convert(utf8.encode('data')).toString(),
      );
      final dir = Directory.systemTemp.createTempSync('crc_');
      try {
        final f = Path(dir.path) / 'x';
        await f.writeText('hello');
        expect(await f.crc32(), 0x3610a686);
        expect(await f.sha1(), 'hello'.sha1);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  final rnd = Random(3);

  final small = List.generate(1000, (_) => rnd.nextInt(256));

  final big = List.generate(5 << 20, (_) => rnd.nextInt(256));

  // spans several 1 MB native buffers

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

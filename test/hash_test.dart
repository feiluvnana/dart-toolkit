import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dart_toolkit/hash.dart';
import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/path.dart';
import 'package:test/test.dart';

String hexOf(Uint8List b) => Digest(b).hex;

const _algos = [Hash.md5, Hash.sha256, Hash.sha512, Hash.crc32, Hash.blake3, Hash.xxh64, Hash.xxh3];

void main() {
  group('hash one-shots and vectors', () {
    test('known answers incl. xxh3/xxh64 vectors', () {
      final abc = utf8.encode('abc');
      expect(hexOf(Hash.sha256(abc)), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(hexOf(Hash.sha256('')), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(hexOf(Hash.md5(abc)), '900150983cd24fb0d6963f7d28e17f72');
      expect(hexOf(Hash.crc32(abc)), '352441c2');
      expect(hexOf(Hash.blake3(abc)), '6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85');
      expect(hexOf(Hash.xxh64(abc)), '44bc2cf5ad770999');
      expect(hexOf(Hash.xxh3(abc)), '78af5f94892f3950');
      expect(hexOf(Hash.xxh3(<int>[])), '2d06800538d394c2');
    });

    test('RFC 4231 HMAC case 2 and checksum key refusal', () {
      expect(
        hexOf(Hash.sha256('what do ya want for nothing?', key: 'Jefe')),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
      expect(() => Hash.crc32('x', key: 'k'), throwsArgumentError);
      expect(() => Hash.xxh3('x', key: 'k'), throwsArgumentError);
    });

    test('HMAC keyed one-shot answers the openssl vector', () {
      expect(hexOf(Hash.sha256('x', key: 'k')), 'c38edc8815c8489f64738978f44008f8596345545f0baa68ef6fcf5c53e57189');
    });

    test('crc32 as an integer answers the zlib vector', () {
      expect(Hash.crc32('data').toInt(), 2918445923);
    });

    test('call(File) directs to the async file hash', () {
      expect(() => Hash.sha256(File('x')), throwsArgumentError);
    });
  });

  group('hash files and streams agree', () {
    test('one-shot across the whole set, small and multi-chunk', () async {
      final small = Uint8List.fromList(utf8.encode('abc'));
      final big = Uint8List.fromList(List.generate(300000, (i) => (i * 7 + 3) & 0xFF));
      for (final algo in _algos) {
        for (final data in [small, big]) {
          // Repeat calls agree: each call opens and finishes its own handle.
          expect(hexOf(algo(data)), hexOf(algo(data)), reason: '${algo.name} len=${data.length}');
        }
        // Text and bytes of the same content hash alike (input normalization).
        expect(hexOf(algo('abc')), hexOf(algo(small)), reason: algo.name);
      }
    });

    test('file hashes equal the one-shot across block boundaries', () async {
      final dir = await Dir.temp();
      try {
        for (final n in [0, 1, 55, 56, 57, 63, 64, 65, 111, 112, 113, 127, 128, 129, 200, 1000]) {
          final data = Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) & 0xFF));
          final file = dir.file('d$n.bin');
          await file.write(data);
          for (final algo in _algos) {
            expect(hexOf(await file.hash(algo)), hexOf(algo(data)), reason: '${algo.name} len=$n');
          }
        }
      } finally {
        await dir.drop();
      }
    });

    test('file() equals the in-memory digest; HMAC file matches', () async {
      final dir = await Dir.temp();
      try {
        final data = Uint8List.fromList(List.generate(200000, (i) => (i * 7 + 3) & 0xFF));
        final file = dir.file('big.bin');
        await file.write(data);
        expect(hexOf(await file.hash(Hash.sha256)), hexOf(Hash.sha256(data)));
        expect(hexOf(await file.hash(Hash.xxh3)), hexOf(Hash.xxh3(data)));
        expect(hexOf(await file.hash(Hash.sha256, key: 'Jefe')), hexOf(Hash.sha256(data, key: 'Jefe')));
      } finally {
        await dir.drop();
      }
    });

    test('file, bytes and download hashes agree on 5 MiB', () async {
      final data = Uint8List.fromList(List.generate(5 * 1024 * 1024, (i) => (i * 7 + 3) & 0xFF));
      final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
      try {
        server.listen((request) async {
          request.response.headers.contentType = io.ContentType.binary;
          request.response.contentLength = data.length;
          request.response.add(data);
          await request.response.close();
        });
        final url = 'http://${server.address.host}:${server.port}/big.bin';
        final dir = await Dir.temp();
        try {
          final file = dir.file('big.bin');
          await file.write(data);
          expect(hexOf(await file.hash(Hash.sha256)), hexOf(Hash.sha256(data)));
          expect(
            hexOf(await Http.get(url).hash(Hash.sha256)),
            hexOf(Hash.sha256(data)),
            reason: 'download streams through the update path',
          );
        } finally {
          await dir.drop();
        }
      } finally {
        await server.close(force: true);
      }
    });

    test('hashing a missing file names it in PathNotFoundException', () async {
      await expectLater(
        File('/nope/absent.bin').hash(Hash.sha256),
        throwsA(isA<io.PathNotFoundException>().having((e) => e.path, 'path', '/nope/absent.bin')),
      );
    });

    test('the event loop stays free during a 500 MB file hash', () async {
      final dir = await Dir.temp();
      try {
        final file = dir.file('half-gig.bin');
        // Synchronous writes: nothing buffers a second copy in memory (a
        // buffered sink would heap the whole half gig and pause the loop in GC).
        final chunk = Uint8List.fromList(List.generate(1024 * 1024, (i) => (i * 7 + 3) & 0xFF));
        final raf = io.File(file.path).openSync(mode: io.FileMode.write);
        try {
          for (var i = 0; i < 500; i++) {
            raf.writeFromSync(chunk);
          }
        } finally {
          raf.closeSync();
        }
        var last = DateTime.now();
        var worst = Duration.zero;
        final tick = Timer.periodic(const Duration(milliseconds: 5), (_) {
          final now = DateTime.now();
          final gap = now.difference(last);
          last = now;
          if (gap > worst) worst = gap;
        });
        try {
          await file.hash(Hash.sha256);
        } finally {
          tick.cancel();
        }
        expect(worst, lessThan(const Duration(milliseconds: 50)), reason: 'worst timer gap was $worst');
      } finally {
        await dir.drop();
      }
    }, timeout: const Timeout(Duration(seconds: 300)));
  });

  group('digest text', () {
    test('hex and base64 spell the bytes; decodes round-trip', () {
      expect(const [0xDE, 0xAD, 0xBE, 0xEF].hex, 'deadbeef');
      expect(Uint8List.fromList(utf8.encode('hello')).base64, 'aGVsbG8=');
      expect(Hex.decode('DEADbeef'), [0xDE, 0xAD, 0xBE, 0xEF]);
      expect(() => Hex.decode('abc'), throwsFormatException);
      expect(() => Hex.decode('zz'), throwsFormatException);
      expect(Base64.decode('aGVsbG8='), utf8.encode('hello'));
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/image.dart';
import 'package:dart_toolkit/video.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import '../projects/medialoader/dashboard.dart';
import '../projects/medialoader/download.dart';
import '../projects/medialoader/media.dart' as media;
import '../projects/medialoader/medialoader.dart';

List<int> get tinyMp4 => base64Decode(
      'AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAAIZnJlZQAABTVtZGF0AAACrQYF//+p'
      '3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMyAwNDgwY2IwIC0gSC4yNjQvTVBF'
      'Ry00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4u'
      'b3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFs'
      'eXNlPTB4MzoweDExMyBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVk'
      'X3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MSBjcW09MCBk'
      'ZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD00IHRocmVhZHM9MiBs'
      'b29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVy'
      'bGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9w'
      'eXJhbWlkPTIgYl9hZGFwdD0xIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MSBvcGVuX2dvcD0w'
      'IHdlaWdodHA9MiBrZXlpbnQ9MjUwIGtleWludF9taW49MTAgc2NlbmVjdXQ9NDAgaW50cmFfcmVm'
      'cmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTM1LjAgcWNvbXA9MC42'
      'MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAIk'
      'ZYiEAFfRaYl09/0GSsLtkoUK/UmGI44o6+YCTKJRbUn/AeFhL1oH/8VIlaV8pVtBl6cKM6bf2vED'
      '8DlCtmXN0E3IGx/uZrpj83XrNWkt4Y9mFLkK7L5ihvXiqdm2y2kctp21wc6gI3S7EhU9kwo6rsuF'
      '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',
    );

void main() {
  late HttpServer server;
  late String base;
  late List<int> testJpg;

  setUpAll(() async {
    // Generate an uncompressed or high-quality test image
    final testImg = img.Image(width: 64, height: 64);
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        testImg.setPixelRgb(x, y, (x * 4) % 256, (y * 4) % 256, ((x + y) * 2) % 256);
      }
    }
    testJpg = img.encodeJpg(testImg, quality: 100);

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((req) {
      if (req.uri.path == '/photo.jpg') {
        req.response
          ..headers.contentType = ContentType('image', 'jpeg')
          ..add(testJpg)
          ..close();
      } else if (req.uri.path == '/video.mp4') {
        req.response
          ..headers.contentType = ContentType('video', 'mp4')
          ..add(tinyMp4)
          ..close();
      } else {
        req.response
          ..statusCode = HttpStatus.notFound
          ..close();
      }
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test('Queue compresses image when imageQuality is specified', () async {
    await Fs.tempDir((tempDir) async {
      final q = Queue(imageQuality: 30);
      final destFile = tempDir.file('photo.jpg');
      final u = board.user('testuser', platform: 'ins');
      final part = u.parts.putIfAbsent('photos', () => Part('photos'));
      final transfer = Transfer(u, part, 'photos/photo.jpg');

      final media.Download download = (to: destFile, url: '$base/photo.jpg', text: null);
      final isNew = await q.save(download, transfer);

      expect(isNew, isTrue);
      expect(await destFile.exists(), isTrue);

      final bytes = await destFile.bytes();
      expect(Image.sniff(bytes), ImageFormat.jpg);
      final decoded = Image.decode(bytes);
      expect(decoded.width(), 64);
      expect(decoded.height(), 64);

      // Compressed at quality 30 should be smaller than quality 100
      expect(bytes.length, lessThan(testJpg.length));
      expect(transfer.done, bytes.length);
    });
  });

  test('Queue compresses video when videoQuality is specified', () async {
    await Fs.tempDir((tempDir) async {
      final q = Queue(videoQuality: 20);
      final destFile = tempDir.file('video.mp4');
      final u = board.user('testuser', platform: 'ins');
      final part = u.parts.putIfAbsent('reels', () => Part('reels'));
      final transfer = Transfer(u, part, 'reels/video.mp4');

      final media.Download download = (to: destFile, url: '$base/video.mp4', text: null);
      final isNew = await q.save(download, transfer);

      expect(isNew, isTrue);
      expect(await destFile.exists(), isTrue);

      final bytes = await destFile.bytes();
      expect(Video.sniff(bytes), VideoFormat.mp4);
      final decoded = await Video.decode(bytes);
      expect(decoded.width(), 64);
      expect(decoded.height(), 64);
      expect(transfer.done, bytes.length);
    });
  });

  test('Queue saves original uncompressed when no quality is specified', () async {
    await Fs.tempDir((tempDir) async {
      final q = Queue();
      final destFile = tempDir.file('photo.jpg');
      final u = board.user('testuser', platform: 'ins');
      final part = u.parts.putIfAbsent('photos', () => Part('photos'));
      final transfer = Transfer(u, part, 'photos/photo.jpg');

      final media.Download download = (to: destFile, url: '$base/photo.jpg', text: null);
      final isNew = await q.save(download, transfer);

      expect(isNew, isTrue);
      expect(await destFile.exists(), isTrue);
      final bytes = await destFile.bytes();
      expect(bytes, testJpg);
    });
  });

  test('Queue logs compression effectiveness even when file does not shrink', () async {
    await Fs.tempDir((tempDir) async {
      final q = Queue(imageQuality: 100);
      final destFile = tempDir.file('photo.jpg');
      final u = board.user('testuser', platform: 'ins');
      final part = u.parts.putIfAbsent('photos', () => Part('photos'));
      final transfer = Transfer(u, part, 'photos/photo.jpg');

      final media.Download download = (to: destFile, url: '$base/photo.jpg', text: null);
      final isNew = await q.save(download, transfer);

      expect(isNew, isTrue);
      expect(await destFile.exists(), isTrue);
      expect(board.events.any((e) => e.line.contains('(compressed from')), isTrue);
    });
  });

  group('CLI options validation', () {
    test('parses quality and aliases properly', () async {
      int? capturedImg;
      int? capturedVid;

      final cmd = Command(
        'test',
        'test',
        params: [...compressionParams],
        handler: (c) {
          final (img, vid) = compressionSettings(c);
          capturedImg = img;
          capturedVid = vid;
        },
      );

      // Default when --compress is passed as a flag: image 85, video 80
      await cmd.run(['--compress']);
      expect(capturedImg, 85);
      expect(capturedVid, 80);

      // --compress with --image-quality override
      await cmd.run(['--compress', '--image-quality', '90']);
      expect(capturedImg, 90);
      expect(capturedVid, 80);

      // --quality sets both
      await cmd.run(['--quality', '70']);
      expect(capturedImg, 70);
      expect(capturedVid, 70);

      await cmd.run(['--image-quality', '75', '--video-quality', '60']);
      expect(capturedImg, 75);
      expect(capturedVid, 60);

      await cmd.run(['--compress-image', '80%', '--compress-video', '50']);
      expect(capturedImg, 80);
      expect(capturedVid, 50);

      await cmd.run(['--image-compression', '65', '--video-compression', '45']);
      expect(capturedImg, 65);
      expect(capturedVid, 45);
    });

    test('rejects invalid quality values', () async {
      final cmd = Command(
        'test',
        'test',
        params: [...compressionParams],
        handler: (_) {},
      );

      final exitCode0 = await cmd.run(['--image-quality', '0']);
      expect(exitCode0, isNot(0));

      final exitCode101 = await cmd.run(['--video-quality', '101']);
      expect(exitCode101, isNot(0));

      final exitCodeNegative = await cmd.run(['--quality', '-5']);
      expect(exitCodeNegative, isNot(0));

      final exitCodeNaN = await cmd.run(['--compress-image', 'abc']);
      expect(exitCodeNaN, isNot(0));
    });
  });
}

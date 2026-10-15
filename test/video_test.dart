import 'dart:convert';

import 'package:dart_toolkit/video.dart';
import 'package:test/test.dart';

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
  group('Video.sniff', () {
    test('names format from magic bytes', () {
      expect(Video.sniff(tinyMp4), VideoFormat.mp4);

      // MOV: 'ftypqt  '
      final mov = [0, 0, 0, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20];
      expect(Video.sniff(mov), VideoFormat.mov);

      // AVI: 'RIFF....AVI '
      final avi = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x41, 0x56, 0x49, 0x20];
      expect(Video.sniff(avi), VideoFormat.avi);

      // WebM EBML header
      final webm = [
        0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x42, 0xF7, 0x81,
        0x01, 0x42, 0xF2, 0x81, 0x04, 0x42, 0x82, 0x84, 0x77, 0x65, 0x62, 0x6D,
      ];
      expect(Video.sniff(webm), VideoFormat.webm);

      // MKV EBML header
      final mkv = [
        0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x42, 0xF7, 0x81,
        0x01, 0x42, 0xF2, 0x81, 0x04, 0x42, 0x82, 0x88, 0x6D, 0x61, 0x74, 0x72,
      ];
      expect(Video.sniff(mkv), VideoFormat.mkv);

      expect(Video.sniff('hello world'.codeUnits), isNull);
      expect(Video.sniff([]), isNull);
    });
  });

  group('Video.decode', () {
    test('decodes bytes and probes metadata', () async {
      final video = await Video.decode(tinyMp4);
      expect(video.width(), 64);
      expect(video.height(), 64);
      expect(video.fps(), 10.0);
      expect(video.duration().inMilliseconds, greaterThan(0));
    });

    test('unknown or broken bytes throw ContentException', () async {
      expect(() => Video.decode([1, 2, 3]), throwsA(isA<FormatException>()));
      expect(() => Video.decode(List.filled(100, 0)), throwsA(isA<FormatException>()));
    });
  });

  group('Reader.video', () {
    test('reads a value', () async {
      final video = await _Mem(tinyMp4).video();
      expect(video.width(), 64);
    });

    test('mirror on Future<Reader>', () async {
      final video = await Future<Reader>.value(_Mem(tinyMp4)).video();
      expect(video.height(), 64);
    });
  });

  group('Video', () {
    test('encode validation: bad quality or size throws ArgumentError', () async {
      final video = await Video.decode(tinyMp4);
      expect(() => video.encode(VideoFormat.mp4, quality: 0), throwsArgumentError);
      expect(() => video.encode(VideoFormat.mp4, quality: 101), throwsArgumentError);
      expect(() => video.encode(VideoFormat.mp4, width: 0), throwsArgumentError);
      expect(() => video.encode(VideoFormat.mp4, height: -1), throwsArgumentError);
    });

    test('encode compresses video and returns Reader', () async {
      final video = await Video.decode(tinyMp4);
      final reader = video.encode(VideoFormat.mp4, quality: 30);
      final compressedBytes = await reader.bytes();
      expect(compressedBytes, isNotEmpty);
      expect(Video.sniff(compressedBytes), VideoFormat.mp4);

      final recoded = await Video.decode(compressedBytes);
      expect(recoded.width(), 64);
      expect(recoded.height(), 64);
    });

    test('encode supports scaling dimensions', () async {
      final video = await Video.decode(tinyMp4);
      final compressedBytes = await video.encode(VideoFormat.mp4, width: 32).bytes();
      expect(compressedBytes, isNotEmpty);

      final recoded = await Video.decode(compressedBytes);
      expect(recoded.width(), 32);
      expect(recoded.height(), 32);
    });

    test('Future mirrors match', () async {
      final f = Future.value(await Video.decode(tinyMp4));
      expect(await f.width(), 64);
      expect(await f.height(), 64);
      expect(await f.fps(), 10.0);
      expect((await f.duration()).inMilliseconds, greaterThan(0));

      final bytes = await f.encode(VideoFormat.mp4, quality: 50).bytes();
      expect(bytes, isNotEmpty);
    });
  });
}

final class _Mem with Reader {
  _Mem(this._bytes);
  final List<int> _bytes;
  @override
  Stream<List<int>> stream() => Stream.value(_bytes);
}

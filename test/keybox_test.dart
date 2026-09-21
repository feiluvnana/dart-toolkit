import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Keybox CLI & Scraper Validation', () {
    final tempDir = Directory.systemTemp.createTempSync('keybox_test_');

    tearDownAll(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('keybox CLI parses format, concurrency, and default options correctly', () async {
      String? chosenFormat;
      int? concurrency;
      bool? shouldCompress;

      final format = Opt.among('format', ['mp3', 'flac', 'all'], abbr: 'f', description: 'Music format').or('all');
      final workers = Opt.number('concurrency', abbr: 'j', description: 'Concurrent download workers').or(4);
      final compress = Flag('compress', abbr: 'c', description: 'Compress directory after download');

      final cli = Cli(name: 'keybox', description: 'Key BOX Scraper & Downloader', options: [format, workers, compress])
        ..action((ctx) {
          chosenFormat = ctx(format);
          concurrency = ctx(workers);
          shouldCompress = ctx(compress);
        });

      await cli.run(['--format', 'flac', '-j', '8', '--compress']);

      expect(chosenFormat, equals('flac'));
      expect(concurrency, equals(8));
      expect(shouldCompress, isTrue);
    });

    test('HTML parsing for track titles and disc formats', () {
      const sampleHtml = '''
        <div class="key_cd_track_box">
          <ul>
            <li>
              <div class="track_disc_title">DISC.01 Kanon Original Soundtrack</div>
              <div class="track_disc_text_style1">
                1. 朝影<br>
                2. 夢の跡<br>
                3. 風の辿り着く場所
              </div>
            </li>
          </ul>
        </div>
      ''';

      final doc = HtmlDocument.parse(sampleHtml);
      final discTitle = doc.$('.track_disc_title').first.text.filename;
      final d = int.parse(discTitle.match(RegExp(r'DISC\.(\d+)'), 1)!);
      expect(d, equals(1));
      expect(discTitle.contains('DISC.01'), isTrue);

      final lines = doc.$('.track_disc_text_style1').first.lines;
      expect(lines.length, equals(3));
      expect(lines[0], equals('1. 朝影'));
      expect(lines[1], equals('2. 夢の跡'));
      expect(lines[2], equals('3. 風の辿り着く場所'));
    });
  });
}

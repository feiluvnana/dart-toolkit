import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Modernization Tests', () {
    test('Codec static dot shorthands', () {
      final jsonCodec = Codec.json;
      final htmlCodec = Codec.html;
      final yamlCodec = Codec.yaml;
      final tomlCodec = Codec.toml;
      final csvCodec = Codec.csv;

      expect(jsonCodec, isA<Codec<Json>>());
      expect(htmlCodec, isA<Codec<Markup>>());
      expect(yamlCodec, isA<Codec<Json>>());
      expect(tomlCodec, isA<Codec<Json>>());
      expect(csvCodec, isA<Codec<Csv>>());

      final jsonDoc = jsonCodec.parse('{"status": "ok"}');
      expect(jsonDoc.text('status'), 'ok');

      final htmlDoc = htmlCodec.parse('<h1>Hello</h1>');
      expect(htmlDoc.$('h1').text, 'Hello');
    });

    test('Reply document extensions and selector shorthands', () {
      final reply = Reply.text('<html><body><div id="content"><p>Test paragraph</p></div></body></html>');
      expect(reply.html, isA<Markup>());
      expect(reply.$('#content p').text, 'Test paragraph');
      expect(reply.$xpath('//div[@id="content"]/p').text, 'Test paragraph');
    });

    test('SysResult JSON accessors', () {
      final res = const SysResult(code: 0, out: '{"version": "7.1.0", "active": true}', err: '');
      expect(res.json, isA<Json>());
      expect(res.json.text('version'), '7.1.0');
      expect(res.json.flag('active'), isTrue);

      final decoded = res.decodeJson<Map<String, dynamic>>();
      expect(decoded['version'], '7.1.0');
      expect(decoded['active'], isTrue);
    });

    test('System.run with shell: true', () async {
      final res = await System.run('echo', ['hello'], shell: true);
      expect(res.stdout.trim(), 'hello');
    });

    test('CliParser choose string choices', () {
      final parser = CliParser();
      final fmt = parser.choose('format', ['mp3', 'flac', 'both'], def: 'mp3');
      parser.parse(['--format', 'flac']);
      expect(fmt(), 'flac');

      final parserDef = CliParser();
      final fmtDef = parserDef.choose('format', ['mp3', 'flac', 'both'], def: 'mp3');
      parserDef.parse([]);
      expect(fmtDef(), 'mp3');
    });

    test('IterableTerminals: split, countBy, avg', () {
      final numbers = [1, 2, 3, 4, 5, 6];
      final (evens, odds) = numbers.split((n) => n.isEven);
      expect(evens, [2, 4, 6]);
      expect(odds, [1, 3, 5]);

      expect(numbers.avg(), 3.5);
      expect(<int>[].avg(), isNull);

      final words = ['apple', 'apricot', 'banana', 'blueberry', 'cherry'];
      final byFirstLetter = words.countBy((w) => w[0]);
      expect(byFirstLetter['a'], 2);
      expect(byFirstLetter['b'], 2);
      expect(byFirstLetter['c'], 1);
    });

    test('Concurrent.map with progress indicator', () async {
      final items = [1, 2, 3, 4];
      final results = await Concurrent.map(
        items,
        (x) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return x * 10;
        },
        progress: 'Calculating',
      );
      expect(results, [10, 20, 30, 40]);
    });
  });
}

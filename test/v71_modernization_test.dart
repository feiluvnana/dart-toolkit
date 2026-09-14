import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Modernization Tests', () {
    test('DocumentFormat static dot shorthands', () {
      final DocumentFormat<Json, Object?> jsonCodec = .json;
      final DocumentFormat<Markup, Markup> htmlCodec = .html;
      final DocumentFormat<Json, Object?> yamlCodec = .yaml;
      final DocumentFormat<Json, Object?> tomlCodec = .toml;
      final DocumentFormat<Csv, Iterable<Map<String, Object?>>> csvCodec = .csv;

      expect(jsonCodec, isA<JsonFormat>());
      expect(htmlCodec, isA<HtmlFormat>());
      expect(yamlCodec, isA<YamlFormat>());
      expect(tomlCodec, isA<TomlFormat>());
      expect(csvCodec, isA<CsvFormat>());

      final jsonDoc = jsonCodec.parse('{"status": "ok"}');
      expect(jsonDoc.text('status'), 'ok');

      final htmlDoc = htmlCodec.parse('<h1>Hello</h1>');
      expect(htmlDoc.$('h1').text, 'Hello');
    });

    test('Response document extensions and selector shorthands', () {
      final reply = Response.text(
        '<html><body><div id="content"><p>Test paragraph</p></div></body></html>',
      );
      expect(reply.html, isA<Markup>());
      expect(reply.$('#content p').text, 'Test paragraph');
      expect(reply.$xpath('//div[@id="content"]/p').text, 'Test paragraph');
    });

    test('SysResult JSON accessors', () {
      final res = const SysResult(
        exitCode: 0,
        stdout: '{"version": "7.1.0", "active": true}',
        stderr: '',
      );
      expect(res.json, isA<Json>());
      expect(res.json.text('version'), '7.1.0');
      expect(res.json.flag('active'), isTrue);

      final decoded = res.decodeJson<Map<String, dynamic>>();
      expect(decoded['version'], '7.1.0');
      expect(decoded['active'], isTrue);
    });

    test('run with shell: true', () async {
      final res = await run('echo', ['hello'], shell: true);
      expect(res.stdout.trim(), 'hello');
    });

    test('CliParser choose string choices', () {
      final parser = CliParser();
      final fmt = parser.choose('format', [
        'mp3',
        'flac',
        'both',
      ], defaultsTo: 'mp3');
      parser.parse(['--format', 'flac']);
      expect(fmt(), 'flac');

      final parserDef = CliParser();
      final fmtDef = parserDef.choose('format', [
        'mp3',
        'flac',
        'both',
      ], defaultsTo: 'mp3');
      parserDef.parse([]);
      expect(fmtDef(), 'mp3');
    });

    test('IterableTerminals: split, countBy, avg', () {
      final numbers = [1, 2, 3, 4, 5, 6];
      final (evens, odds) = numbers.split((n) => n.isEven);
      expect(evens, [2, 4, 6]);
      expect(odds, [1, 3, 5]);

      expect(numbers.average(), 3.5);
      expect(<int>[].average(), isNull);

      final words = ['apple', 'apricot', 'banana', 'blueberry', 'cherry'];
      final byFirstLetter = words.countBy((w) => w[0]);
      expect(byFirstLetter['a'], 2);
      expect(byFirstLetter['b'], 2);
      expect(byFirstLetter['c'], 1);
    });

    test('parallelMap with progress indicator', () async {
      final items = [1, 2, 3, 4];
      final results = await items.parallelMap((x) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return x * 10;
      }, progress: 'Calculating');
      expect(results, [10, 20, 30, 40]);
    });
  });
}

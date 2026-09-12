import 'dart:io';
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('v7.1 Modernization Tests', () {
    test('Codec static dot shorthands', () {
      final jsonCodec = Codec.json;
      final htmlCodec = Codec.html;
      final yamlCodec = Codec.yaml;
      final tomlCodec = Codec.toml;
      final csvCodec = Codec.csv;

      expect(jsonCodec, equals(format.json));
      expect(htmlCodec, equals(format.html));
      expect(yamlCodec, equals(format.yaml));
      expect(tomlCodec, equals(format.toml));
      expect(csvCodec, equals(format.csv));

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

    test('system.run with shell: true', () async {
      final res = await system.run('echo', ['hello'], shell: true);
      expect(res.stdout.trim(), 'hello');
    });

    test('cli.choose string choices', () {
      final isolatedCli = CliAccessor.isolated();
      final fmt = isolatedCli.choose('format', ['mp3', 'flac', 'both'], def: 'mp3');
      isolatedCli.parse(['--format', 'flac']);
      expect(fmt(), 'flac');

      final isolatedCliDef = CliAccessor.isolated();
      final fmtDef = isolatedCliDef.choose('format', ['mp3', 'flac', 'both'], def: 'mp3');
      isolatedCliDef.parse([]);
      expect(fmtDef(), 'mp3');
    });

    test('io.state DiskState operations', () {
      final tempDir = Directory.systemTemp.createTempSync('disk_state_test_');
      try {
        final statePath = io.path.join(tempDir.path, 'state.json');
        const countSlot = Slot<int>('count');
        const nameSlot = Slot<String>('name');

        final state = io.state(statePath);
        expect(state.holds(countSlot), isFalse);
        expect(state.read(countSlot), isNull);

        state.write(countSlot, 42);
        state.write(nameSlot, 'alpha');
        expect(state.holds(countSlot), isTrue);
        expect(state.read(countSlot), 42);
        expect(state.read(nameSlot), 'alpha');

        state.save();
        expect(File(statePath).existsSync(), isTrue);

        // Reload from disk
        final reloaded = io.state(statePath);
        expect(reloaded.read(countSlot), 42);
        expect(reloaded.read(nameSlot), 'alpha');

        reloaded.drop(countSlot);
        expect(reloaded.holds(countSlot), isFalse);
        reloaded.save();

        final afterDrop = io.state(statePath);
        expect(afterDrop.holds(countSlot), isFalse);
        expect(afterDrop.read(nameSlot), 'alpha');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
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

    test('concurrent.run with progress indicator', () async {
      final items = [1, 2, 3, 4];
      final results = await concurrent.run(
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

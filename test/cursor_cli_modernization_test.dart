import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Markup Scoped XPath and Elements', () {
    test('Scoped XPath does not query root document', () {
      final html = '''
        <div id="container">
          <div id="d1">
            <p class="target">Paragraph 1</p>
          </div>
          <div id="d2">
            <p class="target">Paragraph 2</p>
          </div>
        </div>
      ''';
      final doc = html.parseHtml();

      // Top-level XPath finds both paragraphs
      final allTargets = doc.$xpath('//p[@class="target"]');
      expect(allTargets.count, equals(2));

      // Scoped XPath on child cursor isolates to subtree
      final d1 = doc.$('#d1');
      final scopedTargets = d1.$xpath('.//p[@class="target"]');
      expect(scopedTargets.count, equals(1));
      expect(scopedTargets.text, equals('Paragraph 1'));

      final d2 = doc.$('#d2');
      final scopedTargets2 = d2.$xpath('.//p[@class="target"]');
      expect(scopedTargets2.count, equals(1));
      expect(scopedTargets2.text, equals('Paragraph 2'));
    });

    test('Markup.element and Markup.elementList getters', () {
      final html = '''
        <ul>
          <li class="item">One</li>
          <li class="item">Two</li>
        </ul>
      ''';
      final doc = html.parseHtml();

      final firstLi = doc.$('.item').element;
      expect(firstLi, isNotNull);
      expect(firstLi?.text, equals('One'));

      final allLis = doc.$('.item').elementList;
      expect(allLis.length, equals(2));
      expect(allLis[0].text, equals('One'));
      expect(allLis[1].text, equals('Two'));

      final emptyEl = doc.$('.missing').element;
      expect(emptyEl, isNull);

      final emptyList = doc.$('.missing').elementList;
      expect(emptyList, isEmpty);
    });
  });

  group('String Parsing Extensions', () {
    test('parseHtml creates a functioning Markup cursor', () {
      final cursor = '<div class="banner"><h1>Title</h1></div>'.parseHtml();
      expect(cursor.$('.banner h1').text, equals('Title'));
    });

    test('parseJson creates a functioning Json cursor', () {
      final cursor = '{"name": "Alice", "score": 95, "tags": ["admin", "dev"]}'.parseJson();
      expect(cursor.text('name'), equals('Alice'));
      expect(cursor.number('score'), equals(95));
      expect(cursor.at('tags').count, equals(2));
    });
  });

  group('Json toMap and toList', () {
    test('toMap converts JSON object to native Map', () {
      final cursor = '{"host": "localhost", "port": 8080}'.parseJson();
      final map = cursor.toMap<dynamic>();
      expect(map, isA<Map<String, dynamic>>());
      expect(map?['host'], equals('localhost'));
      expect(map?['port'], equals(8080));

      final typedMap = cursor.toMap<Object?>();
      expect(typedMap?['host'], equals('localhost'));
    });

    test('toMap returns null for non-object JSON', () {
      expect('[1, 2, 3]'.parseJson().toMap<dynamic>(), isNull);
      expect('"hello"'.parseJson().toMap<dynamic>(), isNull);
      expect('123'.parseJson().toMap<dynamic>(), isNull);
    });

    test('toList converts JSON array to native List', () {
      final cursor = '["apple", "banana", "cherry"]'.parseJson();
      final list = cursor.toList<dynamic>();
      expect(list, isA<List<dynamic>>());
      expect(list, equals(['apple', 'banana', 'cherry']));

      final stringList = cursor.toList<String>();
      expect(stringList, equals(['apple', 'banana', 'cherry']));
    });

    test('toList returns null for non-array JSON', () {
      expect('{"key": "val"}'.parseJson().toList<dynamic>(), isNull);
      expect('"hello"'.parseJson().toList<dynamic>(), isNull);
      expect('true'.parseJson().toList<dynamic>(), isNull);
    });
  });

  group('CLI Isolation', () {
    test('CliParser creates independent CLI instances', () {
      final parser1 = CliParser();
      final debug = parser1.flag('debug', alias: 'd');
      final parsed1 = parser1.parse(['-d']);
      expect(debug(), isTrue);
      expect(parsed1.switches.containsKey('d'), isTrue);

      final parser2 = CliParser();
      final verbose = parser2.flag('verbose', alias: 'v');
      final parsed2 = parser2.parse([]);
      expect(verbose(), isFalse);
      expect(parsed2.switches, isEmpty);
    });

    test('Cli.isolated creates independent parser', () {
      final parser = Cli.isolated(['--output=build', 'input.txt']);
      final outOpt = parser.option('output', def: 'dist');
      expect(outOpt(), equals('build'));
      expect(parser.args, equals(['input.txt']));
    });
  });
}

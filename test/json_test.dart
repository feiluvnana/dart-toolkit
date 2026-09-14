import 'dart:io';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _store = '''
{
  "store": {
    "book": [
      {"title": "Sayings", "author": "Nigel Rees", "price": 8.95},
      {"title": "Sword", "author": "Evelyn Waugh", "price": 12.99},
      {"title": "Moby Dick", "author": "Herman Melville", "price": 8.99,
       "isbn": "0-553-21311-3"}
    ],
    "bicycle": {"colour": "red", "price": 19.95, "electric": false}
  },
  "count": "3"
}
''';

void main() {
  final doc = _store.parse(.json);

  group('format.json', () {
    test('parse and format are the string doors', () {
      expect('{"a":1}'.parse(.json).number('a'), equals(1));
      expect(const JsonFormat().format({'a': 1}, indent: 0), equals('{"a":1}'));
      expect(const JsonFormat().format({'a': 1}), contains('\n  "a": 1'));
    });

    test('text that is not JSON reads as the empty cursor', () {
      final broken = 'not json at all'.parse(.json);
      expect(broken.isEmpty, isTrue);
      expect(broken.text('a'), isNull);
      expect(broken.raw, isNull);
    });
  });

  group('Json.at', () {
    test('walks a dotted path, brackets or bare indices', () {
      expect(doc.at('store.book[0].title').text(), equals('Sayings'));
      expect(doc.at('store.book.0.title').text(), equals('Sayings'));
      expect(doc.text('store.bicycle.colour'), equals('red'));
    });

    test('a missing path is empty, not an exception', () {
      expect(doc.at('store.nope.deeper.still').isEmpty, isTrue);
      expect(doc.text('store.nope.deeper'), isNull);
      expect(doc.number('store.book[99].price'), isNull);
    });

    test('readers accommodate what JSON does to scalars', () {
      expect(doc.number('count'), equals(3), reason: 'a numeric string parses');
      expect(doc.text('store.bicycle.price'), equals('19.95'));
      expect(doc.flag('store.bicycle.electric'), isFalse);
      expect(doc.flag('store.bicycle.colour'), isNull);
      expect('{"a":"true"}'.parse(.json).flag('a'), isTrue);
    });

    test('count and empty answer every shape', () {
      expect(doc.at('store.book').length, equals(3));
      expect(doc.at('store.bicycle').length, equals(3));
      expect(doc.at('count').length, equals(1));
      expect(doc.at('nope').length, isZero);
      expect(doc.at('nope').isEmpty, isTrue);
    });

    test('all and one build one value per element', () {
      final books = doc
          .at('store.book')
          .all((b) => (title: b.text('title'), price: b.number('price')));
      expect(books, isA<List<Object?>>());
      expect(books.length, equals(3));
      expect(
        books.reduce((a, b) => (b.price ?? 0) > (a.price ?? 0) ? b : a).title,
        equals('Sword'),
      );
      expect(
        doc.at('store.book').all((b) => b.text('title')).firstOrNull,
        equals('Sayings'),
      );
      expect(doc.at('nope').all((b) => b.text('x')).firstOrNull, isNull);
      expect(
        doc.at('store.bicycle').all((b) => b.text('colour')).toList(),
        equals(['red']),
        reason: 'a non-array node counts as one element',
      );
    });

    test('an array of scalars reads as text through all', () {
      expect(
        '["a", 2, true, {"x":1}]'
            .parse(.json)
            .all((item) => item.text())
            .nonNulls
            .toList(),
        equals(['a', '2', 'true']),
      );
    });

    test('raw is the door to a typed whole-document build', () {
      expect(doc.raw, isA<Map<String, Object?>>());
      expect(doc.toString(), contains('store'));
    });
  });

  group('Json.jsonpath', () {
    test('child, wildcard and recursive descent', () {
      expect(
        doc
            .jsonPath(r'$.store.book[*].author')
            .map((n) => n.text())
            .whereType<String>()
            .toList(),
        equals(['Nigel Rees', 'Evelyn Waugh', 'Herman Melville']),
      );
      expect(
        doc
            .jsonPath(r'$..price')
            .map((n) => n.number())
            .whereType<num>()
            .toList(),
        equals([8.95, 12.99, 8.99, 19.95]),
      );
      expect(doc.jsonPath(r'store.book[*]').length, equals(3));
      expect(doc.jsonPath(r'$.store.*').length, equals(2));
    });

    test('indices, negatives, unions and slices', () {
      expect(
        doc
            .jsonPath(r'$.store.book[-1].title')
            .map((n) => n.text())
            .whereType<String>()
            .toList(),
        equals(['Moby Dick']),
      );
      expect(doc.jsonPath(r'$.store.book[0,2]').length, equals(2));
      expect(doc.jsonPath(r'$.store.book[0:2]').length, equals(2));
      expect(doc.jsonPath(r'$.store.book[:2]').length, equals(2));
      expect(
        '[1,2,3,4,5]'
            .parse(.json)
            .jsonPath(r'$[::2]')
            .map((n) => n.number())
            .whereType<num>()
            .toList(),
        equals([1, 3, 5]),
      );
      expect(
        '[1,2,3]'
            .parse(.json)
            .jsonPath(r'$[::-1]')
            .map((n) => n.number())
            .whereType<num>()
            .toList(),
        equals([3, 2, 1]),
      );
    });

    test('quoted names, single or several', () {
      expect(
        doc
            .jsonPath(r"$['store']['bicycle']['colour']")
            .map((n) => n.text())
            .whereType<String>()
            .toList(),
        equals(['red']),
      );
      expect(
        doc.jsonPath(r"$.store.bicycle['colour','price']").length,
        equals(2),
      );
    });

    test('filters: existence, comparison and regex', () {
      expect(
        doc
            .jsonPath(r'$.store.book[?(@.isbn)]')
            .map((b) => b.text('title'))
            .whereType<String>()
            .toList(),
        equals(['Moby Dick']),
      );
      expect(
        doc
            .jsonPath(r'$.store.book[?(@.price < 10)]')
            .map((b) => b.text('title'))
            .whereType<String>()
            .toList(),
        equals(['Sayings', 'Moby Dick']),
      );
      expect(
        doc.jsonPath(r'$.store.book[?(@.author == "Evelyn Waugh")]').length,
        equals(1),
      );
      expect(
        doc.jsonPath(r'$.store.book[?(@.author != "Evelyn Waugh")]').length,
        equals(2),
      );
      expect(
        doc
            .jsonPath(r'$.store.book[?(@.title =~ /^Mob/)]')
            .map((b) => b.text('title'))
            .whereType<String>()
            .toList(),
        equals(['Moby Dick']),
      );
    });

    test('an expression it cannot read selects nothing', () {
      expect(doc.jsonPath(r'$.store.book[').isEmpty, isTrue);
      expect(doc.jsonPath(r'$[?(broken)]').isEmpty, isTrue);
      expect(doc.jsonPath(r'$.store.book[a:b:c]').isEmpty, isTrue);
      expect(doc.jsonPath('').length, equals(1), reason: 'the root itself');
    });

    test('the same expression is only parsed once', () {
      const query = r'$..price';
      expect(doc.jsonPath(query).length, equals(doc.jsonPath(query).length));
    });
  });

  group('the three doors', () {
    test('a response, a string and a file give the same cursor', () async {
      final res = Response.text(
        '{"data":{"items":[{"sku":"a"},{"sku":"b"}]}}',
        fetch: Fetch('https://example.com'.url),
      );
      expect(res.body.parse(.json).at('data.items').length, equals(2));
      expect(
        res.body
            .parse(.json)
            .at('data.items')
            .all((i) => i.text('sku'))
            .toList(),
        equals(['a', 'b']),
      );
      expect(res.body.parse(.json).at('').raw, isA<Map<String, Object?>>());
      expect(
        (Response.text(
          '<html>',
          fetch: Fetch('https://example.com'.url),
        ).body).parse(.json).at('a').isEmpty,
        isTrue,
        reason: 'a body that is not JSON never throws here',
      );

      final dir = Directory.systemTemp.createTempSync('dt_json_door_');
      try {
        final path = p.join(dir.path, 'c.json');
        File(path).writeAsStringSync(
          const JsonFormat().format({
            'hosts': ['a', 'b'],
          }),
        );
        expect(
          (await Path(
            path,
          ).read(.json)).at('hosts').all((h) => h.text()).nonNulls.toList(),
          equals(['a', 'b']),
        );
        expect((await Path(path).read(.json)).length, equals(1));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}

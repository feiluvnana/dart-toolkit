import 'package:dart_toolkit/dart_toolkit.dart';
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
  final doc = format.json.parse(_store);

  group('format.json', () {
    test('parse and format are the string doors', () {
      expect(format.json.parse('{"a":1}').number('a'), equals(1));
      expect(format.json.format({'a': 1}, indent: 0), equals('{"a":1}'));
      expect(format.json.format({'a': 1}), contains('\n  "a": 1'));
    });

    test('text that is not JSON reads as the empty cursor', () {
      final broken = format.json.parse('not json at all');
      expect(broken.empty, isTrue);
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
      expect(doc.at('store.nope.deeper.still').empty, isTrue);
      expect(doc.text('store.nope.deeper'), isNull);
      expect(doc.number('store.book[99].price'), isNull);
    });

    test('readers accommodate what JSON does to scalars', () {
      expect(doc.number('count'), equals(3), reason: 'a numeric string parses');
      expect(doc.text('store.bicycle.price'), equals('19.95'));
      expect(doc.flag('store.bicycle.electric'), isFalse);
      expect(doc.flag('store.bicycle.colour'), isNull);
      expect(format.json.parse('{"a":"true"}').flag('a'), isTrue);
    });

    test('count and empty answer every shape', () {
      expect(doc.at('store.book').count, equals(3));
      expect(doc.at('store.bicycle').count, equals(3));
      expect(doc.at('count').count, equals(1));
      expect(doc.at('nope').count, isZero);
      expect(doc.at('nope').empty, isTrue);
    });

    test('all and one build one value per element', () {
      final books = doc
          .at('store.book')
          .all((b) => (title: b.text('title'), price: b.number('price')));
      expect(books, isA<List<Object?>>());
      expect(books.collect(.count()), equals(3));
      expect(
        books.collect(.max.by((b) => b.price ?? 0))?.title,
        equals('Sword'),
      );
      expect(
        doc.at('store.book').all((b) => b.text('title')).collect(.first()),
        equals('Sayings'),
      );
      expect(doc.at('nope').all((b) => b.text('x')).collect(.first()), isNull);
      expect(
        doc.at('store.bicycle').all((b) => b.text('colour')).collect(.list()),
        equals(['red']),
        reason: 'a non-array node counts as one element',
      );
    });

    test('an array of scalars reads as text through all', () {
      expect(
        format.json
            .parse('["a", 2, true, {"x":1}]')
            .all((item) => item.text())
            .nonNull
            .collect(.list()),
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
            .jsonpath(r'$.store.book[*].author')
            .transform(.map.nonnull((n) => n.text()))
            .collect(.list()),
        equals(['Nigel Rees', 'Evelyn Waugh', 'Herman Melville']),
      );
      expect(
        doc
            .jsonpath(r'$..price')
            .transform(.map.nonnull((n) => n.number()))
            .collect(.list()),
        equals([8.95, 12.99, 8.99, 19.95]),
      );
      expect(doc.jsonpath(r'store.book[*]').collect(.count()), equals(3));
      expect(doc.jsonpath(r'$.store.*').collect(.count()), equals(2));
    });

    test('indices, negatives, unions and slices', () {
      expect(
        doc
            .jsonpath(r'$.store.book[-1].title')
            .transform(.map.nonnull((n) => n.text()))
            .collect(.list()),
        equals(['Moby Dick']),
      );
      expect(doc.jsonpath(r'$.store.book[0,2]').collect(.count()), equals(2));
      expect(doc.jsonpath(r'$.store.book[0:2]').collect(.count()), equals(2));
      expect(doc.jsonpath(r'$.store.book[:2]').collect(.count()), equals(2));
      expect(
        format.json
            .parse('[1,2,3,4,5]')
            .jsonpath(r'$[::2]')
            .transform(.map.nonnull((n) => n.number()))
            .collect(.list()),
        equals([1, 3, 5]),
      );
      expect(
        format.json
            .parse('[1,2,3]')
            .jsonpath(r'$[::-1]')
            .transform(.map.nonnull((n) => n.number()))
            .collect(.list()),
        equals([3, 2, 1]),
      );
    });

    test('quoted names, single or several', () {
      expect(
        doc
            .jsonpath(r"$['store']['bicycle']['colour']")
            .transform(.map.nonnull((n) => n.text()))
            .collect(.list()),
        equals(['red']),
      );
      expect(
        doc.jsonpath(r"$.store.bicycle['colour','price']").collect(.count()),
        equals(2),
      );
    });

    test('filters: existence, comparison and regex', () {
      expect(
        doc
            .jsonpath(r'$.store.book[?(@.isbn)]')
            .transform(.map.nonnull((b) => b.text('title')))
            .collect(.list()),
        equals(['Moby Dick']),
      );
      expect(
        doc
            .jsonpath(r'$.store.book[?(@.price < 10)]')
            .transform(.map.nonnull((b) => b.text('title')))
            .collect(.list()),
        equals(['Sayings', 'Moby Dick']),
      );
      expect(
        doc
            .jsonpath(r'$.store.book[?(@.author == "Evelyn Waugh")]')
            .collect(.count()),
        equals(1),
      );
      expect(
        doc
            .jsonpath(r'$.store.book[?(@.author != "Evelyn Waugh")]')
            .collect(.count()),
        equals(2),
      );
      expect(
        doc
            .jsonpath(r'$.store.book[?(@.title =~ /^Mob/)]')
            .transform(.map.nonnull((b) => b.text('title')))
            .collect(.list()),
        equals(['Moby Dick']),
      );
    });

    test('an expression it cannot read selects nothing', () {
      expect(doc.jsonpath(r'$.store.book[').collect(.empty()), isTrue);
      expect(doc.jsonpath(r'$[?(broken)]').collect(.empty()), isTrue);
      expect(doc.jsonpath(r'$.store.book[a:b:c]').collect(.empty()), isTrue);
      expect(
        doc.jsonpath('').collect(.count()),
        equals(1),
        reason: 'the root itself',
      );
    });

    test('the same expression is only parsed once', () {
      const query = r'$..price';
      expect(
        doc.jsonpath(query).collect(.count()),
        equals(doc.jsonpath(query).collect(.count())),
      );
    });
  });

  group('the three doors', () {
    test('a response, a string and a file give the same cursor', () async {
      final res = Reply.text(
        '{"data":{"items":[{"sku":"a"},{"sku":"b"}]}}',
        fetch: Fetch('https://example.com'.url),
      );
      expect(res.parse(format.json).at('data.items').count, equals(2));
      expect(
        res
            .parse(format.json)
            .at('data.items')
            .all((i) => i.text('sku'))
            .collect(.list()),
        equals(['a', 'b']),
      );
      expect(res.parse(format.json).at('').raw, isA<Map<String, Object?>>());
      expect(
        Reply.text(
          '<html>',
          fetch: Fetch('https://example.com'.url),
        ).parse(format.json).at('a').empty,
        isTrue,
        reason: 'a body that is not JSON never throws here',
      );

      final dir = io.dir.temp('dt_json_door_');
      try {
        final path = io.path.join(dir.path, 'c.json');
        io.dump(path, {
          'hosts': ['a', 'b'],
        });
        expect(
          (await format.json.read(
            path,
          )).at('hosts').all((h) => h.text()).nonNull.collect(.list()),
          equals(['a', 'b']),
        );
        expect((await format.json.read(path)).count, equals(1));
      } finally {
        io.remove(dir.path);
      }
    });
  });
}

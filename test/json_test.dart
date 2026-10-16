import 'dart:io';
import 'dart:convert';

import 'package:dart_toolkit/json.dart';

import 'support/io.dart';
import 'package:test/test.dart';

void main() {
  test('texts() is every item\'s text, as Elements.texts() is every match\'s', () {
    final doc = Json.parse('{"a":[{"uri":"x"},{"uri":2},{"other":1},{"uri":null}],"one":"z"}');
    expect(doc.$('a.*.uri').texts(), ['x', '2']);
    expect(doc.$('**.uri').texts(), ['x', '2']);
    expect(doc.$('one').texts(), ['z']);
    expect(doc.$('missing').texts(), isEmpty);
  });

  test('value<DateTime>() reads ISO text and Unix seconds or milliseconds', () {
    final doc = Json.parse('{"iso":"2024-05-01T10:00:00Z","s":1714557600,"ms":1714557600000,"txt":"1714557600","no":"soon"}');
    final at = DateTime.utc(2024, 5, 1, 10);
    expect(doc.$('iso').value<DateTime>()!.isAtSameMomentAs(at), isTrue);
    expect(doc.$('s').value<DateTime>()!.isAtSameMomentAs(at), isTrue);
    expect(doc.$('ms').value<DateTime>()!.isAtSameMomentAs(at), isTrue);
    expect(doc.$('txt').or(DateTime(0)).isAtSameMomentAs(at), isTrue);
    expect(doc.$('no').value<DateTime>(), isNull);
    expect(Json.parse('{"id":1700000000000000000000}').$('id').value<DateTime>(), isNull, reason: 'past DateTime: not a time');
    expect(Json.parse('["99999999999999999999"]').asList<DateTime>(), isEmpty);
    expect(Json.parse('[1714557600, 1714557600000]').asList<DateTime>(), hasLength(2));
    // B25: microsecond and nanosecond epochs (they read as ms: year 57742).
    expect(Json.parse('1714557600000000').value<DateTime>()!.isAtSameMomentAs(at), isTrue);
    expect(Json.parse('"1714557600000000000"').value<DateTime>()!.isAtSameMomentAs(at), isTrue);
  });

  deepPathTests();
  valueTests();
  group('Json.parse', () {
    test('parses values', () {
      expect(Json.parse('{"a": 1}').$('a').value<int>(), 1);
    });

    test('invalid JSON is a FormatException', () {
      expect(() => Json.parse('{oops'), throwsFormatException);
      expect(() => Json.parse(''), throwsFormatException);
    });

    test('S8: past 1,000 levels a document is a ContentException, so toString never overflows', () async {
      String nested(int n) => '${'[{"a":' * n}1${'}]' * n}';
      expect(Json.parse(nested(500)).toString(), nested(500));
      final deep = ['${'[' * 1001}${']' * 1001}', nested(600), '"${'[' * 5000}"'];
      expect(() => Json.parse(deep[0]), throwsA(isA<ContentException>()));
      expect(() => Json.parse(deep[1]), throwsA(isA<ContentException>()));
      expect(Json.parse(deep[2]).value<String>(), hasLength(5000)); // brackets in a string are text
      await expectLater(Mem(deep[0]).json(), throwsA(isA<ContentException>()));
      await expectLater(Mem('1\n${deep[1]}\n').ndjson().toList(), throwsA(isA<ContentException>()));
    });
  });

  group('Json.encode', () {
    test('renders compact by default', () {
      expect(
        Json.encode({
          'a': [1, 2],
        }),
        '{"a":[1,2]}',
      );
    });

    test('pretty indents by two spaces', () {
      expect(Json.encode({'a': 1}, pretty: true), '{\n  "a": 1\n}');
    });

    test('E14: any Iterable (a Set, a map(...)) encodes as a list', () {
      expect(Json.encode({'s': {1, 2}, 'm': [1, 2].map((i) => i * 10), 'j': Json.of({'t': {'x'}})}), '{"s":[1,2],"m":[10,20],"j":{"t":["x"]}}');
      expect(Json.encode({'a': {3}}, pretty: true), '{\n  "a": [\n    3\n  ]\n}');
      expect(Json.encode(_Point()), '{"x":1}');
      expect(() => Json.encode(Object()), throwsA(isA<JsonUnsupportedObjectError>()));
    });
  });

  group('Json', () {
    final doc = Json.parse('{"server": {"port": 8080}, "users": [{"name": "a"}, {"name": "b"}]}');

    test(r'$() follows dotted paths, numeric indexes arrays', () {
      expect(doc.$('server.port').value<int>(), 8080);
      expect(doc.$('users.0.name').value<String>(), 'a');
      expect(doc.$('users.1.name').value<String>(), 'b');
    });

    test('a missing path holds null, never throws', () {
      expect(doc.$('server.missing').value<int>(), isNull);
      expect(doc.$('users.9.name').value<String>(), isNull);
      expect(doc.$('server.port.x').value<int>(), isNull);
    });

    test('iterates array items or object values; scalar iterates nothing', () {
      expect(doc.$('users').map((u) => u.$('name').value<String>()), ['a', 'b']);
      expect(doc.$('server').map((v) => v.value<int>()), [8080]);
      expect(doc.$('server.port'), isEmpty);
      expect(doc.$('missing'), isEmpty);
    });

    test('[] indexes the iteration, RangeError when out of range', () {
      expect(doc.$('users')[0].$('name').value<String>(), 'a');
      expect(() => doc.$('users')[5], throwsRangeError);
    });

    test('value<T>() is null when absent or mistyped', () async {
      expect(doc.$('server.port').value<String>(), isNull);
      expect(doc.$('server.port').value<num>(), 8080);
      expect(doc.$('server.port').value<Object>(), 8080);
      expect(doc.$('missing').or(8080), 8080);
      expect(doc.$('server.port').or(1), 8080);
      expect(doc.$('server.port').or('x'), '8080', reason: 'a String fallback reads numbers as text');
      expect(await Future.value(doc.$('missing')).or(7), 7);
      expect(doc.$('missing').asList<int>(), isEmpty);
      expect(doc.$('missing').asMap<int>(), isEmpty);
    });
  });

  group('Reader.json', () {
    test('reads a value', () async {
      expect(await Mem('{"a": 1}').json().$('a').value<int>(), 1);
    });

    test('invalid JSON is a FormatException', () {
      expect(Mem('{nope').json(), throwsFormatException);
    });

    test('mirror on Future<Reader>', () async {
      expect(await Future<Reader>.value(Mem('[1,2]')).json().$('1').value<int>(), 2);
    });
  });

  group('Future mirrors', () {
    test('match their members', () async {
      final f = Future.value(Json.parse('{"a": {"b": 1}}'));
      expect((await f.$('a')).$('b').value<int>(), 1);
      expect(await f.$('a.b').value<int>(), 1);
      expect(await Future.value(Json.parse('[1,2]')).asList<int>(), [1, 2]);
      expect(await Future.value(Json.parse('{"a":1}')).asMap<int>(), {'a': 1});
    });
  });

  group('number coercion (§2)', () {
    test('integral numbers read as int and double', () {
      expect(Json.parse('3.0').value<int>(), 3);
      expect(Json.parse('3').value<double>(), 3.0);
      expect(Json.parse('3').value<int>(), 3);
      expect(Json.parse('3.0').value<double>(), 3.0);
    });

    test('non-integral doubles are not ints', () {
      expect(Json.parse('3.5').value<int>(), isNull);
      expect(Json.parse('3.5').value<double>(), 3.5);
    });

    test('a double at 2^63 or beyond is not an int', () {
      expect(Json.parse('9223372036854775808.0').value<int>(), isNull);
      expect(Json.parse('-9223372036854775808.0').value<int>(), -9223372036854775808);
    });
  });

  group('typed lists and maps (V13)', () {
    test('asList<T> checks every element', () {
      expect(Json.parse('[1,2,3]').asList<int>(), [1, 2, 3]);
      // One mismatch nulls the whole read.
      expect(Json.parse('[1,"a"]').asList<int>(), isEmpty);
      expect(Json.parse('[]').asList<int>(), isEmpty);
    });

    test('elements coerce like scalars', () {
      expect(Json.parse('[1,2]').asList<double>(), [1.0, 2.0]);
      expect(Json.parse('[1.0,2.0]').asList<int>(), [1, 2]);
      expect(Json.parse('[1.5]').asList<int>(), isEmpty);
      expect(Json.parse('["a",null]').asList<String?>(), ['a', null]);
      expect(Json.parse('["a",null]').asList<String>(), isEmpty);
    });

    test('asMap<T> checks every value', () {
      expect(Json.parse('{"a":1}').asMap<int>(), {'a': 1});
      expect(Json.parse('{"a":"x"}').asMap<int>(), isEmpty);
      expect(Json.parse('{"a":1}').asMap<double>(), {'a': 1.0});
    });

    test('asList reads REST shapes in one pass', () {
      expect(Json.parse('[{"a":1},{"b":2}]').asList<Map<String, Object?>>(), isNotNull);
      expect(Json.parse('[{"a":1},{"b":2}]').asList<Map<String, dynamic>>(), isNotNull);
      // value<List<...>> is not the typed read; every build mode says so
      // (regression: debug asserted, release returned null).
      expect(() => Json.parse('[1,2]').value<List<int>>(), throwsArgumentError);
      expect(() => Json.parse('{"a":1}').value<Map<String, int>>(), throwsArgumentError);
      expect(Json.parse('{"a":1}').value<Map<String, dynamic>>(), {'a': 1});
      expect(Json.parse('[1]').value<List<dynamic>>(), [1]);
    });

    test('Json.of wraps a held value', () {
      expect(
        Json.of({
          'a': [1, 2],
        }).$('a').asList<int>(),
        [1, 2],
      );
      expect(Json.of([1, 2]).asList<int>(), [1, 2]);
    });

    test('nested reads go through iteration (records)', () {
      final doc = Json.parse('{"users": [{"name": "a", "age": 1}, {"name": "b", "age": 2}]}');
      final users = [for (final u in doc.$('users')) (name: u.$('name').or(''), age: u.$('age').or(0))];
      expect(users, [(name: 'a', age: 1), (name: 'b', age: 2)]);
    });
  });

  group('star paths (V14)', () {
    final doc = Json.parse('{"data":{"users":[{"name":"a"},{"name":"b"},{"x":1}]}}');

    test('* maps over items, missing keys are null entries', () {
      expect(doc.$('data.users.*.name').asList<String?>(), ['a', 'b', null]);
      expect(doc.$('data.users.*.name').asList<String>(), isEmpty);
    });

    test('* as the last segment collects the items', () {
      final users = doc.$('data.users.*');
      expect(users.length, 3);
      expect(users[0].$('name').value<String>(), 'a');
      expect(users[2].$('name').value<String>(), isNull);
    });

    test('* over an object maps over values in iteration order', () {
      final m = Json.parse('{"a":{"x":1},"b":{"x":2}}');
      expect(m.$('*.x').asList<int>(), [1, 2]);
    });

    test('* over a scalar or missing path holds null', () {
      expect(doc.$('data.users.0.name.*').value<Object>(), isNull);
      expect(doc.$('missing.*.name').value<Object>(), isNull);
    });
  });

  group('lazy wrapping (F15)', () {
    test('[] is O(1) and throws RangeError off the iteration', () {
      final doc = Json.parse('{"a":[10,20]}');
      expect(doc.$('a')[1].value<int>(), 20);
      expect(() => doc.$('a')[2], throwsRangeError);
      expect(() => Json.parse('3')[0], throwsRangeError);
    });

    test('encode reads Json values as their raw value', () {
      expect(Json.encode({'a': Json.parse('[1,{"b":2}]')}), '{"a":[1,{"b":2}]}');
      expect(Json.encode(Json.parse('{"a":1}')), '{"a":1}');
    });

    test('encode throws what dart:convert throws', () {
      Type? dartType;
      try {
        jsonEncode({1: 2});
      } on Object catch (e) {
        dartType = e.runtimeType;
      }
      expect(dartType, isNotNull);
      expect(() => Json.encode({1: 2}), throwsA(predicate((e) => e.runtimeType == dartType)));
    });

    test('indexed loops stay linear', () {
      final doc = Json.parse('[${List.filled(10000, '1').join(',')}]');
      final sw = Stopwatch()..start();
      var sum = 0;
      for (var i = 0; i < doc.length; i++) {
        sum += doc[i].value<int>()!;
      }
      expect(sum, 10000);
      // Rebuilding the list per access would be quadratic (~10⁸ wraps).
      expect(sw.elapsedMilliseconds, lessThan(3000));
    });
  });
  test('a value deeper than the call stack still queries, compares and hashes', () {
    // Json.parse refuses text this deep (S8); a held value may be.
    final deep = '${'[' * 100000}{"x": 1}${']' * 100000}';
    final a = Json.of(jsonDecode(deep)), b = Json.of(jsonDecode(deep));
    expect(a.$('**.x').asList<int>(), [1]);
    expect(a == b, isTrue);
    expect(a.hashCode, b.hashCode);
    expect(a == Json.of(jsonDecode(deep.replaceFirst('1', '2'))), isFalse);
  });
}

void deepPathTests() {
  test('E5: scalar reads on a * or ** result take the first hit that reads', () {
    final doc = Json.parse('{"a": {"y": {"z": 1}}, "b": {"y": "two", "t": 1700000000}, "c": [{"n": 3}, {"n": 4}]}');
    expect(doc.$('**.y').text(), 'two'); // the object hit has no text
    expect(doc.$('**.y').or(''), 'two');
    expect(doc.$('c.*.n').value<int>(), 3);
    expect(doc.$('c.*.n').or(0), 3);
    expect(doc.$('**.t').value<DateTime>(), DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(doc.$('**.nope').text(), isNull);
    expect(doc.$('**.nope').or(7), 7);
    expect(doc.$('c.*.n').texts(), ['3', '4']);
    expect(doc.$('c.*.n').value<List<Object?>>(), [3, 4]); // the raw shape is still the list
    expect(doc.$('c').text(), isNull); // a plain array is not a hit list
  });

  group('json **', () {
    final doc = Json.of({
      'pk': 1,
      'a': [
        {'pk': 2},
        {
          'b': {'pk': 3, 'x': null},
        },
      ],
      '*': 'star',
    });

    test('collects a key at every depth, in document order', () {
      expect(doc.$('**.pk').asList<int>(), [1, 2, 3]);
      expect(doc.$('a.**.pk').asList<int>(), [2, 3]);
      expect(doc.$('**.missing').asList<Object>(), isEmpty);
    });

    test('a Json inside Json.of reads as its value (regression: paths stopped at it)', () {
      final outer = Json.of([
        Json.parse('{"k": {"pk": 7}}'),
        Json.of({'pk': 8}),
      ]);
      expect(outer.$('**.pk').asList<int>(), [7, 8]);
      expect(outer.$('0.k.pk').value<int>(), 7);
      expect(Json.of(Json.of(3)).value<int>(), 3);
    });

    test(r'\* stays a literal key (regression: it read as a wildcard)', () {
      expect(doc.$(r'\*').value<String>(), 'star');
      expect(Json.of({'**': 1}).$(r'\*\*').value<int>(), 1);
    });
  });
}

void valueTests() {
  group('Json as a value', () {
    test('toString is the JSON text (regression: printed "(())")', () {
      expect(Json.parse('{"a": [1, "x", null]}').toString(), '{"a":[1,"x",null]}');
      expect('${Json.parse('3')}', '3');
      expect(Json.of(null).toString(), 'null');
    });

    test('== and hashCode are deep (regression: identity)', () {
      final a = Json.parse('{"a": [1, {"b": 2}], "c": "x"}');
      final b = Json.parse('{"c": "x", "a": [1.0, {"b": 2}]}');
      // `==` directly: the matchers compare Iterables element by element.
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
      expect(a == Json.parse('{"a": [1, {"b": 3}], "c": "x"}'), isFalse);
      expect(Json.parse('[1,2]') == Json.parse('[2,1]'), isFalse);
      expect(Json.parse('{"a": 1}') == Json.parse('{"b": 1}'), isFalse);
      expect({a, b}, hasLength(1));
      expect(a.$('a.1') == Json.of({'b': 2}), isTrue);
    });

    test('a plain key reads like the path (fast path)', () {
      final doc = Json.parse('{"name": "n", "nil": null, "list": [5, 6], "a*b": 1}');
      expect(doc.$('name').value<String>(), 'n');
      expect(doc.$('nil').value<Object>(), isNull);
      expect(doc.$('missing').value<Object>(), isNull);
      expect(doc.$('a*b').value<int>(), 1);
      expect(doc.$('list').$('1').value<int>(), 6);
      expect(doc.$('list').$('01').value<int>(), isNull);
      expect(doc.$('list').$('9').value<int>(), isNull);
      expect(Json.parse('3').$('x').value<Object>(), isNull);
    });

    test('json() names the source and status once (regression: no URL, wrapped twice)', () async {
      final e = await _Page(
        '<html>oops</html>',
        const Origin(url: 'https://u:p@x.com/api?token=T', status: 503),
      ).json().then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<ContentException>());
      final c = e as ContentException;
      expect(c.message, startsWith('invalid JSON from https://x.com/api?token=*** (HTTP 503): '));
      expect(c.cause, isNot(isA<ContentException>()));
      final ok = await _Page(
        '<html>',
        const Origin(url: 'https://x.com/', status: 200),
      ).json().then<Object?>((_) => null, onError: (Object e) => e);
      expect((ok as ContentException).message, contains('https://x.com/ (HTTP 200)'));
    });
  });

  group('alternatives, text, extremes', () {
    final doc = Json.parse(
      '{"a":{"shortcode":"S","pk":787132},"v":[{"w":3,"u":"x"},{"config_width":9,"src":"y"},{"w":9,"u":"z"}],"t":true}',
    );

    test('| separates whole paths, tried in order (regression: bound tighter than .)', () {
      expect(doc.$('a.code|a.shortcode').text(), 'S');
      expect(doc.$('a').$('pk|id').text(), '787132');
      expect(doc.$('nope|a.shortcode').text(), 'S');
      expect(doc.$('a.code|nope').text(), isNull);
      expect(Json.parse(r'{"a|b":1}').$(r'a\|b').value<int>(), 1);
      // twitter's tweet id: rest_id first, then legacy.id_str (read 7, expected 9)
      final tweet = Json.parse('{"rest_id":"9","legacy":{"id_str":"7"}}');
      expect(tweet.$('rest_id|legacy.id_str').text(), '9');
      expect(Json.parse('{"legacy":{"id_str":"7"}}').$('rest_id|legacy.id_str').text(), '7');
    });

    test('a wildcard alternative that matches nothing falls through (regression: [] won)', () {
      final page = Json.parse('[{"x":{"profilePhoto":{"url":"p"}}}]');
      expect(page.$('**.profilePicLarge.uri|**.profilePhoto.url').asList<String>(), ['p']);
      expect(page.$('**.nope').length, 0, reason: 'a lone wildcard miss is still an empty list');
      expect(page.$('**.nope|**.none').length, 0);
    });

    test('nested wildcards flatten (regression: [[1,2],[3]])', () {
      final x = Json.parse('{"x":[{"a":[{"b":1},{"b":2}]},{"a":[{"b":3}]},{"c":0}]}');
      expect(x.$('x.*.a.*.b').asList<int>(), [1, 2, 3]);
      expect(x.$('**.a.*.b').asList<int>(), [1, 2, 3]);
      expect(x.$('x.*.a').length, 3, reason: 'a single * still maps, missing keys stay null');
    });

    test('a negative index counts from the end', () {
      final items = Json.parse('{"items":[1,2,3],"m":{"-1":"k"}}');
      expect(items.$('items.-1').value<int>(), 3);
      expect(items.$('items.-3').value<int>(), 1);
      expect(items.$('items.-4').value<Object>(), isNull);
      expect(items.$('items.-0').value<Object>(), isNull);
      expect(items.$('items').$('-2').value<int>(), 2);
      expect(items.$('m.-1').text(), 'k');
    });

    test('asList<Json>/asMap<Json> wrap their values', () {
      final j = Json.parse('{"posts":{"p1":["a","b"],"p2":[]},"l":[{"k":1},2]}');
      final posts = j.$('posts').asMap<Json>();
      expect(posts.keys, ['p1', 'p2']);
      expect(posts['p1']!.asList<String>(), ['a', 'b']);
      expect(j.$('l').asList<Json>().map((e) => e.$('k').or(0)), [1, 0]);
      expect(j.$('l').asList<Object>().first, isA<Map<String, dynamic>>());
    });

    test('or with a String fallback reads numbers as text, like text()', () {
      expect(doc.$('a.pk').or(''), '787132');
      expect(doc.$('t').or(''), 'true');
      expect(doc.$('a').or('-'), '-');
      expect(doc.$('a.pk').or(0), 787132);
    });

    test('text() reads any scalar, null for collections and misses', () {
      expect(
        [doc.$('a.pk').text(), doc.$('t').text(), doc.$('a').text(), doc.$('zz').text()],
        ['787132', 'true', null, null],
      );
      expect(Json.parse('1.5').text(), '1.5');
    });

    test('max returns the largest item, the first on a tie, null when empty', () {
      expect(doc.$('v').max((c) => c.$('w|config_width').or(0)).$('u|src').text(), 'y');
      expect(doc.$('v').max((c) => -c.$('w|config_width').or(0)).$('u').text(), 'x');
      expect(Json.parse('[]').max((c) => 1).value<Object>(), isNull);
    });

    test('ndjson() streams one Json per non-blank line, naming a bad line', () async {
      final rows = await _Page('{"a":1}\n\n{"a":2}\r\n', const Origin()).ndjson().toList();
      expect(rows.map((r) => r.$('a').or(0)), [1, 2]);
      await expectLater(
        _Page('{"a":1}\n{oops', const Origin(path: 'log.ndjson')).ndjson().toList(),
        throwsA(
          isA<ContentException>().having(
            (e) => e.message,
            'message',
            startsWith('invalid JSON from log.ndjson at line 2'),
          ),
        ),
      );
      expect(await Future<Reader>.value(_Page('1\n2', const Origin())).ndjson().length, 2);
    });

    test('json() decodes UTF-8 bytes straight to a value, malformed bytes replaced', () async {
      expect((await Reader.of([0xEF, 0xBB, 0xBF, ...utf8.encode('{"a":"ü"}')]).json()).$('a').text(), 'ü');
      expect((await Reader.of([0x22, 0xFF, 0x22]).json()).text(), '\uFFFD');
    });

    test('json(or:) answers a missing file, other failures still throw', () async {
      expect((await _Missing().json(or: Json.of({'k': 1}))).$('k').value<int>(), 1);
      await expectLater(_Missing().json(), throwsA(isA<PathNotFoundException>()));
      await expectLater(_Page('{', const Origin()).json(or: Json.of(1)), throwsA(isA<ContentException>()));
    });
  });
}

final class _Missing with Reader {
  @override
  Stream<List<int>> stream() => throw const PathNotFoundException('gone', OSError('no such file', 2));
}

final class _Page with Reader {
  _Page(this._text, this._origin);
  final String _text;
  final Origin _origin;
  @override
  Origin origin() => _origin;
  @override
  Stream<List<int>> stream() => Stream.value(_text.codeUnits);
}

final class _Point {
  Map<String, Object?> toJson() => {'x': 1};
}

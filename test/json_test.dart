import 'dart:io';
import 'dart:convert';

import 'package:dart_toolkit/json.dart';
import 'package:test/test.dart';

void main() {
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
      expect(doc.$('server.port').or('x'), 'x');
      expect(await Future.value(doc.$('missing')).or(7), 7);
      expect(doc.$('missing').asList<int>(), isEmpty);
      expect(doc.$('missing').asMap<int>(), isEmpty);
    });
  });

  group('Reader.json', () {
    test('reads a value', () async {
      expect(await _Mem('{"a": 1}').json().$('a').value<int>(), 1);
    });

    test('invalid JSON is a FormatException', () {
      expect(_Mem('{nope').json(), throwsFormatException);
    });

    test('mirror on Future<Reader>', () async {
      expect(await Future<Reader>.value(_Mem('[1,2]')).json().$('1').value<int>(), 2);
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
  test('a document deeper than the call stack still queries, compares and hashes', () {
    final deep = '${'[' * 100000}{"x": 1}${']' * 100000}';
    final a = Json.parse(deep), b = Json.parse(deep);
    expect(a.$('**.x').asList<int>(), [1]);
    expect(a == b, isTrue);
    expect(a.hashCode, b.hashCode);
    expect(a == Json.parse(deep.replaceFirst('1', '2')), isFalse);
  });
}

final class _Mem with Reader {
  _Mem(this._text);
  final String _text;
  @override
  Stream<List<int>> stream() => Stream.value(_text.codeUnits);
}

void deepPathTests() {
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

    test('a | segment tries alternatives in order, with the rest of the path', () {
      expect(doc.$('a.code|shortcode').text(), 'S');
      expect(doc.$('a.pk|id').text(), '787132');
      expect(doc.$('nope|a.shortcode').text(), 'S', reason: 'alternatives are keys of one segment');
      expect(doc.$('a.code|nope').text(), isNull);
      expect(Json.parse(r'{"a|b":1}').$(r'a\|b').value<int>(), 1);
    });

    test('text() reads any scalar, null for collections and misses', () {
      expect(
        [doc.$('a.pk').text(), doc.$('t').text(), doc.$('a').text(), doc.$('zz').text()],
        ['787132', 'true', null, null],
      );
      expect(Json.parse('1.5').text(), '1.5');
    });

    test('max/min return the extreme item, the first on a tie, null when empty', () {
      expect(doc.$('v').max((c) => c.$('w|config_width').or(0)).$('u|src').text(), 'y');
      expect(doc.$('v').min((c) => c.$('w|config_width').or(0)).$('u').text(), 'x');
      expect(Json.parse('[]').max((c) => 1).value<Object>(), isNull);
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

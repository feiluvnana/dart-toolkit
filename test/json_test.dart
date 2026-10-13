import 'dart:convert';

import 'package:dart_toolkit/json.dart';
import 'package:test/test.dart';

void main() {
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
      expect(Json.encode({'a': [1, 2]}), '{"a":[1,2]}');
    });

    test('pretty indents by two spaces', () {
      expect(Json.encode({'a': 1}, pretty: true), '{\n  "a": 1\n}');
    });
  });

  group('Json', () {
    final doc = Json.parse(
      '{"server": {"port": 8080}, "users": [{"name": "a"}, {"name": "b"}]}',
    );

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

    test('value<T>() is null when absent or mistyped', () {
      expect(doc.$('server.port').value<String>(), isNull);
      expect(doc.$('server.port').value<num>(), 8080);
      expect(doc.$('server.port').value<Object>(), 8080);
      expect(doc.$('missing').value<int>() ?? 8080, 8080);
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
      expect(
        await Future<Reader>.value(_Mem('[1,2]')).json().$('1').value<int>(),
        2,
      );
    });
  });

  group('Future mirrors', () {
    test('match their members', () async {
      final f = Future.value(Json.parse('{"a": {"b": 1}}'));
      expect((await f.$('a')).$('b').value<int>(), 1);
      expect(await f.$('a.b').value<int>(), 1);
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
  });

  group('typed lists and maps (V13)', () {
    test('value<List<T>> checks every element', () {
      expect(Json.parse('[1,2,3]').value<List<int>>(), [1, 2, 3]);
      // One mismatch nulls the whole read.
      expect(Json.parse('[1,"a"]').value<List<int>>(), isNull);
      expect(Json.parse('[]').value<List<int>>(), isEmpty);
    });

    test('elements coerce like scalars', () {
      expect(Json.parse('[1,2]').value<List<double>>(), [1.0, 2.0]);
      expect(Json.parse('[1.0,2.0]').value<List<int>>(), [1, 2]);
      expect(Json.parse('[1.5]').value<List<int>>(), isNull);
      expect(Json.parse('["a",null]').value<List<String?>>(), ['a', null]);
      expect(Json.parse('["a",null]').value<List<String>>(), isNull);
    });

    test('value<Map<String,T>> checks every value', () {
      expect(Json.parse('{"a":1}').value<Map<String,int>>(), {'a': 1});
      expect(Json.parse('{"a":"x"}').value<Map<String,int>>(), isNull);
      expect(Json.parse('{"a":1}').value<Map<String,double>>(), {'a': 1.0});
    });
  });

  group('star paths (V14)', () {
    final doc = Json.parse(
      '{"data":{"users":[{"name":"a"},{"name":"b"},{"x":1}]}}',
    );

    test('* maps over items, missing keys are null entries', () {
      expect(
        doc.$('data.users.*.name').value<List<String?>>(),
        ['a', 'b', null],
      );
      expect(doc.$('data.users.*.name').value<List<String>>(), isNull);
    });

    test('* as the last segment collects the items', () {
      final users = doc.$('data.users.*');
      expect(users.length, 3);
      expect(users[0].$('name').value<String>(), 'a');
      expect(users[2].$('name').value<String>(), isNull);
    });

    test('* over an object maps over values in iteration order', () {
      final m = Json.parse('{"a":{"x":1},"b":{"x":2}}');
      expect(m.$('*.x').value<List<int>>(), [1, 2]);
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
      expect(
        () => Json.encode({1: 2}),
        throwsA(predicate((e) => e.runtimeType == dartType)),
      );
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
}

final class _Mem with Reader {
  _Mem(this._text);
  final String _text;
  @override
  Stream<List<int>> stream() => Stream.value(_text.codeUnits);
}

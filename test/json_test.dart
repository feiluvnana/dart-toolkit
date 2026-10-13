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
}

final class _Mem with Reader {
  _Mem(this._text);
  final String _text;
  @override
  Stream<List<int>> stream() => Stream.value(_text.codeUnits);
}

import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/path.dart';
import 'package:test/test.dart';

void main() {
  group('json values', () {
    test('get walks a dotted path with a type', () {
      final j = Json.parse('{"a":{"b":[1,2]}}');
      expect(j.get<int>('a.b.1'), 2);
    });

    test('get answers or: on a miss, else throws MissingException', () {
      final j = Json.parse('{"a":{"b":[1,2]}}');
      expect(j.get<int>('a.x', or: 7), 7);
      expect(() => j.get<int>('a.x'), throwsA(isA<MissingException>()));
      expect(() => j.get<int>('a.b.5'), throwsA(isA<MissingException>()));
      expect(() => j.get<String>('a.b.1'), throwsFormatException);
    });

    test('one step per []: a key, then an index', () {
      final j = Json.parse('{"a":{"b":[1,2]}}');
      expect(j['a']['b'][0].value, 1);
    });

    test('the value is immutable', () {
      final j = Json.parse('{"a":{"b":[1,2]}}');
      expect(() => (j.value as Map)['a'] = 1, throwsUnsupportedError);
      expect(() => ((j.value as Map)['a'] as Map)['b'] = 1, throwsUnsupportedError);
      expect(() => (((j.value as Map)['a'] as Map)['b'] as List)[0] = 9, throwsUnsupportedError);
    });

    test('encode writes compact JSON', () {
      expect(Json({'ok': true}).encode(), '{"ok":true}');
      expect(Json.parse('{"a":1}'), Json({'a': 1}));
    });

    test('save then json() round-trips, atomically', () async {
      final dir = await Dir.temp();
      try {
        final file = dir.file('a.json');
        final j = Json.parse('{"a":{"b":[1,2]}}');
        await j.save(file);
        expect(await file.json(), j);
        expect((await dir.files()).map((f) => f.name), ['a.json']); // no temp left behind
      } finally {
        await dir.drop();
      }
    });

    test('equal maps hash equal whatever their key order', () {
      final a = Json.parse('{"a":1,"b":2}');
      final b = Json.parse('{"b":2,"a":1}');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}.length, 1);
    });
  });

  group('typed reads', () {
    final j = Json.parse(r'{"price": 10, "ratio": 0.5, "half": 2.5, "name": "x", "a.b": 1, "gone": null}');

    test('numbers convert between int and double; fractions never become int', () {
      expect(j.get<double>('price'), 10.0);
      expect(j.get<int>('price'), 10);
      expect(() => j.get<int>('half'), throwsFormatException);
    });

    test('a wrong type names the path and both types', () {
      expect(
        () => j.get<int>('name'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', 'name is a string, not int')),
      );
    });

    test('or: covers a missing value only, and a nullable type reads null', () {
      expect(j.get<int>('nope', or: 3), 3);
      expect(j.get<int?>('nope'), isNull);
      expect(j.get<int?>('gone'), isNull);
      expect(() => j.get<int>('nope'), throwsA(isA<MissingException>()));
    });

    test("'' is the root and \\. is a dot inside a key", () {
      expect(j.get<Map<String, Object?>>('')['price'], 10);
      expect(j.get<int>(r'a\.b'), 1);
    });

    test('Json(value) refuses what JSON cannot hold', () {
      expect(() => Json({1: 'a'}), throwsArgumentError);
      expect(() => Json([DateTime(2026)]), throwsArgumentError);
      expect(() => Json(double.nan), throwsArgumentError);
      expect(Json({'ok': true}).encode(), '{"ok":true}');
    });
  });
}

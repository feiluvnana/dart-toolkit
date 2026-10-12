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
      expect(() => j.get<String>('a.b.1'), throwsA(isA<MissingException>()));
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
  });
}

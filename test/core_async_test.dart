import 'dart:async';

import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

void main() {
  group('Core Either', () {
    test('Left and Right properties and pattern matching', () {
      final Either<String, int> right = Right(42);
      final Either<String, int> left = Left('error');

      expect(right.isRight, isTrue);
      expect(right.isLeft, isFalse);
      expect(right.rightOrNull, equals(42));
      expect(right.leftOrNull, isNull);

      expect(left.isLeft, isTrue);
      expect(left.isRight, isFalse);
      expect(left.leftOrNull, equals('error'));
      expect(left.rightOrNull, isNull);

      // fold
      expect(right.fold((l) => 'L: $l', (r) => 'R: $r'), equals('R: 42'));
      expect(left.fold((l) => 'L: $l', (r) => 'R: $r'), equals('L: error'));

      // map
      final mappedRight = right.map((r) => r * 2);
      expect(mappedRight, equals(const Right<String, int>(84)));

      final mappedLeft = left.map((r) => r * 2);
      expect(mappedLeft, equals(const Left<String, int>('error')));

      // mapLeft
      final leftMapped = left.mapLeft((l) => l.toUpperCase());
      expect(leftMapped, equals(const Left<String, int>('ERROR')));
    });

    test('Either.guard and Either.guardAsync', () async {
      final syncSuccess = Either.guard(() => 10 + 5);
      expect(syncSuccess, equals(const Right<Object, int>(15)));

      final syncFailure = Either.guard<int>(() => throw FormatException('bad'));
      expect(syncFailure.isLeft, isTrue);
      expect(syncFailure.leftOrNull, isA<FormatException>());

      final asyncSuccess = await Either.guardAsync(() async => 'hello');
      expect(asyncSuccess, equals(const Right<Object, String>('hello')));

      final asyncFailure = await Either.guardAsync<String>(() async => throw StateError('failed'));
      expect(asyncFailure.isLeft, isTrue);
      expect(asyncFailure.leftOrNull, isA<StateError>());
    });
  });

  group('Async parallelize on Iterable', () {
    test('preserves input order and isolates errors into Left', () async {
      final items = [1, 2, 3, 4, 5];

      final results = await items.parallelize((item) async {
        if (item == 3) {
          throw Exception('item 3 failed');
        }
        await Future<void>.delayed(Duration(milliseconds: (6 - item) * 10));
        return 'res-$item';
      }, concurrency: 3);

      expect(results.length, equals(5));
      expect(results[0], equals(const Right<Object, String>('res-1')));
      expect(results[1], equals(const Right<Object, String>('res-2')));
      expect(results[2].isLeft, isTrue);
      expect((results[2].leftOrNull as Exception).toString(), contains('item 3 failed'));
      expect(results[3], equals(const Right<Object, String>('res-4')));
      expect(results[4], equals(const Right<Object, String>('res-5')));
    });

    test('respects concurrency limit', () async {
      final items = List.generate(10, (i) => i);
      var maxInFlight = 0;
      var currentInFlight = 0;

      await items.parallelize((item) async {
        currentInFlight++;
        if (currentInFlight > maxInFlight) maxInFlight = currentInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        currentInFlight--;
        return item;
      }, concurrency: 3);

      expect(maxInFlight, lessThanOrEqualTo(3));
    });
  });

  group('Async parallelize on Stream', () {
    test('emits outcomes concurrently as they complete', () async {
      final stream = Stream.fromIterable([1, 2, 3]);

      final results = await stream.parallelize((item) async {
        if (item == 2) throw Exception('fail 2');
        await Future<void>.delayed(Duration(milliseconds: (4 - item) * 10));
        return item * 10;
      }, concurrency: 2).toList();

      expect(results.length, equals(3));
      // item 3 finishes first, item 2 fails, item 1 finishes last
      final rightValues = results.where((e) => e.isRight).map((e) => e.rightOrNull).toList();
      expect(rightValues, containsAll([10, 30]));

      final leftValues = results.where((e) => e.isLeft).toList();
      expect(leftValues.length, equals(1));
    });
  });
}

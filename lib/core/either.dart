import 'dart:async';

Object _throwable(Object? value) => value ?? StateError('Unwrapped a Left holding null');

/// A type-safe disjoint union representing either a failure [Left] or a success [Right].
///
/// {@category Formats}
sealed class Either<L, R> {
  const Either();

  /// Whether this instance is a [Left].
  bool get isLeft => this is Left<L, R>;

  /// Whether this instance is a [Right].
  bool get isRight => this is Right<L, R>;

  /// The left value if this is a [Left], or `null` otherwise.
  L? get leftOrNull => switch (this) {
    Left<L, R>(:final value) => value,
    Right<L, R>() => null,
  };

  /// The right value if this is a [Right], or `null` otherwise.
  R? get rightOrNull => switch (this) {
    Right<L, R>(:final value) => value,
    Left<L, R>() => null,
  };

  /// Unfolds the either into a single value of type [T].
  T fold<T>(T Function(L left) onLeft, T Function(R right) onRight) => switch (this) {
    Left<L, R>(:final value) => onLeft(value),
    Right<L, R>(:final value) => onRight(value),
  };

  /// Maps the success value if [Right], preserving [Left].
  Either<L, T> map<T>(T Function(R right) transform) => switch (this) {
    Right<L, R>(:final value) => Right(transform(value)),
    Left<L, R>(:final value) => Left(value),
  };

  /// Maps the left failure value if [Left], preserving [Right].
  Either<T, R> mapLeft<T>(T Function(L left) transform) => switch (this) {
    Left<L, R>(:final value) => Left(transform(value)),
    Right<L, R>(:final value) => Right(value),
  };

  /// Returns the [Right] value, or throws the [Left] value.
  ///
  /// Use when a failure at this point is genuinely exceptional; use [fold] or
  /// [rightOrNull] when it is not.
  R unwrap() => switch (this) {
    Right<L, R>(:final value) => value,
    Left<L, R>(:final value) => throw _throwable(value),
  };

  /// Runs a synchronous [action], capturing anything it throws as a [Left].
  ///
  /// Narrow the failure type afterwards with [mapLeft]:
  ///
  /// ```dart
  /// final outcome = Either.tryCatch(() => int.parse(raw)).mapLeft(ParseFailure.from);
  /// ```
  static Either<Object, T> tryCatch<T>(T Function() action) {
    try {
      return Right(action());
    } catch (error) {
      return Left(error);
    }
  }

  /// Runs an asynchronous [action], capturing anything it throws as a [Left].
  ///
  /// Accepts a synchronous or asynchronous closure; the result is always awaited.
  static Future<Either<Object, T>> tryCatchAsync<T>(FutureOr<T> Function() action) async {
    try {
      return Right(await action());
    } catch (error) {
      return Left(error);
    }
  }
}

/// The failure / left branch of [Either].
///
/// {@category Formats}
final class Left<L, R> extends Either<L, R> {
  /// The underlying left value.
  final L value;

  /// Creates a [Left] outcome.
  const Left(this.value);

  @override
  bool operator ==(Object other) => identical(this, other) || (other is Left && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Left($value)';
}

/// The success / right branch of [Either].
///
/// {@category Formats}
final class Right<L, R> extends Either<L, R> {
  /// The underlying right value.
  final R value;

  /// Creates a [Right] outcome.
  const Right(this.value);

  @override
  bool operator ==(Object other) => identical(this, other) || (other is Right && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Right($value)';
}

/// Collection helpers for iterables of [Either] outcomes.
///
/// {@category Formats}
extension IterableEitherExtensions<L, R> on Iterable<Either<L, R>> {
  /// Every [Right] value in order, throwing the first [Left] value encountered.
  List<R> unwrap() => [for (final outcome in this) outcome.unwrap()];

  /// Only the [Right] values, discarding failures.
  List<R> get rights => [
    for (final outcome in this)
      if (outcome case Right<L, R>(:final value)) value,
  ];

  /// Only the [Left] values.
  List<L> get lefts => [
    for (final outcome in this)
      if (outcome case Left<L, R>(:final value)) value,
  ];
}

/// Stream helpers for streams of [Either] outcomes.
///
/// {@category Formats}
extension StreamEitherExtensions<L, R> on Stream<Either<L, R>> {
  /// Emits every [Right] value, forwarding the first [Left] into the error channel.
  Stream<R> unwrap() => map((outcome) => outcome.unwrap());
}

import 'dart:async';

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

  /// Asynchronously evaluates [action], capturing any thrown error into a [Left].
  static Future<Either<Object, T>> guardAsync<T>(FutureOr<T> Function() action) async {
    try {
      return Right(await action());
    } catch (error) {
      return Left(error);
    }
  }

  /// Synchronously evaluates [action], capturing any thrown error into a [Left].
  static Either<Object, T> guard<T>(T Function() action) {
    try {
      return Right(action());
    } catch (error) {
      return Left(error);
    }
  }

  /// Evaluates [action] synchronously with typed error capturing.
  static Either<E, T> tryCatch<E extends Object, T>(
    T Function() action, {
    E Function(Object error, StackTrace stackTrace)? onError,
  }) {
    try {
      return Right(action());
    } catch (error, stackTrace) {
      if (onError != null) {
        return Left(onError(error, stackTrace));
      }
      if (error is E) {
        return Left(error);
      }
      return Left(error as E);
    }
  }

  /// Evaluates [action] asynchronously with typed error capturing.
  static Future<Either<E, T>> tryCatchAsync<E extends Object, T>(
    FutureOr<T> Function() action, {
    E Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    try {
      return Right(await action());
    } catch (error, stackTrace) {
      if (onError != null) {
        return Left(onError(error, stackTrace));
      }
      if (error is E) {
        return Left(error);
      }
      return Left(error as E);
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

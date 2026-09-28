part of '../../core.dart';

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
  Either<L, T> mapRight<T>(T Function(R right) transform) => switch (this) {
    Right<L, R>(:final value) => Right(transform(value)),
    Left<L, R>(:final value, :final trace) => Left(value, trace),
  };

  /// Maps the left failure value if [Left], preserving [Right] and the captured trace.
  Either<T, R> mapLeft<T>(T Function(L left) transform) => switch (this) {
    Left<L, R>(:final value, :final trace) => Left(transform(value), trace),
    Right<L, R>(:final value) => Right(value),
  };

  /// The [Right] value, or throws the [Left] value with the trace it was caught with.
  R unwrap() => switch (this) {
    Right<L, R>(:final value) => value,
    Left<L, R>(:final value, :final trace) => Error.throwWithStackTrace(_throwable(value), trace ?? StackTrace.current),
  };

  /// Runs [action], sync or async, capturing anything it throws as a [Left].
  ///
  /// Narrow the failure type afterwards with [mapLeft].
  static Future<Either<Object, T>> tryCatch<T>(FutureOr<T> Function() action) async {
    try {
      return Right(await action());
    } catch (error, trace) {
      return Left(error, trace);
    }
  }

  /// Runs [action], capturing anything it throws as a [Left], without an `await`.
  static Either<Object, T> tryCatchSync<T>(T Function() action) {
    try {
      return Right(action());
    } catch (error, trace) {
      return Left(error, trace);
    }
  }
}

/// The failure / left branch of [Either].
///
/// {@category Formats}
final class Left<L, R> extends Either<L, R> {
  /// The underlying left value.
  final L value;

  /// Where the failure was caught, when [Either.tryCatch] produced it; [unwrap] rethrows with it.
  final StackTrace? trace;

  /// Creates a [Left] outcome.
  const Left(this.value, [this.trace]);

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
  /// Emits every [Right] value; every [Left] becomes an error event, and the stream continues.
  Stream<R> unwrap() => map((outcome) => outcome.unwrap());

  /// Only the [Right] values, discarding failures.
  Stream<R> get rights => where((outcome) => outcome.isRight).map((outcome) => (outcome as Right<L, R>).value);

  /// Only the [Left] values.
  Stream<L> get lefts => where((outcome) => outcome.isLeft).map((outcome) => (outcome as Left<L, R>).value);
}

part of '../../core.dart';

Object _throwable(Object? value) => value ?? StateError('Unwrapped a Left holding null');

/// A failure [Left] or a success [Right].
///
/// {@category Utilities}
sealed class Either<L, R> {
  const Either();

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

  /// Whether this outcome is a failure [Left].
  bool get isLeft => this is Left<L, R>;

  /// Whether this outcome is a success [Right].
  bool get isRight => this is Right<L, R>;

  /// The [Right] value, or throws the [Left] value with the trace it was caught with.
  R unwrap() => switch (this) {
    Right<L, R>(:final value) => value,
    Left<L, R>(:final value, :final trace) => Error.throwWithStackTrace(_throwable(value), trace ?? StackTrace.current),
  };
}

/// The failure branch of [Either].
///
/// {@category Formats}
final class Left<L, R> extends Either<L, R> {
  final L value;

  /// Where the failure was caught, when it was; [unwrap] rethrows with it.
  final StackTrace? trace;

  const Left(this.value, [this.trace]);

  @override
  bool operator ==(Object other) => identical(this, other) || (other is Left && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Left($value)';
}

/// The success branch of [Either].
///
/// {@category Formats}
final class Right<L, R> extends Either<L, R> {
  final R value;

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
  Stream<R> get rights => where((outcome) => outcome is Right<L, R>).map((outcome) => (outcome as Right<L, R>).value);

  /// Only the [Left] values.
  Stream<L> get lefts => where((outcome) => outcome is Left<L, R>).map((outcome) => (outcome as Left<L, R>).value);
}

/// The same helpers on a batch still settling, so the `await` needs no parentheses:
/// `await batch.rights`.
///
/// {@category Formats}
extension FutureEitherListExtensions<L, R> on Future<List<Either<L, R>>> {
  /// Every [Right] value in order, throwing the first [Left] value encountered.
  Future<List<R>> unwrap() => then((outcomes) => outcomes.unwrap());

  /// Only the [Right] values, discarding failures.
  Future<List<R>> get rights => then((outcomes) => outcomes.rights);

  /// Only the [Left] values.
  Future<List<L>> get lefts => then((outcomes) => outcomes.lefts);
}

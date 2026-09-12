/// # Iterables (`Iterables`)
///
/// Generation, ranges, combinators, partitioning, and zip algorithms over [Iterable].
library;

/// Static utility functions for creating and manipulating [Iterable]s.
abstract final class Iterables {
  /// Creates an iterable of inline elements, filtering out null arguments.
  static Iterable<T> of<T>([
    T? a,
    T? b,
    T? c,
    T? d,
    T? e,
    T? f,
    T? g,
    T? h,
    T? i,
    T? j,
  ]) sync* {
    for (final item in [a, b, c, d, e, f, g, h, i, j]) {
      if (item != null) yield item;
    }
  }

  /// Generates a range of integers from [start] to [end] by [step].
  static Iterable<int> range(int start, int end, [int step = 1]) sync* {
    if (step == 0) throw ArgumentError('step cannot be 0');
    for (var i = start; step > 0 ? i < end : i > end; i += step) {
      yield i;
    }
  }

  /// Generates [count] elements via [generator](index).
  static Iterable<T> generate<T>(
    int count,
    T Function(int index) generator,
  ) sync* {
    for (var i = 0; i < count; i++) {
      yield generator(i);
    }
  }

  /// Generates an infinite or bounded sequence iterating [next] from [seed].
  static Iterable<T> iterate<T>(
    T seed,
    T Function(T current) next, {
    bool Function(T current)? whileCondition,
  }) sync* {
    var curr = seed;
    while (whileCondition == null || whileCondition(curr)) {
      yield curr;
      curr = next(curr);
    }
  }

  /// Generates an iterable repeating [element] [times] (or indefinitely if null).
  static Iterable<T> repeat<T>(T element, [int? times]) sync* {
    for (var i = 0; times == null || i < times; i++) {
      yield element;
    }
  }

  /// Concatenates multiple iterables sequentially.
  static Iterable<T> concat<T>(Iterable<Iterable<T>> iterables) sync* {
    for (final iterable in iterables) {
      yield* iterable;
    }
  }

  /// Combines two iterables pairwise using [combiner].
  static Iterable<R> zip<A, B, R>(
    Iterable<A> a,
    Iterable<B> b,
    R Function(A a, B b) combiner,
  ) sync* {
    final iterA = a.iterator;
    final iterB = b.iterator;
    while (iterA.moveNext() && iterB.moveNext()) {
      yield combiner(iterA.current, iterB.current);
    }
  }

  /// Interleaves elements from [a] and [b] alternately.
  static Iterable<T> interleave<T>(Iterable<T> a, Iterable<T> b) sync* {
    final iterA = a.iterator;
    final iterB = b.iterator;
    var hasA = true;
    var hasB = true;
    while (hasA || hasB) {
      if (hasA && (hasA = iterA.moveNext())) yield iterA.current;
      if (hasB && (hasB = iterB.moveNext())) yield iterB.current;
    }
  }

  /// Partitions [items] into two lists: matching and non-matching [predicate].
  static (List<T> matching, List<T> nonMatching) partition<T>(
    Iterable<T> items,
    bool Function(T item) predicate,
  ) {
    final matching = <T>[];
    final nonMatching = <T>[];
    for (final item in items) {
      if (predicate(item)) {
        matching.add(item);
      } else {
        nonMatching.add(item);
      }
    }
    return (matching, nonMatching);
  }

  /// Generates the Cartesian product of two iterables.
  static Iterable<(A, B)> cartesian<A, B>(Iterable<A> a, Iterable<B> b) sync* {
    for (final itemA in a) {
      for (final itemB in b) {
        yield (itemA, itemB);
      }
    }
  }
}

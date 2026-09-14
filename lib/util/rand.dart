/// # Randomness
///
/// Picks, shuffles, ids and jitter — the small random choices a crawler makes
/// to look less like a machine.
///
/// ```dart
/// final agent = agents.toList().randomElement();
/// await delay(2.s.jittered());
/// ```
/// {@category Utilities}
library;

import 'dart:math';

const String _alphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

const int _maxDraw = 1 << 32;

Random _rng = Random();

/// Randomness with no receiver to hang off.
///
/// Picking and shuffling act on a list, so they are members of one
/// ([RandomListExtensions]); jitter acts on a duration, so it is a member of
/// that (`250.ms.jittered()`). What is left here genuinely *generates* rather
/// than transforms, and a generator has nothing to be a member of — so it is
/// one small type rather than six names in global scope.
///
/// ```dart
/// Rand.seed(42);
/// final id = Rand.id();           // 'x7Fk2mQp9Lda'
/// if (Rand.chance(0.1)) print(1); // one time in ten
/// Rand.between(1, 100);
/// ```
abstract final class Rand {
  /// Fixes the generator behind every random choice in this library to [seed],
  /// or restores an unseeded one when [seed] is omitted.
  ///
  /// Every random choice runs through one generator — [id], [chance],
  /// [between], `list.randomElement()`, `list.shuffled()`, the crawl order they
  /// decide, and the `jittered()` on an HTTP retry — so seeding it makes a run
  /// repeat exactly. That is what a test of any of them needs:
  ///
  /// ```dart
  /// Rand.seed(42);
  /// final first = Rand.id();
  /// Rand.seed(42);
  /// assert(Rand.id() == first);
  /// ```
  ///
  /// Process-wide, and not for anything that must be unguessable: a seeded
  /// generator is reproducible by design.
  static void seed([int? seed]) =>
      _rng = seed == null ? Random() : Random(seed);

  /// A whole random integer in `[min, max)`.
  ///
  /// Spans wider than 2^32 are drawn from two smaller draws, since
  /// [Random.nextInt] only accepts a 32-bit bound.
  static int between(int min, int max) {
    if (max <= min) return min;
    final span = max - min;
    if (span <= _maxDraw) return min + _rng.nextInt(span);
    final high = _rng.nextInt(1 << 32);
    final low = _rng.nextInt(1 << 32);
    return min + (((high << 32) | low) % span).abs();
  }

  /// A random URL-safe id of [length] characters.
  static String id([int length = 12]) => String.fromCharCodes([
    for (var i = 0; i < length; i++)
      _alphabet.codeUnitAt(_rng.nextInt(_alphabet.length)),
  ]);

  /// `true` with probability [probability], which is clamped to `0..1`.
  static bool chance([double probability = 0.5]) =>
      _rng.nextDouble() < probability.clamp(0, 1);
}

/// [base] varied by up to [spread] of itself, never shorter than [base].
///
/// The implementation behind `Duration.jittered()`, which is where callers
/// reach it. A negative [spread] is treated as zero: it is only ever added, so
/// the result is a delay of at least [base]; a negative spread would otherwise
/// make a "jittered" wait finish early.
Duration jitterOf(Duration base, {double spread = 0.25}) {
  final width = spread.isNaN ? 0.0 : (spread < 0 ? 0.0 : spread);
  return Duration(
    microseconds:
        base.inMicroseconds +
        (base.inMicroseconds * width * _rng.nextDouble()).round(),
  );
}

/// Random selection over this list.
extension RandomListExtensions<T> on List<T> {
  /// One item chosen uniformly at random.
  ///
  /// Throws [StateError] when this list is empty.
  T randomElement() {
    if (isEmpty) throw StateError('Cannot pick from an empty list');
    return this[_rng.nextInt(length)];
  }

  /// A shuffled copy, leaving this list untouched.
  List<T> shuffled() => [...this]..shuffle(_rng);
}

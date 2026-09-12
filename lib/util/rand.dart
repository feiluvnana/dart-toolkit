/// # Randomness (`util.rand.*`)
///
/// Picks, shuffles, ids and jitter — the small random choices a crawler makes
/// to look less like a machine.
library;

import 'dart:math';

// ============================================================================
// RANDOMNESS (util.rand.*)
// ============================================================================

/// Entry point for randomness, reachable as `util.rand`.
///
/// ```dart
/// final agent = Rand.pick(agents.toList());
/// await Time.wait(Rand.jitter(2.s));
/// ```
const RandAccessor _randInstance = RandAccessor();

/// Picks one element uniformly at random from [items].
T randomPick<T>(List<T> items) => _randInstance.pick(items);

/// Returns a shuffled copy of [items], leaving the original list untouched.
List<T> randomShuffle<T>(List<T> items) => _randInstance.shuffle(items);

/// Returns a whole random integer in `[min, max)`.
int randomBetween(int min, int max) => _randInstance.between(min, max);

/// Generates a random URL-safe ID of [length] characters.
String randomId([int length = 12]) => _randInstance.id(length);

/// Returns [base] varied by up to [spread] of itself, never shorter than [base].
Duration jitter(Duration base, {double spread = 0.25}) =>
    _randInstance.jitter(base, spread: spread);

// ============================================================================
// STATIC HELPER HUB: Rand
// ============================================================================

/// Static helper hub for random element picking, shuffling, and IDs.
///
/// Easily discoverable via IDE auto-complete:
/// ```dart
/// final item = Rand.pick(['a', 'b', 'c']);
/// final shuffled = Rand.shuffle([1, 2, 3]);
/// final num = Rand.between(1, 100);
/// final id = Rand.id(16);
/// final jittered = Rand.jitter(const Duration(seconds: 2));
/// ```
abstract final class Rand {
  Rand._();

  /// Picks one element uniformly at random from [items].
  static T pick<T>(List<T> items) => _randInstance.pick(items);

  /// Returns a shuffled copy of [items], leaving the original list untouched.
  static List<T> shuffle<T>(List<T> items) => _randInstance.shuffle(items);

  /// Returns a whole random integer in `[min, max)`.
  static int between(int min, int max) => _randInstance.between(min, max);

  /// Generates a random URL-safe ID of [length] characters.
  static String id([int length = 12]) => _randInstance.id(length);

  /// Returns [base] varied by up to [spread] of itself, never shorter than [base].
  static Duration jitter(Duration base, {double spread = 0.25}) =>
      _randInstance.jitter(base, spread: spread);

  /// Fixes the generator seed for reproducibility.
  static void seed([int? seed]) => _randInstance.seed(seed);

  /// `true` with probability [chance], which is clamped to `0..1`.
  static bool chance([double chance = 0.5]) => _randInstance.chance(chance);
}

class RandAccessor {
  /// Creates the accessor. Prefer the shared `util.rand` instance.
  const RandAccessor();

  static Random _rng = Random();
  static const _alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  /// Fixes the generator behind every method here to [seed], or restores an
  /// unseeded one when [seed] is omitted.
  ///
  /// Every random choice this library makes runs through one generator —
  /// `pick`, `shuffle`, `id`, `chance`, the crawl order they decide, and the
  /// jitter on an HTTP retry — so seeding it makes a run repeat exactly. That
  /// is what a test of any of them needs:
  ///
  /// ```dart
  /// Rand.seed(42);
  /// expect(Rand.pick(agents.toList()),
  ///     Rand.pick(agents.toList())); // no
  /// Rand.seed(42);
  /// final first = Rand.id();
  /// Rand.seed(42);
  /// expect(Rand.id(), first);                          // yes
  /// ```
  ///
  /// Process-wide, and not for anything that must be unguessable: a seeded
  /// generator is reproducible by design.
  void seed([int? seed]) => _rng = seed == null ? Random() : Random(seed);

  /// One item chosen uniformly from [items].
  ///
  /// Throws [StateError] when [items] is empty.
  T pick<T>(List<T> items) {
    if (items.isEmpty) {
      throw StateError('Cannot pick from an empty list');
    }
    return items[_rng.nextInt(items.length)];
  }

  /// A shuffled copy of [items], leaving the original untouched.
  List<T> shuffle<T>(List<T> items) => [...items]..shuffle(_rng);

  /// A whole number in `[min, max)`.
  ///
  /// Spans wider than 2^32 are drawn from two smaller draws, since
  /// [Random.nextInt] only accepts a 32-bit bound.
  int between(int min, int max) {
    if (max <= min) return min;
    final span = max - min;
    if (span <= _maxDraw) return min + _rng.nextInt(span);
    final high = _rng.nextInt(1 << 32);
    final low = _rng.nextInt(1 << 32);
    return min + (((high << 32) | low) % span).abs();
  }

  static const int _maxDraw = 1 << 32;

  /// A random URL-safe id of [length] characters.
  String id([int length = 12]) => String.fromCharCodes([
    for (var i = 0; i < length; i++)
      _alphabet.codeUnitAt(_rng.nextInt(_alphabet.length)),
  ]);

  /// [base] varied by up to [spread] of itself, never shorter than [base].
  ///
  /// A negative [spread] is treated as zero.
  ///
  /// Spacing requests by a jittered delay stops a pool of workers from
  /// resynchronising onto the same instant.
  Duration jitter(Duration base, {double spread = 0.25}) {
    // Only ever added, so the result is a delay of at least [base]; a negative
    // spread would otherwise make a "jittered" wait finish early.
    final width = spread.isNaN ? 0.0 : (spread < 0 ? 0.0 : spread);
    return Duration(
      microseconds:
          base.inMicroseconds +
          (base.inMicroseconds * width * _rng.nextDouble()).round(),
    );
  }

  /// `true` with probability [chance], which is clamped to `0..1`.
  bool chance([double chance = 0.5]) => _rng.nextDouble() < chance.clamp(0, 1);
}

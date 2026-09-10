/// # Randomness (`util.rand.*`)
///
/// Picks, shuffles, ids and jitter — the small random choices a crawler makes
/// to look less like a machine.
library;

import 'dart:math';

import 'sequence.dart';

// ============================================================================
// RANDOMNESS (util.rand.*)
// ============================================================================

/// Entry point for randomness, reachable as `util.rand`.
///
/// ```dart
/// final agent = util.rand.pick(agents);
/// await util.time.wait(util.rand.jitter(2.s));
/// ```
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
  /// util.rand.seed(42);
  /// expect(util.rand.pick(agents), util.rand.pick(agents)); // no
  /// util.rand.seed(42);
  /// final first = util.rand.id();
  /// util.rand.seed(42);
  /// expect(util.rand.id(), first);                          // yes
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

  /// [count] distinct items chosen from [items], in random order.
  ///
  /// Returns everything, shuffled, when [count] exceeds the list length.
  Sequence<T> some<T>(List<T> items, int count) =>
      shuffle(items).head(count < 0 ? 0 : count);

  /// A shuffled copy of [items], leaving the original untouched.
  ///
  /// Randomness lives here rather than on [Sequence], so a sequence gets it by
  /// exiting: `util.rand.shuffle(rows.list)`.
  Sequence<T> shuffle<T>(List<T> items) => Sequence([...items]..shuffle(_rng));

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

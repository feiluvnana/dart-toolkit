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
/// final agent = util.rand.pick(agents);
/// await util.time.wait(util.rand.jitter(2.s));
/// ```
class RandAccessor {
  /// Creates the accessor. Prefer the shared `util.rand` instance.
  const RandAccessor();

  static final Random _rng = Random();
  static const _alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

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
  List<T> some<T>(List<T> items, int count) {
    final pool = shuffle(items);
    return pool.take(count.clamp(0, pool.length)).toList();
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

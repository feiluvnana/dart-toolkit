/// # Randomness
///
/// Picks, shuffles, ids and jitter — the small random choices a crawler makes
/// to look less like a machine.
///
/// ```dart
/// final agent = randomPick(agents.toList());
/// await delay(jitter(2.s));
/// ```
library;

import 'dart:math';

const String _alphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

const int _maxDraw = 1 << 32;

Random _rng = Random();

/// Fixes the generator behind every function here to [seed], or restores an
/// unseeded one when [seed] is omitted.
///
/// Every random choice this library makes runs through one generator —
/// [randomPick], [randomShuffle], [randomId], [randomChance], the crawl order
/// they decide, and the [jitter] on an HTTP retry — so seeding it makes a run
/// repeat exactly. That is what a test of any of them needs:
///
/// ```dart
/// // setup: final agents = ['a', 'b', 'c'];
/// seedRandom(42);
/// final first = randomId();
/// seedRandom(42);
/// assert(randomId() == first);
/// ```
///
/// Process-wide, and not for anything that must be unguessable: a seeded
/// generator is reproducible by design.
void seedRandom([int? seed]) => _rng = seed == null ? Random() : Random(seed);

/// One item chosen uniformly at random from [items].
///
/// Throws [StateError] when [items] is empty.
T randomPick<T>(List<T> items) {
  if (items.isEmpty) {
    throw StateError('Cannot pick from an empty list');
  }
  return items[_rng.nextInt(items.length)];
}

/// A shuffled copy of [items], leaving the original list untouched.
List<T> randomShuffle<T>(List<T> items) => [...items]..shuffle(_rng);

/// A whole random integer in `[min, max)`.
///
/// Spans wider than 2^32 are drawn from two smaller draws, since
/// [Random.nextInt] only accepts a 32-bit bound.
int randomBetween(int min, int max) {
  if (max <= min) return min;
  final span = max - min;
  if (span <= _maxDraw) return min + _rng.nextInt(span);
  final high = _rng.nextInt(1 << 32);
  final low = _rng.nextInt(1 << 32);
  return min + (((high << 32) | low) % span).abs();
}

/// A random URL-safe id of [length] characters.
String randomId([int length = 12]) => String.fromCharCodes([
  for (var i = 0; i < length; i++)
    _alphabet.codeUnitAt(_rng.nextInt(_alphabet.length)),
]);

/// `true` with probability [probability], which is clamped to `0..1`.
bool randomChance([double probability = 0.5]) =>
    _rng.nextDouble() < probability.clamp(0, 1);

/// Returns [base] varied by up to [spread] of itself, never shorter than [base].
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

/// Random selection over this list.
extension RandomListExtensions<T> on List<T> {
  /// One item chosen uniformly at random. See [randomPick].
  T randomItem() => randomPick(this);

  /// A shuffled copy, leaving this list untouched. See [randomShuffle].
  List<T> shuffled() => randomShuffle(this);
}

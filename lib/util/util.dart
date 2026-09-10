/// # Util Domain (`util.*`)
///
/// Pure helpers, with no filesystem and no operating system behind them:
/// time and delays (`util.time`), byte sizes (`util.size`), text handling
/// (`util.text`), hashing (`util.hash`) and randomness (`util.rand`).
///
/// The rule: anything that touches the disk lives in `io`, anything that
/// touches the OS or the user lives in `system`. Archives are `tool.zip`, Git
/// is `tool.git`, and the terminal is `system.console`.
library;

import 'hash.dart';
import 'rand.dart';
import 'size.dart';
import 'text.dart';
import 'time.dart';

export 'extensions.dart';
export 'hash.dart';
export 'rand.dart';
export 'size.dart';
export 'text.dart';
export 'time.dart';

// ============================================================================
// UTIL DOMAIN (util.*) - Time, Size, Text, Hash & Rand
// ============================================================================

/// The `util` domain: time, sizes, text, hashing and randomness.
const UtilAccessor util = UtilAccessor();

/// Entry point for the `util` sub-namespaces.
class UtilAccessor {
  /// Creates the accessor. Prefer the shared [util] instance.
  const UtilAccessor();

  /// Delays, timestamps and duration formatting.
  TimeAccessor get time => const TimeAccessor();

  /// Human-readable byte sizes.
  SizeAccessor get size => const SizeAccessor();

  /// Slugs, cleaning, truncation and pulling values out of raw text.
  TextAccessor get text => const TextAccessor();

  /// Digests, signatures and base64.
  HashAccessor get hash => const HashAccessor();

  /// Picks, shuffles, ids and jitter.
  RandAccessor get rand => const RandAccessor();
}

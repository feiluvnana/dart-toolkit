/// # Util Domain (`util.*`)
///
/// Pure helpers, with no filesystem and no operating system behind them:
/// time and delays (`util.time`), byte sizes (`util.size`), text handling
/// (`util.text`), hashing (`util.hash`) and randomness (`util.rand`) — plus
/// the two document cursors, [Json] for a tree of maps and scalars and
/// [Markup] for a tree of elements, that `format` builds and `net` hands back
/// through [Codec].
///
/// `Sequence` and `Dictionary` used to be here and are their own domain now —
/// see `lib/collection/`. This holds functions you call; a collection is a
/// type you receive.
///
/// The cursors live here and their codecs live in `format` for the same
/// reason: a cursor is a pure value that more than one domain returns, and a
/// format is knowledge from outside Dart.
///
/// The rule: anything that touches the disk lives in `io`, anything that
/// touches the OS or the user lives in `system`. Archives are `format.zip`,
/// and the terminal is `system.console`.
library;

import 'hash.dart';
import 'rand.dart';
import 'size.dart';
import 'text.dart';
import 'time.dart';

export 'codec.dart';
export 'extensions.dart';
export 'hash.dart';
export 'json.dart';
export 'markup.dart';
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

  /// Slugs, cleaning, truncation, templates and pulling values out of raw text.
  TextAccessor get text => const TextAccessor();

  /// Digests, signatures and base64.
  HashAccessor get hash => const HashAccessor();

  /// Picks, shuffles, ids and jitter.
  RandAccessor get rand => const RandAccessor();
}

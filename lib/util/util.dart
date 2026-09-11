/// # Util Domain (`util.*`)
///
/// Pure helpers, with no filesystem and no operating system behind them:
/// time and delays (`util.time`), byte sizes (`util.size`), text handling
/// (`util.text`), hashing (`util.hash`) and randomness (`util.rand`).
///
/// **Five files, five accessors, and nothing else.** `Json`, `Markup`, `Csv`,
/// [Codec] and the `.url`/`.ms` extensions sat under `lib/util/` through
/// 5.4.0 and were never reachable through `util.` anything: they are types
/// and extensions that several domains return, not a sub-namespace of this
/// one. A directory named after an accessor should hold that accessor's
/// members and no strays, so 5.5.0 moved them to `lib/src/`, where the rest
/// of the cross-domain machinery already lives. They are exported from
/// `package:dart_toolkit/dart_toolkit.dart` exactly as before; nothing a
/// caller writes changed.
///
/// `Sequence` and `Dictionary` used to be here and are their own domain now —
/// see `lib/collection/`. This holds functions you call; a collection is a
/// type you receive.
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

  /// Slugs, cleaning, truncation, templates and pulling values out of raw text.
  TextAccessor get text => const TextAccessor();

  /// Digests, signatures and base64.
  HashAccessor get hash => const HashAccessor();

  /// Picks, shuffles, ids and jitter.
  RandAccessor get rand => const RandAccessor();
}

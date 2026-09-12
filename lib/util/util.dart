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


export 'hash.dart';
export 'rand.dart';
export 'size.dart';
export 'text.dart';
export 'time.dart';


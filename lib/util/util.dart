/// # Utilities
///
/// Pure helpers, with no filesystem and no operating system behind them:
/// time and delays (`time.dart`), byte sizes (`size.dart`), text handling
/// (`text.dart`), hashing (`hash.dart`) and randomness (`rand.dart`).
///
/// Every helper here is a **top-level function**, and most have a matching
/// extension method on the type they operate on, so the two spellings below
/// are the same call:
///
/// ```dart
/// 'Hello World'.toSlug();   // 'hello-world'
/// 'Hello World'.toSlug();   // 'hello-world'
/// ```
///
/// The rule for what belongs here: anything that touches the disk lives in
/// `io`, anything that touches the OS or the user lives in `system`. Archives
/// are `format`, and the terminal is `system/console`.
/// {@category Utilities}
library;

export 'hash.dart';
export 'rand.dart' hide jitterOf;
export 'size.dart';
export 'text.dart';
export 'time.dart';

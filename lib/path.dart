/// # Files & Paths
///
/// What a [Path] can do: its parts (`/`, `name`, `ext`, `parent`, …), reading and writing (writes
/// are atomic), listings with one vocabulary, and the long operations (copy, move, delete,
/// trash) as `Task`s that report progress and can be cancelled.
///
/// {@category Files}
library;

export 'src/path.dart' hide PathInternals;

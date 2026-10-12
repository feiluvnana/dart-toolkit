/// # Core
///
/// What every module stands on: a [Source] is anything readable and a [Target] anything
/// writable; every source has the readings `text`, `bytes` and `lines`, and `pipe` copies a
/// source into a target. [Reader] and [Writer] are the chunk level beneath, and the shared
/// error table lives here. No dependencies.
library;

export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';

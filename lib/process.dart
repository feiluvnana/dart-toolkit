/// # Processes
///
/// A lazy `Process(cmd, args)`: stdout is a `Source`, stdin a `Target`, so
/// readings and `pipe` work on it. A non-zero exit throws a
/// `ProcessException`; `check` answers yes or no; `close` kills the whole
/// tree.
library;

export 'src/process/process.dart';
export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';

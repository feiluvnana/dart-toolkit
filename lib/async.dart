/// # Async & Concurrency
///
/// `Task.run` for one-shot background work on an isolate, `Pool` for mapping
/// over persistent worker isolates, and `Chan` for bounded channels with
/// backpressure (including fan-in from worker isolates via [Chan.post]).
library;

export 'src/async/chan.dart';
export 'src/async/pool.dart';
export 'src/async/task.dart';
export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';

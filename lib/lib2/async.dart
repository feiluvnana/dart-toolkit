/// # Async & Concurrency
///
/// `Task` for one-shot background work, `Pool` for a fixed worker pool, and `Chan` for
/// bounded multi-producer channels with backpressure and deterministic completion.
library;

export 'src/async/chan.dart';
export 'src/async/pool.dart';
export 'src/async/task.dart';

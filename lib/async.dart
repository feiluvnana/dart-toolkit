/// # Async & Concurrency
///
/// `Worker`, `Pool` and `Job` (work kept busy, jobs that outlive the program), `Semaphore`, and
/// stream operators: `chunk`, `debounce`, `throttle`, `unique`, `merge`. `parallelize`,
/// `Retry` and `Cancel` are in `core`.
///
/// {@category Concurrency}
library;

export 'core.dart';

export 'src/async.dart';

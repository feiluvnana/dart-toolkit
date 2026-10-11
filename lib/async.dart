/// # Async & Concurrency
///
/// `Task` for one-shot background work (`isolate: true` leaves the event loop live),
/// `Pool` over persistent worker isolates built from a `Worker` factory, and `Chan`
/// for bounded multi-producer channels with backpressure (including fan-in from
/// worker isolates via `sendPort`/`sendTo`) and deterministic completion.
library;

export 'src/async/chan.dart';
export 'src/async/pool.dart';
export 'src/async/task.dart';
export 'src/async/worker.dart';

/// # Async & Concurrency
///
/// Bounded parallelism, retries, a semaphore, isolate pools and stream operators. Cancellation
/// (`Cancel.scope`) lives in `core`.
///
/// {@category Concurrency}
library;

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math';

import 'core.dart';

part 'src/async/parallelize.dart';
part 'src/async/pool.dart';
part 'src/async/retry.dart';
part 'src/async/stream_extensions.dart';
part 'src/async/sync.dart';

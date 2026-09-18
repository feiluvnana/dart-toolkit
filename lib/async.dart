/// # Async & Concurrency
///
/// Bounded parallelism, retries, synchronisation primitives, isolate
/// offloading, cancellation tokens and stream operators.
///
/// {@category Concurrency}
library;

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'core.dart';

part 'src/async/cancellation_token.dart';
part 'src/async/isolate.dart';
part 'src/async/parallelize.dart';
part 'src/async/retry.dart';
part 'src/async/stream_extensions.dart';
part 'src/async/sync.dart';

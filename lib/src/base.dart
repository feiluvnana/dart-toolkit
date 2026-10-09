/// Core's foundations: everything in `core` but `Io`, `Store` and `Key`, `Border`,
/// `Detachable` and the `Terminal` seam. A topic whose code needs none of those (the formats,
/// paths, hashing, the native library) builds on this alone and compiles less.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

part 'core/batch.dart';
part 'core/bytes.dart';
part 'core/cancel.dart';
part 'core/clock.dart';
part 'core/coerce.dart';
part 'core/env.dart';
part 'core/file_bridge.dart';
part 'core/isolate.dart';
part 'core/missing.dart';
part 'core/or_null.dart';
part 'core/path_type.dart';
part 'core/process_registry.dart';
part 'core/retry.dart';
part 'core/secret.dart';
part 'core/semaphore.dart';
part 'core/status.dart';
part 'core/string_extensions.dart';
part 'core/task.dart';
part 'core/time.dart';

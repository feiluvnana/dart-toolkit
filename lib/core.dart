/// # Core
///
/// What every other module stands on and every script reaches for: `Either`, string helpers,
/// `Env`, the `ConsoleIo` seam, the progress seam, `Crc32` and duration helpers. No dependencies.
///
/// {@category Core}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

part 'src/core/crc32.dart';
part 'src/core/either.dart';
part 'src/core/env.dart';
part 'src/core/progress.dart';
part 'src/core/stdio.dart';
part 'src/core/string_extensions.dart';
part 'src/core/time.dart';

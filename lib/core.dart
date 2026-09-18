/// # Core
///
/// What every other module stands on and every script reaches for: `Either`, string helpers,
/// `Env`, the `Io` seam, the progress seam, and duration helpers. No dependencies.
///
/// {@category Core}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

part 'src/core/either.dart';
part 'src/core/env.dart';
part 'src/core/progress.dart';
part 'src/core/stdio.dart';
part 'src/core/string_extensions.dart';
part 'src/core/time.dart';

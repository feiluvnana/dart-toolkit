/// # Utilities
///
/// Environment variables, the console IO seam, the progress seam and duration
/// helpers. OS detection is `Platform.isMacOS` and friends from `dart:io`.
///
/// {@category Utilities}
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

part 'src/util/crc32.dart';
part 'src/util/env.dart';
part 'src/util/progress.dart';
part 'src/util/stdio.dart';
part 'src/util/time.dart';

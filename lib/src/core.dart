/// `core` whole: its foundations (`base.dart`) and `Io`, `Store` and `Key`, `Border`,
/// `Detachable` and the `Terminal` seam.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:io' as io show stderr, stdin, stdout;

import 'base.dart';

export 'base.dart';

part 'core/border.dart';
part 'core/detachable.dart';
part 'core/stdio.dart';
part 'core/store.dart';
part 'core/terminal_seam.dart';

/// The state-driven engine behind `tui.dart`: session loop, zone, routing,
/// painter, widgets, markdown, diff and the Console bridge.
/// [TestSession] is the in-memory harness for `test/tui_test.dart`.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'exit.dart' as exit;
import 'keys.dart' as keys;
import 'terminal.dart' as term;

part 'tui/session.dart';
part 'tui/region.dart';
part 'tui/paint.dart';
part 'tui/widgets.dart';
part 'tui/markdown.dart';
part 'tui/diff.dart';
part 'tui/harness.dart';

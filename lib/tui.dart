/// # Tui
///
/// Full-screen and inline terminal apps: [Tui.run] takes a state, a `view` of it built from
/// widgets ([Label], [VStack], [HStack], [Box], [Menu], [Grid], [Field], [Tabs], [Gauge],
/// [Spin], [Paint]) and an `update` that answers [Key]s, [Char]s, [Mouse] and your own
/// messages. A cell buffer is diffed so each frame writes only what changed; colour falls back
/// from 24-bit to 256 to 16 to none; the terminal is put back on every way out.
///
/// Not in the `dart_toolkit.dart` barrel — import it by name:
///
/// ```dart
/// import 'package:dart_toolkit/tui.dart';
/// ```
///
/// {@category CLI}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'core.dart';

export 'core.dart' show TaskState;

part 'src/tui/app.dart';
part 'src/tui/canvas.dart';
part 'src/tui/controls.dart';
part 'src/tui/event.dart';
part 'src/tui/field.dart';
part 'src/tui/gauge.dart';
part 'src/tui/style.dart';
part 'src/tui/terminal.dart';
part 'src/tui/widget.dart';

/// # Pickers
///
/// `list.pick(question)` and `list.pickMany(question)`: a choice from a list, under the cursor on
/// a terminal (arrows, filtering, checks), numbered elsewhere. In the console's place, as its
/// prompts are; its own import, so a `cli` script that never picks compiles no key reader.
///
/// {@category CLI}
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'src/cli.dart';
import 'src/core.dart';
import 'src/keys.dart';
import 'src/terminal.dart';

export 'cli.dart';

part 'src/cli/pick.dart';

/// What `cli.dart` exports, and [ConsoleBridge], through which `pick.dart` draws its pickers in
/// the console's place.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'core.dart';
import 'terminal.dart';

part 'cli/command.dart';
part 'cli/completion.dart';
part 'cli/console.dart';
part 'cli/lifecycle.dart';

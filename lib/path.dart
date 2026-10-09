/// # Files & Paths
///
/// What a [Path] can do: its parts (`/`, `name`, `ext`, `parent`, …), reading and writing (writes
/// are atomic), listings with one vocabulary, and the long operations (copy, move, delete,
/// trash) as `Task`s that report progress and can be cancelled.
///
/// {@category Files}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'src/core.dart';
import 'src/native.dart';

export 'core.dart';

part 'src/fs/copy.dart';
part 'src/fs/duplicates.dart';
part 'src/fs/glob.dart';
part 'src/fs/list.dart';
part 'src/fs/mode.dart';
part 'src/fs/path.dart';
part 'src/fs/rename.dart';
part 'src/fs/sys.dart';
part 'src/fs/watch.dart';

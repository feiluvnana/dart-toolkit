/// # Collections
///
/// `Table`: rows of named columns from CSV, TSV, JSON, NDJSON, Markdown or maps,
/// queried in memory and written in any of those formats.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'src/collection/formats_bridge.dart';
import 'src/fs/io.dart';
import 'src/tui/width.dart';

export 'src/core/errors.dart';

part 'src/collection/table.dart';

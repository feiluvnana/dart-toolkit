/// # Collections
///
/// `Table`: rows of named columns from CSV, TSV, JSON, NDJSON, Markdown, maps or an HTML table,
/// queried in memory and written in any of those formats.
///
/// {@category Collections}
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'src/collection/formats_bridge.dart';
import 'src/core.dart';

export 'core.dart';

part 'src/collection/table.dart';

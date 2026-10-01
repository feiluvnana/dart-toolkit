/// # Collections
///
/// `Sequence`, a lazy LINQ/Kotlin-style query over any `Iterable` or `Map` (`items.sequence`),
/// with `Sorted` for multi-key ordering; and `Table`, rows of named columns from maps, JSON, CSV,
/// a file or an HTML table. Nothing is added to `Iterable` or `Map` beyond the `.sequence` way in.
///
/// {@category Collections}
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'core.dart';

part 'src/collection/sequence.dart';
part 'src/collection/table.dart';

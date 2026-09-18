/// # Collections
///
/// `Sequence`, a lazy query over any `Iterable` or `Map` (`items.sequence`, `map.sequence`) with LINQ's and
/// Kotlin's vocabulary; `Sorted`, its multi-key ordering; and `Table`, rows of named columns
/// from maps, records, JSON, CSV or an HTML table. Nothing is added to `Iterable` or `Map`
/// themselves: the way in is a conversion, and a `Sequence` is still an `Iterable` on the way out.
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

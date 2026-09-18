/// # Collections
///
/// `Seq`, a lazy query over any `Iterable` or `Map` (`items.seq`, `map.seq`) with LINQ's and
/// Kotlin's vocabulary; `Sorted`, its multi-key ordering; and `Table`, rows of named columns
/// from maps, records, JSON, CSV or an HTML table. Nothing is added to `Iterable` or `Map`
/// themselves: the way in is a conversion, and a `Seq` is still an `Iterable` on the way out.
///
/// {@category Collections}
library;

import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'core.dart';

part 'src/collection/seq.dart';
part 'src/collection/table.dart';

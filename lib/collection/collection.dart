/// # Collections
///
/// Extensions directly on the standard [Iterable], [Stream] and [Map] — no
/// wrapper types, no pipeline objects, nothing to convert into or out of:
///
/// ```dart
/// items.sortedBy((s) => s.length).chunk(2);
/// await urls.parallelMap(Http.get, concurrency: 5);
/// rows.groupBy((r) => r.name);
/// ```
///
/// The three `Iterables`, `Maps` and `Streams` classes hold only what has no
/// receiver to hang off: factories such as `Iterables.range` and n-ary
/// combinators such as `Streams.merge`.
/// {@category Collections}
library;

export 'iterable_extensions.dart';
export 'iterables.dart';
export 'map_extensions.dart';
export 'maps.dart';
export 'stream_extensions.dart';
export 'streams.dart';

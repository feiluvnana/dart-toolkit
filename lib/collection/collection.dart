/// # Collections
///
/// Extensions directly on the standard [Iterable], [Stream] and [Map] — no
/// wrapper types, no pipeline objects, nothing to convert into or out of:
///
/// ```dart
/// items.sortedBy((s) => s.length).chunk(2);
/// await urls.parallelMap(Http.get, concurrency: 5);
/// rows.groupBy((r) => r.host);
/// ```
///
/// ## The word form says whether you get a copy
///
/// This is `dart:core`'s own rule, and the reason `sorted` is a participle
/// while `sort` is not:
///
/// - **A noun or adjective hands back a new value** and leaves the receiver
///   alone: [IterableExtensions.sorted], `reversed`, `shuffled`, `distinct`,
///   [MapExtensions.inverted], [MapExtensions.merged], `nonNulls`.
/// - **A verb does something** — it mutates, or it touches the disk, the
///   network or the terminal: `List.sort`, `Map.addAll`, `writeText`,
///   `delete`, `render`.
///
/// `sorted` is spelled that way *because* `List.sort` exists and sorts in
/// place; a reader must never have to check which one they wrote. Same for
/// [MapExtensions.merged] beside `Map.addAll`.
///
/// **Where `dart:core` already uses a verb for a copying operation, so does
/// this package** — `where`, `map`, `expand`, `take`, `followedBy` on
/// `Iterable`, and `trim`, `toLowerCase`, `replaceAll` on `String`. Matching
/// the platform beats matching ourselves: a reader who knows one knows the
/// other, and a reader who knows neither has one convention to learn instead
/// of two.
///
/// ## `by` is the keyed form
///
/// Wherever an operation can take *the thing to compare, group or dedupe by*
/// instead of doing the comparing itself, the keyed member is the same name
/// plus `By`: [IterableExtensions.sorted] / `sortedBy`, `distinct` /
/// `distinctBy`, `groupBy`, `countBy`, `maxByOrNull`, `minByOrNull`,
/// `toMapBy`.
///
/// ## `OrNull` means it can be null
///
/// `maxOrNull`, `minOrNull`, `maxByOrNull`, `minByOrNull`, `firstOrNull`,
/// `lastOrNull` — the `dart:core` suffix, and not decoration:
/// `package:collection` gives the *throwing* contract to the bare `max` and
/// `min`, so sharing those names with a nullable return is a trap rather than
/// a convenience.
///
/// The three `Iterables`, `Maps` and `Streams` classes hold only what has no
/// receiver to hang off: factories such as `Iterables.range` and n-ary
/// combinators such as `Streams.merge`.
library;

export 'iterable_extensions.dart';
export 'iterables.dart';
export 'map_extensions.dart';
export 'maps.dart';
export 'stream_extensions.dart';
export 'streams.dart';

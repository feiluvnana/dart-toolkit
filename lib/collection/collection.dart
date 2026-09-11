/// # Collections (`Sequence`, `Dictionary`)
///
/// The two collections this library returns in place of Dart's, and the two
/// operation types that shape them.
///
/// - [Sequence] is the ordered collection, [Dictionary] the keyed one.
/// - [Transformer] is an operation that turns a sequence into another
///   sequence; [Collector] is one that turns a sequence into a single value.
///   Both are values: a pipeline can be stored, passed, tested and supplied by
///   a caller.
/// - [Slot] is a typed key into a JSON-backed dictionary.
///
/// There is no `collection` accessor. It is a library, not a
/// `collection.something` you call: Rule 2 spends no top-level name, and you
/// reach every one of these types from the data you already hold.
library;

export 'collector.dart';
export 'dictionary.dart';
export 'sequence.dart';
export 'slot.dart';
export 'transformer.dart';

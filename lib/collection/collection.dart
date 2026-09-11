/// # Collections (`Sequence`, `Dictionary`, `Flow`)
///
/// The three collections this library returns in place of Dart's, and the two
/// operation types that shape them.
///
/// - [Sequence] is the ordered collection, [Dictionary] the keyed one, and
///   [Flow] the one whose elements arrive over time — `Iterable`, `Map` and
///   `Stream` respectively.
/// - [Transformer] is an operation that turns a collection into another
///   collection; [Collector] is one that turns a collection into a single
///   value. Both are values: a pipeline can be stored, passed, tested and
///   supplied by a caller, and the same one runs over a sequence or a flow.
/// - [Slot] is a typed key into a JSON-backed dictionary.
///
/// There is no `collection` accessor. It is a library, not a
/// `collection.something` you call: Rule 2 spends no top-level name, and you
/// reach every one of these types from the data you already hold.
library;

export 'collector.dart';
export 'dictionary.dart';
export 'flow.dart';
export 'sequence.dart';
export 'slot.dart';
export 'transformer.dart';

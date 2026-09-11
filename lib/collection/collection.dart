/// # Collections (`Sequence`, `Dictionary`, `Flow`)
///
/// The three collections this library returns in place of Dart's, and the two
/// operation types that shape them.
///
/// - [Sequence] is the ordered collection, [Dictionary] the keyed one, and
///   [Flow] the one whose elements arrive over time — `Iterable`, `Map` and
///   `Stream` respectively.
/// - Four operation types, one pair per container. [Transformer] turns a
///   [Sequence] into another sequence and [Collector] turns one into a
///   single value; [Pipe] and [Pour] are the same two jobs over a [Flow].
///   All four are values: a pipeline can be stored, passed, tested and
///   supplied by a caller.
/// - [Slot] is a typed key into a JSON-backed dictionary.
///
/// It was one pair through 5.4.0, serving both containers, with the
/// streaming half of every operation an optional field. See the [Transformer]
/// class doc for what separating them bought and cost; **no call site
/// changed**, because a dot shorthand resolves against the context type.
///
/// There is no `collection` accessor. It is a library, not a
/// `collection.something` you call: Rule 2 spends no top-level name, and you
/// reach every one of these types from the data you already hold.
library;

export 'collector.dart';
export 'dictionary.dart';
export 'flow.dart';
export 'pipe.dart';
export 'sequence.dart';
export 'slot.dart';
export 'transformer.dart';

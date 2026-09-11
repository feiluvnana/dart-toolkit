/// # Dictionaries (`Dictionary<K, V>`)
///
/// The keyed collection, as [Sequence] is the ordered one.
///
/// It is what grouping hands back, so a chain never has to leave this
/// vocabulary and climb back in; it is what a crawl carries as `Fetch.meta`;
/// and with [Slot]s for keys it is what a script keeps in a JSON file between
/// runs. Those were three classes before this one existed.
library;

import 'collector.dart';
import 'sequence.dart';
import 'slot.dart';
import 'transformer.dart';

// ============================================================================
// DICTIONARIES (Dictionary<K, V>)
// ============================================================================

/// A keyed collection, carrying this library's vocabulary.
///
/// ```dart
/// final spend = rows.collect(.group.into((r) => r.host, .sum((r) => r.cost)));
///
/// spend.get('a.com');                              // num?
/// spend.pairs.transform(.sort.by((e) => e.$1));
/// ```
///
/// ## The same two doors [Sequence] has
///
/// [transform] and [collect] run over `(K, V)` records, so the whole
/// [Transformer] and [Collector] vocabulary reaches a dictionary without a
/// second set of factories:
///
/// ```dart
/// // setup: final hosts = Sequence(const [Row('a.com', 1, 1)]).collect(.group.by((r) => r.host));
/// hosts.transform(.where((e) => e.$2.collect(.count()) > 10));
/// ```
///
/// [transform] keeps you in a dictionary, so its transformer has to hand back
/// records. To leave, go through [pairs], [keys] or [values].
///
/// ## Not a `Map`
///
/// For the reason [Sequence] is not an `Iterable`: an extension member never
/// overrides an instance member, so `get` beside `[]` and `count` beside
/// `length` would be two spellings of one operation forever. [map] is the one
/// word at the boundary, as `Sequence.collect(.list())` is for the other
/// collection.
///
/// ## Typed keys
///
/// A `Dictionary<String, Object?>` reads and writes through [Slot]s — see the
/// `Slotted` extension. That is what `Meta` and `Store` each used to implement
/// privately, nine members apiece.
final class Dictionary<K, V> {
  final Map<K, V> _entries;

  /// Holds [entries], copied now.
  ///
  /// A snapshot: nothing underneath can change while you hold it. A
  /// [Sequence] is the other way about — it holds a view — so [keys],
  /// [values] and [pairs] copy on the way out rather than handing one over
  /// this dictionary's own [set] and [delete] could pull apart mid-walk.
  /// Insertion order is kept, so all three come back in the order they went
  /// in.
  Dictionary([Map<K, V> entries = const {}]) : _entries = Map<K, V>.of(entries);

  /// The empty dictionary, as a `const`.
  const Dictionary.empty() : _entries = const {};

  /// Holds [pairs], the last to claim a key winning.
  Dictionary.of(Iterable<(K, V)> pairs)
    : _entries = {for (final (key, value) in pairs) key: value};

  // --------------------------------------------------------------------------
  // Reading
  // --------------------------------------------------------------------------

  /// The value [key] names, or `null` when it is absent.
  ///
  /// Nullable rather than throwing, like every other reader in this library.
  /// `?? fallback` is how you say the other thing.
  V? get(K key) => _entries[key];

  /// Whether [key] is present.
  ///
  /// Worth having beside [get] because a `V` that is itself nullable cannot
  /// tell absent from `null` any other way.
  bool has(K key) => _entries.containsKey(key);

  /// How many entries there are.
  ///
  /// A shorthand **defined as** the terminal, so there is one implementation
  /// of the question and the two spellings cannot disagree. [Sequence] has no
  /// such member and should not gain one: a sequence is always shaped before
  /// it is asked anything, and a dictionary is usually asked directly.
  int get count => collect(Collector.count());

  /// Whether the dictionary holds nothing.
  ///
  /// The same carve-out as [count] — `if (dict.empty)` is written constantly,
  /// and `if (dict.collect(.empty()))` is worse in a way the guardrail exists
  /// to refuse. There is no complement: `!dict.empty` already says the other
  /// thing.
  bool get empty => collect(Collector.empty());

  // --------------------------------------------------------------------------
  // Writing
  // --------------------------------------------------------------------------

  /// Stores [value] under [key].
  void set(K key, V value) => _entries[key] = value;

  /// Removes [key].
  void delete(K key) => _entries.remove(key);

  /// Removes every entry.
  void clear() => _entries.clear();

  /// The value under [key], creating it with [create] when it is absent.
  ///
  /// Dart's `putIfAbsent`, named for what it does rather than for when it
  /// does it.
  ///
  /// ```dart
  /// // setup: final counts = Dictionary<String, List<int>>();
  /// counts.ensure('a.com', () => <int>[]).add(1);
  /// ```
  V ensure(K key, V Function() create) => _entries.putIfAbsent(key, create);

  /// Replaces what is under [key] with [change] of it.
  ///
  /// [change] is handed `null` when the key is absent, so one callback covers
  /// both the first write and every one after it:
  ///
  /// ```dart
  /// // setup: final seen = Dictionary<String, int>();
  /// seen.update('a.com', (n) => (n ?? 0) + 1);
  /// ```
  void update(K key, V Function(V? current) change) =>
      _entries[key] = change(_entries[key]);

  /// Takes every entry of [other], overwriting on a shared key.
  void merge(Dictionary<K, V> other) => _entries.addAll(other._entries);

  // --------------------------------------------------------------------------
  // Crossing into the other collection
  // --------------------------------------------------------------------------

  /// The keys, in insertion order.
  Sequence<K> get keys => Sequence(_entries.keys.toList());

  /// The values, in insertion order.
  Sequence<V> get values => Sequence(_entries.values.toList());

  /// Every entry as a `(key, value)` record, in insertion order.
  ///
  /// Records rather than `MapEntry`, because `MapEntry` is a noun nobody
  /// wants:
  ///
  /// ```dart
  /// // setup: final spend = Dictionary<String, num>({'a.com': 1});
  /// spend.pairs.transform(.map((e) => '${e.$1}: ${e.$2}'));
  /// ```
  Sequence<(K, V)> get pairs => Sequence(_records);

  // --------------------------------------------------------------------------
  // The two doors
  // --------------------------------------------------------------------------

  /// This dictionary shaped by [step], over its `(key, value)` records.
  Dictionary<K2, V2> transform<K2, V2>(Transformer<(K, V), (K2, V2)> step) =>
      Dictionary.of(step.run(_records));

  /// This dictionary reduced by [step], over its `(key, value)` records.
  R collect<R>(Collector<(K, V), R> step) => step.run(_records);

  /// The entries as records, which is what both doors run over.
  List<(K, V)> get _records => [
    for (final entry in _entries.entries) (entry.key, entry.value),
  ];

  /// The entries as a map — a real snapshot, and the hand-off to anything
  /// typed `Map<K, V>`.
  ///
  /// The one word at the boundary, as `collect(.list())` is on a [Sequence].
  Map<K, V> get map => Map<K, V>.of(_entries);

  /// The map underneath, as it is written to JSON. See [map].
  Map<K, V> toJson() => map;

  @override
  String toString() {
    final shown = pairs.collect(
      .join(', ', limit: 4, of: (e) => '${e.$1}: ${e.$2}'),
    );
    return 'Dictionary($shown)';
  }
}

// ============================================================================
// THE WAY IN
// ============================================================================

/// Turns a map into a [Dictionary].
///
/// The seam at the edge of a script: a literal, a `dart:io` call or another
/// package becomes shapeable with one word, the way `.seq` does it for the
/// ordered collection.
extension Dictionaried<K, V> on Map<K, V> {
  /// This map as a [Dictionary], copied now.
  Dictionary<K, V> get dict => Dictionary<K, V>(this);
}

/// Typed keys, on the one shape that can carry them.
///
/// [Slot] needs the keys to be strings and the values to be whatever JSON
/// holds, so this cannot live on the generic class. It goes where
/// `NullableSequence` already goes — an extension narrowed to the shape it
/// needs.
///
/// ```dart
/// const cursor = Slot<int>('cursor');
///
/// final db = Dictionary<String, Object?>();
/// db.write(cursor, 120);
/// final int at = db.read(cursor) ?? 0;
/// ```
///
/// Named `read` and `write` rather than `get` and `set` so they do not collide
/// with the untyped members on the class — and because that pair says the
/// value is going through a codec, which is exactly what a [Slot] is.
extension Slotted on Dictionary<String, Object?> {
  /// The value [slot] names, or `null` when it is absent or the wrong shape.
  T? read<T>(Slot<T> slot) => slot.read(get(slot.name));

  /// Stores [value] under [slot]. It must survive `jsonEncode`.
  void write<T>(Slot<T> slot, T value) => set(slot.name, slot.write(value));

  /// Whether [slot] is present.
  bool holds(Slot<Object?> slot) => has(slot.name);

  /// Removes [slot].
  void drop(Slot<Object?> slot) => delete(slot.name);
}

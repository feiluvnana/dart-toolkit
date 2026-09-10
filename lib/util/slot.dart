/// # Typed Keys (`Slot`, `Meta`)
///
/// A typed key into a JSON-backed map, and the bag it opens. Used by a
/// crawl's `meta`, which rides through a resume file, and by `io.store`, which
/// *is* a JSON file — both need the map underneath to stay JSON, and neither
/// should make the reader cast it back.
library;

// ============================================================================
// TYPED KEYS (Slot, Meta)
// ============================================================================

/// A typed key into a JSON-backed map.
///
/// Declare one `const` and both ends are checked: writing takes a `T`, reading
/// hands one back, and neither site casts.
///
/// ```dart
/// // setup: final page = res;
/// const name  = Slot<String>('name');
/// const track = Slot<int>('track');
///
/// page.follow(href, tag: 'song', meta: [name('Hey Jude'), track(4)]);
///
/// final String? title = page.meta.get(name);
/// ```
///
/// The value has to survive `jsonEncode`, because a crawl's `meta` is written
/// to the resume file and a store is written to disk. For a type JSON does not
/// carry — a [Duration], an enum, a value class — use [Slot.coded] and say how
/// it converts.
final class Slot<T> {
  /// The key this slot reads and writes in the underlying map.
  final String name;

  final T? Function(Object? raw)? _read;
  final Object? Function(T value)? _write;

  /// Creates a slot for a JSON-native [T]: a string, number, bool, list or map.
  const Slot(this.name) : _read = null, _write = null;

  /// Creates a slot for a [T] that JSON does not carry.
  ///
  /// [read] converts what came out of the document, and returns `null` when it
  /// is not a value this slot understands. [write] converts back to something
  /// `jsonEncode` accepts. Both must be top-level or static functions for the
  /// slot to stay `const`.
  ///
  /// ```dart
  /// const since = Slot<DateTime>.coded('since', read: _readTime, write: _writeTime);
  ///
  /// DateTime? _readTime(Object? raw) =>
  ///     raw is String ? DateTime.tryParse(raw) : null;
  /// Object? _writeTime(DateTime value) => value.toIso8601String();
  /// ```
  const Slot.coded(
    this.name, {
    required T? Function(Object? raw) read,
    required Object? Function(T value) write,
  }) : _read = read,
       _write = write;

  /// The entry this slot writes for [value].
  ///
  /// Calling the slot is how a value reaches a `meta` list, so the write site
  /// is checked against [T]:
  ///
  /// ```dart
  /// // setup: final page = res;
  /// // setup: const name = Slot<String>('name');
  /// page.follow(href, meta: [name('Hey Jude'), track(4)]);
  /// ```
  MapEntry<String, Object?> call(T value) => MapEntry(name, write(value));

  /// Reads [raw] as [T], or `null` when it is absent or the wrong shape.
  ///
  /// A document that has moved on — a field that used to be a string and is
  /// now an object — reads as `null` rather than throwing, because the caller
  /// asked for a value and the honest answer is that there is not one.
  T? read(Object? raw) {
    final custom = _read;
    if (custom != null) return custom(raw);
    if (raw is T) return raw;
    // JSON does not distinguish 5 from 5.0, so a `Slot<double>` restored from
    // a document that happened to hold a whole number still reads.
    if (raw is num) {
      final asDouble = raw.toDouble();
      if (asDouble is T) return asDouble as T;
      final asInt = raw.toInt();
      if (asInt is T) return asInt as T;
    }
    return null;
  }

  /// Converts [value] to something `jsonEncode` accepts.
  Object? write(T value) {
    final custom = _write;
    return custom != null ? custom(value) : value;
  }

  @override
  String toString() => 'Slot<$T>($name)';
}

/// A JSON-backed bag of values, read and written through [Slot]s.
///
/// This is what a crawl carries as `Fetch.meta`: whatever a handler put in
/// survives the round trip to the response, and the resume file, without
/// anybody casting it back.
///
/// ```dart
/// // setup: final page = res;
/// const name = Slot<String>('name');
///
/// page.follow(href, tag: 'song', meta: [name(page.parse(format.html).text)]);
/// // later, in the 'song' handler:
/// final String? title = page.meta.get(name);
/// ```
final class Meta {
  /// The map underneath, as it is written to JSON.
  ///
  /// The escape hatch for keys another library owns, and for handing the whole
  /// bag to something that wants a plain map.
  final Map<String, Object?> raw;

  /// Creates a bag holding [entries].
  ///
  /// ```dart
  /// // setup: const name = Slot<String>('name');
  /// Meta([name('Hey Jude'), track(4)]);
  /// ```
  Meta([Iterable<MapEntry<String, Object?>> entries = const []])
    : raw = Map<String, Object?>.fromEntries(entries);

  /// Wraps [raw] directly, sharing it rather than copying.
  Meta.of(this.raw);

  /// The value [slot] names, or `null` when it is absent or the wrong shape.
  T? get<T>(Slot<T> slot) => slot.read(raw[slot.name]);

  /// Stores [value] under [slot].
  void set<T>(Slot<T> slot, T value) => raw[slot.name] = slot.write(value);

  /// Whether [slot] is present.
  bool has(Slot<Object?> slot) => raw.containsKey(slot.name);

  /// Removes [slot].
  void delete(Slot<Object?> slot) => raw.remove(slot.name);

  /// Every entry, for forwarding one bag into another.
  ///
  /// ```dart
  /// // setup: final page = res;
  /// page.follow(href, meta: [...page.meta.entries, track(2)]);
  /// ```
  Iterable<MapEntry<String, Object?>> get entries => raw.entries;

  /// The number of entries.
  int get length => raw.length;

  /// Whether the bag holds nothing.
  bool get isEmpty => raw.isEmpty;

  /// Whether the bag holds at least one entry.
  bool get isNotEmpty => raw.isNotEmpty;

  /// The map underneath. See [raw].
  Map<String, Object?> toJson() => raw;

  @override
  String toString() => 'Meta($raw)';
}

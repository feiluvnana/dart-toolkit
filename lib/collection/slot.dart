/// # Typed Keys (`Slot`)
///
/// A typed key into a JSON-backed [Dictionary]. Used by a crawl's `meta`,
/// which rides through a resume file, and by whatever a script keeps on disk
/// between runs — both need the map underneath to stay JSON, and neither
/// should make the reader cast it back.
///
/// The bag a slot opens is a `Dictionary<String, Object?>`, through the
/// `Slotted` extension. It used to be two private classes, `Meta` and `Store`,
/// nine identical members apiece.
library;

// ============================================================================
// TYPED KEYS (Slot)
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
/// final String? title = page.fetch.meta.read(name);
/// ```
///
/// The value has to survive `jsonEncode`, because a crawl's `meta` is written
/// to the resume file and a dictionary is written to disk. For a type JSON
/// does not carry — a [Duration], an enum, a value class — use [Slot.coded]
/// and say how it converts.
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

  /// The `(key, value)` pair this slot writes for [value].
  ///
  /// Calling the slot is how a value reaches a `meta` list, so the write site
  /// is checked against [T]:
  ///
  /// ```dart
  /// // setup: final page = res;
  /// // setup: const name = Slot<String>('name');
  /// // setup: const track = Slot<int>('track');
  /// page.follow(href, meta: [name('Hey Jude'), track(4)]);
  /// ```
  ///
  /// A record rather than a `MapEntry`, so it goes straight into a
  /// [Dictionary] and comes straight back out of `Dictionary.pairs`:
  ///
  /// ```dart
  /// // setup: final page = res;
  /// // setup: const track = Slot<int>('track');
  /// page.follow(
  ///   href,
  ///   meta: [...page.fetch.meta.pairs.collect(.list()), track(2)],
  /// );
  /// ```
  (String, Object?) call(T value) => (name, write(value));

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

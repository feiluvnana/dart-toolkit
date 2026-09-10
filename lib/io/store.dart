/// # Key-Value Storage (`io.store.*`)
///
/// A small JSON-backed map for the kind of state scripts need between runs:
/// cursors, cached tokens, "last seen" markers.
library;

import 'dart:convert';
import 'dart:io';

import '../src/fs.dart';
import '../util/slot.dart';

// ============================================================================
// LIGHTWEIGHT KEY-VALUE STORAGE (Store)
// ============================================================================

/// A JSON-backed key-value map.
///
/// Keys are [Slot]s, so a value goes in and comes back with its type and
/// neither end casts. A value the document no longer holds in that shape reads
/// as `null` rather than throwing:
///
/// ```dart
/// const cursor = Slot<int>('cursor');
///
/// final db = io.store.open('cache.json');
/// db.set(cursor, 120);
/// await db.save();
///
/// final int at = db.get(cursor) ?? 0;
/// ```
class Store {
  String? _path;
  final Map<String, Object?> _data = {};

  /// Opens a store backed by [path], loading it if the file exists.
  ///
  /// With no [path] the store is in-memory only and [save] throws.
  Store([this._path]) {
    if (_path != null && File(_path!).existsSync()) load();
  }

  /// Opens an independent store backed by [path].
  static Store open(String path) => Store(path);

  /// Points this store at [path], loading it if the file exists.
  Store attach(String path) {
    _path = path;
    if (File(path).existsSync()) load(path);
    return this;
  }

  /// The file backing this store, or `null` when it is in-memory only.
  String? get path => _path;

  /// The value [slot] names, or `null` when it is absent or the wrong shape.
  T? get<T>(Slot<T> slot) => slot.read(_data[slot.name]);

  /// Stores [value] under [slot]. It must survive `jsonEncode`.
  void set<T>(Slot<T> slot, T value) => _data[slot.name] = slot.write(value);

  /// Whether [slot] is present.
  bool has(Slot<Object?> slot) => _data.containsKey(slot.name);

  /// Removes [slot].
  void delete(Slot<Object?> slot) => _data.remove(slot.name);

  /// Removes every entry.
  void clear() => _data.clear();

  /// Reloads from [path], or from this store's own file when omitted.
  ///
  /// A missing, empty, unreadable, malformed or non-object document leaves the
  /// store untouched. A half-written file is exactly what an interrupted run
  /// leaves behind, and a store that throws from its own constructor would
  /// take the next run down with it.
  void load([String? path]) {
    final target = path ?? _path;
    if (target == null || !File(target).existsSync()) return;
    final Object? decoded;
    try {
      final text = File(target).readAsStringSync();
      if (text.trim().isEmpty) return;
      decoded = jsonDecode(text);
    } on FormatException {
      return;
    } on FileSystemException {
      return;
    }
    if (decoded is! Map) return;
    _data
      ..clear()
      ..addEntries(
        decoded.entries.map((e) => MapEntry(e.key.toString(), e.value)),
      );
  }

  /// Writes the store to [path], or to its own file when omitted.
  ///
  /// Throws [StateError] when neither is available. The write is atomic.
  Future<File> save([String? path]) {
    final target = path ?? _path;
    if (target == null) {
      throw StateError(
        'Store has no file to save to. Open it with io.store.open(path), '
        'or pass a path to save().',
      );
    }
    return Fs.dump(target, _data);
  }

  /// An unmodifiable view of every entry.
  Map<String, Object?> all() => Map.unmodifiable(_data);

  /// The number of entries.
  int get length => _data.length;

  /// Whether the store holds no entries.
  bool get isEmpty => _data.isEmpty;

  /// Whether the store holds at least one entry.
  bool get isNotEmpty => _data.isNotEmpty;
}

/// Entry point for key-value storage, reachable as `io.store`.
///
/// Inherits from the shared process-wide [Store]. Point it at a file
/// with [attach] if you want that shared state to persist — [attach] returns
/// the [Store] itself — or use [open] for an independent store.
class StoreAccessor extends Store {
  /// Creates the accessor. Prefer the shared `io.store` instance.
  StoreAccessor() : super();

  /// Opens an independent store backed by [path].
  Store open(String path) => Store(path);
}

/// # Key-Value Storage (`io.store.*`)
///
/// A small JSON-backed map for the kind of state scripts need between runs:
/// cursors, cached tokens, "last seen" markers.
library;

import 'dart:convert';
import 'dart:io';

import '../src/fs.dart';

// ============================================================================
// LIGHTWEIGHT KEY-VALUE STORAGE (Store)
// ============================================================================

/// A JSON-backed key-value map.
///
/// Values must be JSON-encodable. Reads are typed through [get]; a value of
/// the wrong type yields the fallback rather than throwing:
///
/// ```dart
/// final db = io.store.open('cache.json');
/// db.set('cursor', 120);
/// await db.save();
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

  /// Reads [key] as [T], returning [fallback] when absent or mistyped.
  T? get<T>(String key, [T? fallback]) {
    final value = _data[key];
    return value is T ? value : fallback;
  }

  /// Stores [value] under [key]. [value] must be JSON-encodable.
  void set(String key, Object? value) => _data[key] = value;

  /// Whether [key] is present.
  bool has(String key) => _data.containsKey(key);

  /// Removes [key].
  void delete(String key) => _data.remove(key);

  /// Removes every entry.
  void clear() => _data.clear();

  /// Reloads from [path], or from this store's own file when omitted.
  ///
  /// A missing, empty, or non-object document leaves the store untouched.
  void load([String? path]) {
    final target = path ?? _path;
    if (target == null || !File(target).existsSync()) return;
    final text = File(target).readAsStringSync();
    if (text.trim().isEmpty) return;
    final decoded = jsonDecode(text);
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

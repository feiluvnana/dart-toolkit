import 'dart:convert';
import 'dart:io';

import 'file.dart';

// ============================================================================
// LIGHTWEIGHT KEY-VALUE STORAGE SUBSYSTEM (store.* / Store)
// ============================================================================

/// Top-level persistent key-value storage accessor.
///
/// Provides strictly 1-word methods for managing local persistent JSON state:
/// ```dart
/// // Open a persistent store file
/// final db = store.open('.cache.json');
/// db.set('last_run', DateTime.now().toIso8601String());
/// db.set('count', db.get('count', 0) + 1);
/// await db.save();
///
/// // Or use the default shared store
/// store.set('token', 'xyz');
/// print(store.get('token'));
/// ```
/// Persistent key-value store backed by a local JSON file.
class Store {
  final File? _file;
  final Map<String, Object?> _data = {};

  /// Creates a [Store] optionally bound to [filePath].
  Store([Object? filePath])
    : _file = filePath != null
          ? (filePath is File ? filePath : File(filePath.toString()))
          : null {
    if (_file != null && _file.existsSync()) {
      load();
    }
  }

  /// Retrieves a value for [key] cast to [T] with an optional [fallback] (1-word).
  T? get<T>(String key, [T? fallback]) {
    final val = _data[key];
    if (val == null) return fallback;
    if (val is T) return val as T;
    return fallback;
  }

  /// Retrieves a string value for [key] with an optional [fallback] (1-word).
  String? str(String key, [String? fallback]) => get<String>(key, fallback);

  /// Sets a value for [key] (1-word).
  void set(String key, Object? value) {
    _data[key] = value;
  }

  /// Checks whether [key] exists in the store (1-word).
  bool has(String key) => _data.containsKey(key);

  /// Removes [key] from the store (1-word).
  void delete(String key) {
    _data.remove(key);
  }

  /// Clears all keys and values from the store (1-word).
  void clear() {
    _data.clear();
  }

  /// Reloads data from the backing JSON file (1-word).
  void load([Object? filePath]) {
    final target = filePath != null
        ? (filePath is File ? filePath : File(filePath.toString()))
        : _file;
    if (target != null && target.existsSync()) {
      final text = target.readAsStringSync();
      if (text.trim().isNotEmpty) {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          _data.clear();
          for (final entry in decoded.entries) {
            _data[entry.key.toString()] = entry.value as Object?;
          }
        }
      }
    }
  }

  /// Atomically writes store data to the backing JSON file (1-word).
  Future<File> save([Object? filePath]) {
    final target = filePath != null
        ? (filePath is File ? filePath : File(filePath.toString()))
        : _file;
    if (target == null) {
      throw StateError('Cannot save Store without a target file path');
    }
    final content = const JsonEncoder.withIndent('  ').convert(_data);
    return Fs.write(target, content);
  }

  /// Returns an unmodifiable snapshot of the stored data (1-word).
  Map<String, Object?> map() => Map.unmodifiable(_data);

  /// Number of entries currently stored.
  int get length => _data.length;

  /// Whether the store contains no entries.
  bool get isEmpty => _data.isEmpty;

  /// Whether the store contains entries.
  bool get isNotEmpty => _data.isNotEmpty;
}

/// Store accessor providing an open factory and a default global in-memory store.
class StoreAccessor {
  final Store _defaultStore = Store();

  /// Creates a [StoreAccessor].
  StoreAccessor();

  /// Opens or loads a persistent [Store] file at [filePath] (1-word).
  Store open(Object filePath) => Store(filePath);

  /// Retrieves a value from the default store (1-word).
  T? get<T>(String key, [T? fallback]) => _defaultStore.get<T>(key, fallback);

  /// Retrieves a string value from the default store (1-word).
  String? str(String key, [String? fallback]) => _defaultStore.str(key, fallback);

  /// Sets a value in the default store (1-word).
  void set(String key, Object? value) => _defaultStore.set(key, value);

  /// Checks whether [key] exists in the default store (1-word).
  bool has(String key) => _defaultStore.has(key);

  /// Removes [key] from the default store (1-word).
  void delete(String key) => _defaultStore.delete(key);

  /// Clears all entries from the default store (1-word).
  void clear() => _defaultStore.clear();

  /// Returns an unmodifiable snapshot map of the default store (1-word).
  Map<String, Object?> map() => _defaultStore.map();
}

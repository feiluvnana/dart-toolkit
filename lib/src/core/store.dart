part of '../core.dart';

/// A folder that work keeps its memory in between runs: a pool's unfinished jobs, a crawl's
/// frontier, cookies, a browser profile, your own "already done" list. It is the one way to
/// persist anything that is not a result.
///
/// Everything that remembers takes `store:`; `/` gives a sub-store, one folder per feature.
/// Your own state is a typed [Key].
///
/// ```dart
/// final app = Store.app('books');
/// const seen = Key<List<String>>('seen', or: []);
/// final ids = await app.read(seen);                    // `or` until it is first written
/// await app.update(seen, (ids) => [...ids, book.id]);  // under the store's lock
/// await (app / 'crawl').clear();                       // forget: the one way to start over
/// ```
///
/// Every write is atomic, and the lock keeps two runs of one program from writing at once. The
/// default everywhere is [Store.memory]: nothing touches the disk unless you pass a folder.
///
/// {@category Utilities}
final class Store {
  /// The folder, or `null` for a store in memory.
  final String? folder;

  final _Memory? _memory;
  final String _prefix;

  /// A store in [folder], made on first write.
  Store(String this.folder) : _memory = null, _prefix = '';

  /// A store that keeps everything in this process, for its life: the default, and the test
  /// seam. Each call is a store of its own.
  Store.memory() : folder = null, _memory = _Memory(), _prefix = '';

  Store._sub(this.folder, this._memory, this._prefix);

  /// The operating system's place for [name]'s data: `~/Library/Application Support/<name>` on
  /// macOS, `%APPDATA%\<name>` on Windows, `$XDG_DATA_HOME/<name>` (or `~/.local/share/<name>`)
  /// on Linux. `DART_TOOLKIT_STORE=<folder>` moves every one under that folder.
  factory Store.app(String name) {
    if (name.isEmpty || name.contains('/') || name.contains(r'\')) {
      throw ArgumentError.value(name, 'name', 'Invalid store name, expected one folder name');
    }
    if (Env.get<String?>('DART_TOOLKIT_STORE') case final root?) return Store(_join(root, name));
    final home = Env.get<String?>('HOME') ?? Env.get<String?>('USERPROFILE');
    final String base;
    if (Platform.isWindows) {
      base = Env.get<String?>('APPDATA') ?? _join(home ?? '.', r'AppData\Roaming');
    } else if (Platform.isMacOS) {
      base = _join(home ?? '.', 'Library/Application Support');
    } else {
      base = Env.get<String?>('XDG_DATA_HOME') ?? _join(home ?? '.', '.local/share');
    }
    return Store(_join(base, name));
  }

  /// The sub-store [name]: a folder of its own, or its own part of the memory.
  Store operator /(String name) {
    if (name.isEmpty || name == '.' || name == '..' || name.contains('/') || name.contains(r'\')) {
      throw ArgumentError.value(name, 'name', 'Invalid sub-store name, expected one folder name');
    }
    final into = folder;
    return into != null ? Store(_join(into, name)) : Store._sub(null, _memory, '$_prefix$name/');
  }

  /// Whether nothing of it is kept on disk.
  bool get isMemory => folder == null;

  /// [key]'s value, or its `or` until it is first written.
  Future<T> read<T>(Key<T> key) async {
    final encoded = await _readRaw(key.name);
    if (encoded == null) return key.or;
    return key._decode(encoded, this);
  }

  /// Writes [value] as [key]'s, atomically: a crash keeps the old value.
  Future<void> write<T>(Key<T> key, T value) => lock(() => _write(key, value));

  /// [key]'s value replaced by what [change] makes of it, holding the lock across the read and
  /// the write, so two runs never lose each other's change. Returns the new value.
  Future<T> update<T>(Key<T> key, FutureOr<T> Function(T value) change) => lock(() async {
    final next = await change(await read(key));
    await _write(key, next);
    return next;
  });

  /// Forgets everything in it, sub-stores included: how anything starts over.
  Future<void> clear() async {
    // A store never written has nothing to forget, and gets no folder for it.
    if (folder case final folder? when !await Directory(folder).exists()) return;
    return lock(() async {
      if (_memory case final memory?) {
        memory.values.removeWhere((name, _) => name.startsWith(_prefix));
        return;
      }
      await for (final entry in Directory(folder!).list(followLinks: false)) {
        if (entry.path.endsWith('${Platform.pathSeparator}.lock')) continue;
        await entry.delete(recursive: true);
      }
    });
  }

  /// Runs [body] holding this store's lock: other runs of the program, and other calls here,
  /// wait. A folder's lock is a file in it, so it holds across processes. A sub-store has a lock
  /// of its own, and work inside [body] already holds this one: a write inside [update] or
  /// [lock] goes ahead.
  Future<R> lock<R>(FutureOr<R> Function() body) async {
    final Object id = folder ?? (_memory!, _prefix);
    final held = Zone.current[_heldKey] as Set<Object>?;
    if (held != null && held.contains(id)) return await body();
    Future<R> holding() => runZoned(
      () async => await body(),
      zoneValues: {
        _heldKey: {...?held, id},
      },
    );
    final previous = _locks[id];
    final mine = Completer<void>();
    _locks[id] = mine.future;
    try {
      await previous;
      if (folder == null) return await holding();
      await Directory(folder!).create(recursive: true);
      final file = await File(_join(folder!, '.lock')).open(mode: FileMode.append);
      try {
        await file.lock(FileLock.blockingExclusive);
        return await holding();
      } finally {
        await file.close();
      }
    } finally {
      if (identical(_locks[id], mine.future)) _locks.remove(id);
      mine.complete();
    }
  }

  Future<void> _write<T>(Key<T> key, T value) async {
    final encoded = key._encode(value, this);
    final text = jsonEncode({'version': _version, 'value': encoded});
    if (_memory case final memory?) {
      memory.values['$_prefix${key.name}'] = text;
      return;
    }
    await Directory(folder!).create(recursive: true);
    await FileBridge.write(_join(folder!, '${key.name}.json'), utf8.encode(text));
  }

  Future<Object?> _readRaw(String name) async {
    final String text;
    if (_memory case final memory?) {
      final kept = memory.values['$_prefix$name'];
      if (kept == null) return null;
      text = kept;
    } else {
      final file = File(_join(folder!, '$name.json'));
      if (!await file.exists()) return null;
      text = await file.readAsString();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw FormatException('Invalid store in $this, key $name: ${e.message}');
    }
    if (decoded is! Map || decoded['version'] != _version || !decoded.containsKey('value')) {
      final version = decoded is Map ? decoded['version'] : null;
      throw FormatException('Invalid store in $this, key $name: version $version, expected $_version');
    }
    return _Encoded(decoded['value']);
  }

  /// What a store writes inside, as this version of the library writes it.
  static const _version = 1;

  static final _locks = <Object, Future<void>>{};

  /// The locks the work in a zone holds.
  static const _heldKey = #dartToolkitStoreLocks;

  static String _join(String a, String b) =>
      a.endsWith('/') || a.endsWith(Platform.pathSeparator) ? '$a$b' : '$a${Platform.pathSeparator}$b';

  @override
  bool operator ==(Object other) =>
      other is Store && other.folder == folder && identical(other._memory, _memory) && other._prefix == _prefix;

  @override
  int get hashCode => Object.hash(folder, _memory, _prefix);

  @override
  String toString() => folder ?? 'memory${_prefix.isEmpty ? '' : ':$_prefix'}';
}

final class _Memory {
  final values = <String, String>{};
}

/// A value read back from a store, before its key decodes it.
final class _Encoded {
  final Object? json;
  const _Encoded(this.json);
}

/// A typed name in a [Store]: [name] holds a [T], [or] until it is first written.
///
/// A key without [as] holds JSON-ready values: `null`, `bool`, numbers, `String`, `Path`, and
/// lists, sets and string-keyed maps of those; any other type names its [Serializer]. The first
/// write checks by a round trip, and a type that cannot make it is an [ArgumentError] naming the
/// key.
///
/// ```dart
/// const seen = Key<List<String>>('seen', or: []);
/// const last = Key<Book?>('last', or: null, as: Book.serializer);
/// ```
///
/// {@category Utilities}
final class Key<T> {
  final String name;
  final T or;
  final Serializer<T>? as;

  const Key(this.name, {required this.or, this.as});

  Object? _encode(T value, Store store) {
    _checkName();
    if (as case final serializer?) return serializer.encode(value);
    final json = _jsonReady(value);
    // The first write proves the type comes back, before anything depends on it.
    if (!_checked.contains(this)) {
      try {
        _cast(jsonDecode(jsonEncode(json)));
      } catch (_) {
        throw ArgumentError.value(
          name,
          'key',
          'Invalid key $name: a ${value.runtimeType} does not come back from JSON as a $T; give it `as:` a Serializer',
        );
      }
      _checked.add(this);
    }
    return json;
  }

  T _decode(Object? stored, Store store) {
    final json = (stored as _Encoded).json;
    if (as case final serializer?) {
      try {
        return serializer.decode(json);
      } on FormatException {
        rethrow;
      } catch (e) {
        throw FormatException('Invalid store in $store, key $name: $e');
      }
    }
    try {
      return _cast(json);
    } catch (_) {
      throw FormatException('Invalid store in $store, key $name: ${json.runtimeType}, expected $T');
    }
  }

  void _checkName() {
    if (name.isEmpty || name.startsWith('.') || name.contains(_unsafe)) {
      throw ArgumentError.value(name, 'name', 'Invalid key name, expected a plain file name');
    }
  }

  /// [json] as a [T]: as it is when it already is one, else rebuilt as the typed list, set or
  /// map [T] names.
  T _cast(Object? json) {
    if (json is T) return json;
    // Whether T is an S (or an S?, which covers both).
    bool names<S>() => <T>[] is List<S>;
    if (json is List) {
      if (names<List<String>?>()) return List<String>.from(json) as T;
      if (names<List<int>?>()) return List<int>.from(json) as T;
      if (names<List<double>?>()) return [for (final n in json) (n as num).toDouble()] as T;
      if (names<List<num>?>()) return List<num>.from(json) as T;
      if (names<List<bool>?>()) return List<bool>.from(json) as T;
      if (names<Set<String>?>()) return Set<String>.from(json) as T;
      if (names<Set<int>?>()) return Set<int>.from(json) as T;
      if (names<List<Map<String, Object?>>?>()) return [for (final m in json) Map<String, Object?>.from(m as Map)] as T;
    }
    if (json is Map) {
      if (names<Map<String, String>?>()) return Map<String, String>.from(json) as T;
      if (names<Map<String, int>?>()) return Map<String, int>.from(json) as T;
      if (names<Map<String, num>?>()) return Map<String, num>.from(json) as T;
      if (names<Map<String, bool>?>()) return Map<String, bool>.from(json) as T;
      // Before `Map<String, Object?>`, which every string-keyed map is.
      if (names<Map<String, List<String>>?>()) {
        return {for (final MapEntry(:key, :value) in json.entries) key as String: List<String>.from(value as List)}
            as T;
      }
      if (names<Map<String, Object?>?>()) return Map<String, Object?>.from(json) as T;
    }
    if (json is num && names<double?>()) return json.toDouble() as T;
    return json as T;
  }

  static final _unsafe = RegExp(r'[/\\:*?"<>|]');

  /// Keys whose type has made the round trip once.
  static final _checked = <Key<Object?>>{};

  @override
  bool operator ==(Object other) => other is Key && other.name == name && other.runtimeType == runtimeType;

  @override
  int get hashCode => Object.hash(name, runtimeType);

  @override
  String toString() => 'Key<$T>($name)';
}

/// [value] as plain JSON: sets become lists; anything JSON cannot hold is an [ArgumentError].
Object? _jsonReady(Object? value) => switch (value) {
  null || bool() || num() || String() => value,
  Set() => [for (final v in value) _jsonReady(v)],
  List() => [for (final v in value) _jsonReady(v)],
  Map() when value.keys.every((k) => k is String) => {
    for (final MapEntry(:key, :value) in value.entries) key as String: _jsonReady(value),
  },
  _ => throw ArgumentError.value(
    value,
    'value',
    'Invalid value: a ${value.runtimeType} is not JSON-ready; give the key `as:` a Serializer',
  ),
};

/// The one codec in the library: a [T] to a JSON-ready value, and back. Keys, detached jobs and
/// crawl metadata use it.
///
/// ```dart
/// static final serializer = Serializer<Book>(
///   encode: (b) => b.toJson(),
///   decode: (j) => Book.fromJson(j as Map<String, Object?>),
/// );
/// ```
///
/// {@category Utilities}
final class Serializer<T> {
  final Object? Function(T value) encode;
  final T Function(Object? json) decode;

  const Serializer({required this.encode, required this.decode});

  /// Whether [value] makes the round trip: what a pool checks when it starts.
  bool check(T value) {
    try {
      decode(jsonDecode(jsonEncode(_jsonReady(encode(value)))));
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Not API: what features need from a [Store] to keep their own files in it.
abstract final class StoreInternals {
  /// The memory a memory store keeps [name] in: features that keep more than keys write text
  /// there.
  static Map<String, String>? memory(Store store) => store._memory?.values;

  /// The prefix a memory sub-store's names carry.
  static String prefix(Store store) => store._prefix;
}

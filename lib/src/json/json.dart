// ignore_for_file: avoid_annotating_with_dynamic, avoid_dynamic_calls
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// High-performance, dead-simple JSON parsing, serialization and safe navigation.
///
/// ```dart
/// final data = Json.parse('{"server": {"host": "localhost"}}');
/// final host = data.get('server.host', '0.0.0.0');
/// final text = Json.dump(data, pretty: true);
/// final config = await Json.read('config.json');
/// await Json.write('config.json', config);
/// ```
abstract final class Json {
  /// Parses [src] into a [JsonMap], [JsonList] or scalar.
  static dynamic parse(String src) => _wrap(jsonDecode(src));

  /// Serialises [val] to JSON; [pretty] indents with two spaces.
  static String dump(Object? val, {bool pretty = false}) {
    final raw = _unwrap(val);
    return pretty ? const JsonEncoder.withIndent('  ').convert(raw) : jsonEncode(raw);
  }

  /// Reads and parses the JSON file at [src] (a path `String`).
  static Future<dynamic> read(Object src) async => parse(await _read(src));

  /// Writes [val] as JSON to [dst] (a path `String`).
  static Future<void> write(Object dst, Object? val, {bool pretty = false}) async {
    final path = dst is String ? dst : dst.toString();
    await File(path).writeAsString(dump(val, pretty: pretty));
  }

  /// Safe nested lookup from [target]: `Json.get(data, 'server.ports.0', 80)`.
  static T? get<T>(Object? target, String path, [T? fallback]) => _safeGet<T>(target, path, fallback);

  static Future<String> _read(Object src) {
    if (src is String) return File(src).readAsString();
    if (src is File) return src.readAsString();
    throw ArgumentError.value(src, 'src', 'Must be a path String or File');
  }
}

dynamic _wrap(dynamic val) {
  if (val is Map) return JsonMap(Map<String, dynamic>.from(val));
  if (val is List) return JsonList(val);
  return val;
}

dynamic _unwrap(dynamic val) {
  if (val is JsonMap) return val._inner;
  if (val is JsonList) return val._inner;
  return val;
}

/// A JSON object wrapper giving instance [get] for safe dot-path traversal.
final class JsonMap with MapMixin<String, dynamic> {
  final Map<String, dynamic> _inner;

  JsonMap(this._inner);

  @override
  dynamic operator [](Object? key) => _wrap(_inner[key]);

  @override
  void operator []=(String key, dynamic value) => _inner[key] = _unwrap(value);

  @override
  void clear() => _inner.clear();

  @override
  Iterable<String> get keys => _inner.keys;

  @override
  dynamic remove(Object? key) => _inner.remove(key);

  /// Safely extracts a nested value by dot notation (`'server.host'`).
  T? get<T>(String path, [T? fallback]) => _safeGet<T>(this, path, fallback);

  /// A plain [Map] view.
  Map<String, dynamic> toMap() => Map<String, dynamic>.from(_inner);

  @override
  String toString() => _inner.toString();
}

/// A JSON array wrapper giving instance [get] for safe dot-path traversal.
final class JsonList with ListMixin<dynamic> {
  final List<dynamic> _inner;

  JsonList(this._inner);

  @override
  int get length => _inner.length;

  @override
  set length(int newLength) => _inner.length = newLength;

  @override
  dynamic operator [](int index) => _wrap(_inner[index]);

  @override
  void operator []=(int index, dynamic value) => _inner[index] = _unwrap(value);

  /// Safely extracts a nested value by dot notation (`'ports.0'`).
  T? get<T>(String path, [T? fallback]) => _safeGet<T>(this, path, fallback);

  /// A plain [List] view.
  List<dynamic> asList() => List<dynamic>.from(_inner);

  @override
  String toString() => _inner.toString();
}

T? _safeGet<T>(Object? target, String path, [T? fallback]) {
  if (target == null) return fallback;
  dynamic current = target;
  for (final part in path.split('.')) {
    if (current is Map) {
      if (!current.containsKey(part)) return fallback;
      current = current[part];
    } else if (current is List) {
      final idx = int.tryParse(part);
      if (idx == null || idx < 0 || idx >= current.length) return fallback;
      current = current[idx];
    } else {
      return fallback;
    }
  }
  if (current is T) return current;
  return fallback;
}

/// Safe path lookup on anything: `data.get('server.host', 'localhost')`.
extension JsonGet on Object? {
  /// Extracts a nested value by dot notation, returning [fallback] when absent or mistyped.
  T? get<T>(String path, [T? fallback]) => _safeGet<T>(this, path, fallback);
}

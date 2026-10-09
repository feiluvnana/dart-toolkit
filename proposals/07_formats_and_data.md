# Module Proposal 07: Data Formats & Serialization (`lib/json.dart`, `lib/xml.dart`, `lib/xpath.dart`, `lib/src/formats/*`)

## 1. Overview & Vision

The Formats module provides high-speed parsing, querying, and serialization for JSON, YAML, TOML, XML, and Torrent/Bencode formats, including JSONPath and XPath evaluation engines.

### Core Problems in the Existing API
1. **Divergent Parser Names**: JSON uses `jsonDecode()`, YAML uses `Yaml.decode()`, TOML uses `Toml.decode()`, and XML uses `Xml.parse()`.
2. **Runtime `TypeError` on Deep Navigation**: Accessing nested dynamic maps (`data['server']['network']['port']`) crashes with `TypeError: null is not a subtype of Map` if any parent key is missing.
3. **Verbose Serialization**: Converting objects back to formatted strings requires importing different converters and memorizing their specific indent arguments.

---

## 2. Detailed Before vs After Comparison

### 2.1 Symmetrical Format Decoding & Encoding

#### Before:
```dart
import 'dart:convert';
import 'package:dart_toolkit/src/formats/yaml.dart';
import 'package:dart_toolkit/src/formats/toml.dart';
import 'package:dart_toolkit/src/formats/xml/xml.dart';

// Decoding
final j = jsonDecode(jsonStr);
final y = Yaml.decode(yamlStr);
final t = Toml.decode(tomlStr);
final x = Xml.parse(xmlStr);

// Encoding
final jOut = const JsonEncoder.withIndent('  ').convert(data);
final yOut = Yaml.encode(data);
final tOut = Toml.encode(data);
```

#### After (Proposed):
```dart
// 1. Unified parsing extensions on String
final j = jsonStr.parseJson<Map<String, dynamic>>();
final y = yamlStr.parseYaml<Map<String, dynamic>>();
final t = tomlStr.parseToml<Map<String, dynamic>>();
final x = xmlStr.parseXml();

// 2. Unified serialization extensions on Object
final jOut = data.toJson(pretty: true);
final yOut = data.toYaml();
final tOut = data.toToml();
final xOut = xmlDoc.toXmlString(pretty: true);
```

---

### 2.2 Null-Safe Dynamic Path Navigation (`JsonDoc`)

#### Before:
```dart
final data = jsonDecode(jsonStr) as Map<String, dynamic>;
final port = (data['server'] as Map<String, dynamic>?)?['port'] as int? ?? 8080;
final city = ((data['user'] as Map<String, dynamic>?)?['address'] as Map<String, dynamic>?)?['city'] as String? ?? 'Unknown';
```

#### After (Proposed):
```dart
final doc = jsonStr.parseJsonDoc();

// Fluent null-forgiving path queries
final port    = doc.int('server.port', def: 8080);
final city    = doc.str('user.address.city', def: 'Unknown');
final tags    = doc.list<String>('metadata.tags');
final enabled = doc.bool('features.auth.enabled', def: true);
```

---

### 2.3 JSONPath & XPath Evaluation

#### Before:
```dart
final path = JsonPath(r'$.store.book[*].author');
final authors = path.read(json).map((m) => m.value).toList();
```

#### After (Proposed):
```dart
// 1. Direct JsonPath querying on string or map
final authors = jsonStr.queryJson(r'$.store.book[*].author');
final cheapBooks = doc.query(r'$.store.book[?(@.price < 10)]');

// 2. Direct XPath querying on XML
final titles = xmlStr.queryXml('//book/title/text()').values;
```

---

## 3. What is Better vs Old API

| Feature | Old API | Proposed New API | Impact |
|---|---|---|---|
| **Format Consistency** | Inconsistent class names & functions | Symmetrical `.parseJson()`, `.parseYaml()`, `.parseToml()` | Zero cognitive friction |
| **Deep Map Access** | Verbose cascading null checks | `doc.str('a.b.c')`, `doc.int('a.b.port')` | Crash-free dynamic navigation |
| **JsonPath / XPath** | Multi-class setup | Direct `.queryJson(...)` and `.queryXml(...)` | 1-line query execution |

---

## 4. Trade-Offs & Backward Compatibility

### Trade-Offs:
- `JsonDoc` wraps the underlying `Map<String, dynamic>` to provide dot-notated queries.
  - *Mitigation*: The underlying raw map is accessible at any time via `doc.raw`.

### Backward Compatibility:
- 100% backward compatible. All existing `Json`, `Yaml`, `Toml`, `Xml`, `Bencode`, `Torrent`, and `JsonPath` classes continue to function.

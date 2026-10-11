# 04: JSON

High-performance, dead-simple JSON parsing, serialization, and streaming.

---

## 1. Parse & Dump

```dart
// Parse string to map/list
final data = Json.parse('{"id": 1, "name": "App"}');

// Dump object to string
final str = Json.dump(data);
final pretty = Json.dump(data, pretty: true);
```

---

## 2. Safe Dynamic Navigation (`get`)

Extract nested values safely without runtime cast errors or null assertions:

```dart
final json = Json.parse('''{
  "server": {
    "host": "localhost",
    "ports": [8080, 8443]
  }
}''');

// Safe nested lookup with default values
final host  = json.get('server.host', '0.0.0.0'); // 'localhost'
final port  = json.get('server.ports.0', 80);      // 8080
final cert  = json.get('server.ssl.cert');         // null
```

---

## 3. Direct File I/O

```dart
// Read & write JSON directly
final config = await Json.read('config.json');
config['version'] = '2.0.0';
await Json.write('config.json', config);
```

---

## 4. Advanced Use Cases

### 4.1 Streaming Multi-Gigabyte JSONL (JSON Lines)
Process massive datasets line-by-line with constant memory footprint:

```dart
// Stream JSON lines directly from disk
var activeCount = 0;
await for (final line in File('users.jsonl').lines()) {
  final user = Json.parse(line);
  if (user.get('active', false)) {
    activeCount++;
  }
}
print('Active users: $activeCount');
```

### 4.2 Stream JSONL over HTTP directly to Disk
```dart
// Download telemetry JSON lines stream and filter in realtime
final resp = await Http.get('https://api.site.com/events.jsonl');
final target = File('filtered.jsonl');

await for (final line in resp.lines()) {
  final event = Json.parse(line);
  if (event.get('severity') == 'critical') {
    await target.write('$line\n', append: true);
  }
}
```

# 03: HTTP & Networking

Dead-simple HTTP requests, streaming, and pipeline integration.

---

## 1. Quick Requests

```dart
// GET text, JSON, or parsed HTML directly
final text = await Http.get('https://api.site.com/status').text();
final data = await Http.get('https://api.site.com/users').json();
final doc  = await Http.get('https://news.ycombinator.com').html();

// POST JSON body
final resp = await Http.post(
  'https://api.site.com/login',
  body: {'user': 'alice', 'pass': 'secret'},
);

if (resp.ok) {
  print(resp.status); // 200
}
```

---

## 2. Response (`Resp`)

`Resp` implements `Reader` for zero-allocation streaming.

```dart
final resp = await Http.get('https://example.com/asset.zip');

print(resp.status); // 200
print(resp.ok);     // true

final bytes = await resp.bytes();
final text  = await resp.text();
final json  = await resp.json();
final doc   = await resp.html();
```

---

## 3. Streaming & Direct Piping

```dart
// Stream response directly to disk without memory overhead
await Http.get('https://example.com/huge.iso').pipe(File('huge.iso'));

// Pipe HTTP stream straight into an archive unpacker
await Http.get('https://example.com/build.tar.gz').pipe(Archive.unpack(dst: 'dist'));
```

---

## 4. Advanced Use Cases

### 4.1 Resumable Partial Download
Resume interrupted multi-gigabyte downloads using HTTP `Range` headers:

```dart
Future<void> resumeDownload(String url, File target) async {
  final currentSize = (await target.exists) ? await target.size : 0;

  final resp = await Http.get(
    url,
    headers: {'Range': 'bytes=$currentSize-'},
  );

  // Append new incoming bytes to existing file
  await resp.pipe(target.writer(append: true));
}
```

### 4.2 Stream File Upload (Zero-Buffer POST)
Upload a multi-gigabyte file without loading it entirely into RAM:

```dart
final file = File('video.mp4');

// Stream file directly as request body
final resp = await Http.post(
  'https://upload.site.com/videos',
  body: file, // File implements Reader, streams directly
);
```

### 4.3 Automatic Retries & Sane Timeouts
```dart
final data = await Http.get(
  'https://flakey-api.com/data',
  retry: 3, // automatically retries on 5xx or network errors
  timeout: const Duration(seconds: 10),
).json();
```

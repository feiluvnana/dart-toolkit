# 09: CLI & Terminal

Dead-simple terminal styling, prompts, and progress bars.

---

## 1. Colored Output

```dart
Cli.print('Done!'.green);
Cli.print('Warning!'.yellow);
Cli.print('Error!'.red.bold);
```

---

## 2. Interactive Prompts (`ask`)

```dart
// Text input
final name = Cli.ask('Your name?');

// Confirmation (y/n)
final ok = Cli.confirm('Proceed?');

// Select from options
final choice = Cli.choose('Select target:', ['dev', 'stage', 'prod']);
```

---

## 3. Progress Bar & Spinner

```dart
// Determinate Progress Bar
final bar = Cli.bar(total: 100);
for (var i = 0; i <= 100; i++) {
  bar.set(i);
  await Future.delayed(const Duration(milliseconds: 10));
}
bar.done();

// Indeterminate Spinner
await Cli.spin('Syncing data...', () async {
  await Future.delayed(const Duration(seconds: 2));
});
```

---

## 4. Advanced Use Cases

### 4.1 Multi-Download Progress Tracking
Display multiple live progress bars for concurrent background downloads:

```dart
void downloadAll(List<String> urls) async {
  final bars = [for (final url in urls) Cli.bar(total: 100, label: url)];
  final pool = Pool(4);

  for (var i = 0; i < urls.length; i++) {
    final idx = i;
    pool.run(() async {
      await Http.get(urls[idx]).pipe(
        File('file_$idx.bin'),
        onProgress: (p) => bars[idx].set(p),
      );
      bars[idx].done();
    });
  }

  await pool.wait();
  Cli.print('All downloads complete!'.green);
}
```

### 4.2 Stream Pipeline with Live Bandwidth Monitor
```dart
final bar = Cli.bar(total: totalBytes, unit: 'MB');

await Http.get(url).pipe(
  File('movie.mp4'),
  onProgress: (bytes) {
    bar.set(bytes); // automatically prints speed (e.g. "14.2 MB/s")
  },
);
bar.done();
```

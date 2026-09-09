# `zip` — archives

Pack a folder, unpack an archive, look inside one without unpacking it, and
squeeze bytes. The format comes from the file name, so one pair of calls covers
every archive a script meets.

| Extension | Format |
| :--- | :--- |
| `.zip` | `Format.zip` (the default) |
| `.tar` | `Format.tar` |
| `.tar.gz`, `.tgz` | `Format.gz` |
| `.tar.bz2`, `.tbz` | `Format.bz2` |

Pass `format:` to override the guess.

---

## 1. Packing

```dart
await zip.pack('site', 'site.zip');        // a whole folder
await zip.pack('notes.txt', 'notes.zip');  // a single file
await zip.pack('site', 'site.tar.gz');     // format from the name
```

Paths inside the archive are relative to the source, so unpacking recreates the
tree without the leading directories. The write is atomic, like every other
write in this library.

To build an archive from data that never touched the disk:

```dart
await zip.bundle('out.zip', {
  'notes.txt': utf8.encode('hello'),
  'data/rows.csv': csvBytes,
});
```

---

## 2. Unpacking

```dart
final files = await zip.unpack('site.zip', 'restored');
print('wrote ${files.length} files');
```

Entries that would escape the destination — a `..` segment or an absolute path,
the "zip slip" attack — are skipped rather than trusted. An archive is usually
something you downloaded.

---

## 3. Looking inside

```dart
for (final entry in await zip.list('site.zip')) {
  print('${entry.name} ${entry.size} ${entry.folder}');
}

final bytes = await zip.read('site.zip', 'index.html');  // null when absent
```

---

## 4. Raw compression

```dart
final packed = zip.deflate(bytes);   // gzip
final raw = zip.inflate(packed);
```

---

## See Also

- [`io.*`](io.md) — reading and writing the files you pack
- [`util.size.*`](util.md) — rendering the sizes `zip.list` reports

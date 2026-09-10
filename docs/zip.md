# Archives (`format.zip.*`)

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
await format.zip.pack('site', 'site.zip');        // a whole folder
await format.zip.pack('notes.txt', 'notes.zip');  // a single file
await format.zip.pack('site', 'site.tar.gz');     // format from the name
```

Paths inside the archive are relative to the source, so unpacking recreates the
tree without the leading directories. The write is atomic, like every other
write in this library.

To build an archive from data that never touched the disk:

```dart
await format.zip.bundle('out.zip', {
  'notes.txt': utf8.encode('hello'),
  'data/rows.csv': csvBytes,
});
```

---

## 2. Unpacking

```dart
final files = await format.zip.unpack('site.zip', 'restored');
print('wrote ${files.length} files');
```

Entries that would escape the destination — a `..` segment or an absolute path,
the "zip slip" attack — are skipped rather than trusted. An archive is usually
something you downloaded.

Unpacking is a restore rather than a fresh write, so a file's recorded unix
permissions and modification time come back with it: an archive of shell
scripts unpacks with its execute bit intact, and a restored tree keeps the
dates it was packed with. Permissions are a no-op on Windows, which has no
such bits, and a zip's DOS timestamp has two-second resolution, so an odd
second is rounded.

---

## 3. Looking inside

```dart
for (final entry in await format.zip.list('site.zip')) {
  print('${entry.name} ${entry.size} ${entry.folder}');
}

final bytes = await format.zip.read('site.zip', 'index.html');  // null when absent
```

---

## 4. Raw compression

```dart
final packed = format.zip.deflate(bytes);   // gzip
final raw = format.zip.inflate(packed);
```

---

## See Also

- [`format.json.*`](json.md) — the configuration formats, spelled the same way
- [`io.*`](io.md) — reading and writing the files you pack
- [`util.size.*`](util.md) — rendering the sizes `format.zip.list` reports

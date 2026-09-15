/// # Archives
///
/// Pack a folder, unpack an archive, look inside one without unpacking it, and
/// squeeze bytes. The format comes from the file name — `.zip`, `.tar`,
/// `.tar.gz`, `.tgz` and `.tar.bz2` are all understood — so one pair of calls
/// covers every archive a script meets.
/// {@category Formats}
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../io/entry.dart';
import '../io/path.dart';
import '../src/fs.dart';
import '../src/proc.dart';

// ============================================================================
// ZIP TOOL (format.zip.*)
// ============================================================================

/// The archive formats [zip] and `ArchiveOnPath.unzipInto` read and write.
enum ArchiveFormat {
  /// A `.zip` container.
  zip,

  /// An uncompressed `.tar` container.
  tar,

  /// A gzip-compressed tar, `.tar.gz` or `.tgz`.
  gz,

  /// A bzip2-compressed tar, `.tar.bz2` or `.tbz`.
  bz2;

  /// The format [path]'s name implies.
  ///
  /// ```dart
  /// ArchiveFormat.of('backup.tar.gz'); // ArchiveFormat.gz
  /// ArchiveFormat.of('site.zip');      // ArchiveFormat.zip
  /// ArchiveFormat.of('archive');       // ArchiveFormat.zip — no extension to go on
  /// ArchiveFormat.of('site.rar');      // throws ArgumentError
  /// ```
  ///
  /// A name carrying an extension none of these four covers throws
  /// [ArgumentError] rather than falling back to [ArchiveFormat.zip]. That fallback
  /// meant `zip('site', 'site.rar')` wrote a zip, named it `.rar`
  /// and reported success — and on the way back in, read a genuine `.rar` as a
  /// zip and failed somewhere further down. A name with no extension at all
  /// has nothing to disagree with and stays [ArchiveFormat.zip].
  static ArchiveFormat of(String path) {
    final name = p.basename(path).toLowerCase();
    if (name.endsWith('.tar.gz') || name.endsWith('.tgz')) {
      return ArchiveFormat.gz;
    }
    if (name.endsWith('.tar.bz2') || name.endsWith('.tbz')) {
      return ArchiveFormat.bz2;
    }
    if (name.endsWith('.tar')) return ArchiveFormat.tar;
    if (name.endsWith('.zip')) return ArchiveFormat.zip;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return ArchiveFormat.zip;
    throw ArgumentError.value(
      path,
      'path',
      "'${name.substring(dot)}' is not an archive this reads or writes; "
          'pass `format:` explicitly, or use .zip, .tar, .tar.gz/.tgz '
          'or .tar.bz2/.tbz',
    );
  }
}

/// One entry inside an archive.
///
/// Named for the archive it is in, because `Entry` alone lands at top level
/// beside [FileSystemEntry] — two types describing "a thing with a name and a
/// size that might be a directory" — and nothing in the shorter name says
/// which is which.
class ArchiveEntry {
  /// The entry's path within the archive, using forward slashes.
  final String name;

  /// Uncompressed size in bytes; zero for a directory.
  final int size;

  /// Whether this entry is a directory rather than a file.
  final bool folder;

  /// Whether this entry is a directory rather than a file.
  ///
  /// Standard alias matching [FileSystemEntry.isDir] and [Path.isDir].
  bool get isDir => folder;

  /// Whether this entry is a regular file.
  bool get isFile => !folder;

  /// The entry's path within the archive, as an alias for [name].
  String get path => name;

  /// Creates an entry description.
  const ArchiveEntry(this.name, this.size, {this.folder = false});

  @override
  String toString() => folder ? '$name/' : '$name ($size bytes)';
}

/// Archives, as members of the path they are at.
///
/// ```dart
/// await Path('site').zipTo('site.zip');
/// for (final e in await Path('site.zip').archiveEntries()) print(e.name);
/// await Path('site.zip').unzipInto('restored');
/// ```
extension ArchiveOnPath on Path {
  /// Packs what is here — a file or a whole folder — into the archive at
  /// [dest].
  ///
  /// The format follows [dest]'s name; pass [format] to override it. Paths
  /// inside the archive are relative to this path, so unpacking recreates the
  /// tree without the leading directories. Existing archives are replaced, and
  /// the write is atomic.
  Future<Path> zipTo(String dest, {ArchiveFormat? format}) async =>
      Path((await _zip(raw, dest, format: format)).path);

  /// Unpacks the archive here into the folder [dest], returning what it wrote.
  ///
  /// An archive that is not there writes nothing rather than throwing. Entries
  /// that would escape [dest] — a `..` segment or an absolute path, the "zip
  /// slip" attack — are skipped rather than trusted, since an archive is
  /// usually something you downloaded, and so are symlink entries, which can
  /// point anywhere at all.
  ///
  /// A file's recorded modification time and unix permissions are restored, so
  /// an archive of shell scripts unpacks with its execute bit intact and a
  /// restored tree keeps the dates it was packed with. Permissions are a no-op
  /// on Windows.
  Future<List<Path>> unzipInto(String dest, {ArchiveFormat? format}) async => [
    for (final file in await _unzip(raw, dest, format: format)) Path(file.path),
  ];

  /// What the archive here holds, without unpacking it.
  ///
  /// Named apart from [Path.list], which answers the same question about a
  /// *directory*: one `entries()` for both would have read as whichever the
  /// reader happened to be thinking about.
  Future<List<ArchiveEntry>> archiveEntries({ArchiveFormat? format}) =>
      _listArchive(raw, format: format);

  /// The bytes of one [name] inside the archive here, or `null`.
  ///
  /// For reading a manifest out of a download without unpacking it — the one
  /// entry, where [unzipInto] is all of them.
  Future<List<int>?> readArchived(String name, {ArchiveFormat? format}) =>
      _extractFromArchive(raw, name, format: format);

  /// Writes an archive here from [files], a map of archive path to contents.
  ///
  /// For building one from data that never touched the disk.
  ///
  /// ```dart
  /// await Path('out.zip').writeArchive({'notes.txt': utf8.encode('hi')});
  /// ```
  Future<Path> writeArchive(
    Map<String, List<int>> files, {
    ArchiveFormat? format,
  }) async => Path((await _zipBytes(raw, files, format: format)).path);
}

/// Gzip, on the bytes themselves.
extension GzipOnBytes on List<int> {
  /// These bytes, gzip-compressed.
  ///
  /// Named for the operation, not the container: the output carries a gzip
  /// header, so it is what a `.gz` file holds rather than a raw deflate
  /// stream.
  List<int> gzip() => GZipEncoder().encodeBytes(this);

  /// These bytes, gzip-decompressed. The inverse of [gzip].
  List<int> gunzip() => GZipDecoder().decodeBytes(this);
}

/// Packs [source] — a file or a whole folder — into the archive at [dest].
///
/// The format follows [dest]'s name; pass [format] to override it. Paths
/// inside the archive are relative to [source], so unpacking recreates the
/// tree without the leading directories. Existing archives are replaced, and
/// the write is atomic.
Future<FileSystemEntry> _zip(
  String source,
  String dest, {
  ArchiveFormat? format,
}) async {
  final archive = Archive();
  final type = FileSystemEntity.typeSync(source);

  if (type == FileSystemEntityType.directory) {
    final root = Directory(source);
    // followLinks defaults to true, which lets a link out of the tree pull
    // unrelated files in — and a link that points at an ancestor walk
    // forever.
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final name = p.relative(entity.path, from: source).replaceAll(r'\', '/');
      if (entity is File) {
        archive.add(
          _stamp(
            ArchiveFile.bytes(name, await entity.readAsBytes()),
            await entity.stat(),
          ),
        );
      } else if (entity is Directory) {
        archive.add(_stamp(ArchiveFile.directory(name), await entity.stat()));
      }
    }
  } else if (type == FileSystemEntityType.file) {
    final file = File(source);
    archive.add(
      _stamp(
        ArchiveFile.bytes(p.basename(source), await file.readAsBytes()),
        await file.stat(),
      ),
    );
  } else {
    throw FileSystemException('Nothing to pack', source);
  }

  return Fs.entryFor(
    (await Fs.save(
      dest,
      _encode(archive, format ?? ArchiveFormat.of(dest)),
    )).path,
  );
}

/// Packs [files] — a map of archive path to contents — into [dest].
///
/// For building an archive from data that never touched the disk.
///
/// ```dart
/// await Path('out.zip').writeArchive({'notes.txt': utf8.encode('hi')});
/// ```
Future<FileSystemEntry> _zipBytes(
  String dest,
  Map<String, List<int>> files, {
  ArchiveFormat? format,
}) async {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return Fs.entryFor(
    (await Fs.save(
      dest,
      _encode(archive, format ?? ArchiveFormat.of(dest)),
    )).path,
  );
}

/// Unpacks the archive at [source] into the folder [dest].
///
/// Returns the files written. An archive that is not there
/// writes nothing rather than throwing. Entries that would escape [dest] — a `..`
/// segment or an absolute path, the "zip slip" attack — are skipped rather
/// than trusted, since an archive is usually something you downloaded, and
/// so are symlink entries, which can point anywhere at all.
///
/// A file's recorded modification time and unix permissions are restored,
/// so an archive of shell scripts unpacks with its execute bit intact and a
/// restored tree keeps the dates it was packed with. Permissions are a no-op
/// on Windows.
Future<List<File>> _unzip(
  String source,
  String dest, {
  ArchiveFormat? format,
}) async {
  final kind = format ?? ArchiveFormat.of(source);
  final archive = await _open(source, kind);
  if (archive == null) return const [];
  final root = p.normalize(p.absolute(dest));
  await Directory(root).create(recursive: true);
  // The real root, because a temp directory is itself a link on macOS and
  // every resolved member would look like an escape from the nominal one.
  final real = await _resolved(root);
  final written = <File>[];
  final executable = <int, List<String>>{};

  for (final entry in archive) {
    final target = p.normalize(p.join(root, entry.name));
    if (!p.isWithin(root, target)) continue;
    // A link entry names a path this has no business creating: recreating it
    // as a directory is simply wrong, and honouring it could point out of
    // [dest] the way a `..` entry would.
    if (entry.isSymbolicLink) continue;
    if (!entry.isFile) {
      await Directory(target).create(recursive: true);
      continue;
    }
    await Directory(p.dirname(target)).create(recursive: true);
    // A link already sitting where a member wants to be is a write that leaves
    // [dest] the moment it is followed: the lexical check above cannot see it,
    // because the archive's own name is innocent.
    if (await FileSystemEntity.type(target, followLinks: false) ==
        FileSystemEntityType.link) {
      await Link(target).delete();
    }
    final parent = await _resolved(p.dirname(target));
    if (parent != real && !p.isWithin(real, parent)) continue;
    final file = File(target);
    await file.writeAsBytes(entry.readBytes() ?? const <int>[]);
    written.add(file);

    final when = _modified(entry, kind);
    // Unpacking is a restore, not a fresh write: an archive that recorded
    // when a file was last touched should not hand it back stamped now.
    if (when != null) await file.setLastModified(when);
    final permissions = entry.mode & 0x1ff;
    if (permissions != 0) {
      executable.putIfAbsent(permissions, () => []).add(target);
    }
  }

  await _permit(executable);
  return written;
}

/// Where [dir] really is, links resolved.
///
/// A member under a planted symlinked directory passes a lexical check and
/// still lands outside the destination, so directories are resolved before the
/// write rather than trusted.
Future<String> _resolved(String dir) async {
  try {
    return p.normalize(await Directory(dir).resolveSymbolicLinks());
  } on FileSystemException {
    return p.normalize(dir);
  }
}

/// Applies each set of unix permissions to the paths that carry it.
///
/// One `chmod` per distinct mode rather than one per file, and none at all
/// on Windows, which has no such bits. Without this an archive of shell
/// scripts unpacks without its execute bit and nothing in it will run.
Future<void> _permit(Map<int, List<String>> byMode) async {
  if (Platform.isWindows || byMode.isEmpty) return;
  for (final entry in byMode.entries) {
    // Only worth a subprocess where the bits differ from what a fresh write
    // already produces.
    if (entry.key == 0x1a4 || entry.key == 0x1b6) continue;
    // `--`, because a member named `--reference=/etc/passwd` is a path here and
    // an option to chmod.
    await Sys.run('chmod', [
      entry.key.toRadixString(8).padLeft(3, '0'),
      '--',
      ...entry.value,
    ]);
  }
}

/// [file] with the mode and modification time [stat] reports.
ArchiveFile _stamp(ArchiveFile file, FileStat stat) => file
  ..mode = stat.mode
  ..lastModTime = stat.modified.millisecondsSinceEpoch ~/ 1000;

/// When [entry] says it was last modified, or `null` when it does not say.
///
/// The two container families disagree about the field: a tar carries
/// seconds since the epoch, while a zip carries a packed DOS date and time,
/// which is what `lastModDateTime` decodes. Reading one as the other yields
/// a date in 1980 or in the far future, so the format decides.
DateTime? _modified(ArchiveFile entry, ArchiveFormat format) {
  if (entry.lastModTime <= 0) return null;
  final DateTime when;
  if (format == ArchiveFormat.zip) {
    // A zip's DOS fields hold local wall-clock components with no zone, and
    // are handed back as if they were UTC. Rebuilding them as local time is
    // what makes the date read back as the one that was packed. DOS time
    // has two-second resolution, so an odd second is lost either way.
    final fields = entry.lastModDateTime;
    when = DateTime(
      fields.year,
      fields.month,
      fields.day,
      fields.hour,
      fields.minute,
      fields.second,
    );
  } else {
    when = DateTime.fromMillisecondsSinceEpoch(entry.lastModTime * 1000);
  }
  if (when.year < 1980 || when.isAfter(DateTime.now().add(_slack))) {
    return null;
  }
  return when;
}

// A clock that is a little ahead is normal; a year ahead is a bad field.
const Duration _slack = Duration(days: 1);

/// Lists what the archive at [source] holds, without unpacking it.
///
/// An archive that is not there is empty, not a throw — the same answer
/// `walkDir`, `readCsvRows` and `JsonFormat.read` give for a missing path.
/// Through 4.0.0 this was the one read in the library that raised
/// `PathNotFoundException`.
Future<List<ArchiveEntry>> _listArchive(
  String source, {
  ArchiveFormat? format,
}) async {
  final archive = await _open(source, format);
  if (archive == null) return const [];
  return archive
      .map(
        (entry) => ArchiveEntry(entry.name, entry.size, folder: !entry.isFile),
      )
      .toList();
}

/// Takes one entry's bytes out of the archive at [source].
///
/// The pair of `ArchiveOnPath.unzipInto`: that one writes everything to disk, this one hands
/// back a single member in memory, and neither is a spelling of the other.
/// Returns `null` when [name] is not in the archive, and when the archive
/// itself is not there.
Future<List<int>?> _extractFromArchive(
  String source,
  String name, {
  ArchiveFormat? format,
}) async {
  final archive = await _open(source, format);
  return archive?.find(name)?.readBytes();
}

/// The archive at [source], or `null` when there is no file there.
///
/// One read and one decode per call, shared by [listArchive], [extractFromArchive] and `ArchiveOnPath.unzipInto`
/// so the three of them agree about a missing file and about which format a
/// name implies.
Future<Archive?> _open(String source, ArchiveFormat? format) async {
  final file = File(source);
  if (!await file.exists()) return null;
  return _decode(await file.readAsBytes(), format ?? ArchiveFormat.of(source));
}

Uint8List _asBytes(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

List<int> _encode(Archive archive, ArchiveFormat format) => switch (format) {
  ArchiveFormat.zip => ZipEncoder().encode(archive),
  ArchiveFormat.tar => TarEncoder().encode(archive),
  ArchiveFormat.gz => GZipEncoder().encodeBytes(TarEncoder().encode(archive)),
  ArchiveFormat.bz2 => BZip2Encoder().encode(TarEncoder().encode(archive)),
};

Archive _decode(List<int> bytes, ArchiveFormat format) {
  final raw = _asBytes(bytes);
  return switch (format) {
    ArchiveFormat.zip => ZipDecoder().decodeBytes(raw),
    ArchiveFormat.tar => TarDecoder().decodeBytes(raw),
    ArchiveFormat.gz => TarDecoder().decodeBytes(
      GZipDecoder().decodeBytes(raw),
    ),
    ArchiveFormat.bz2 => TarDecoder().decodeBytes(
      _asBytes(BZip2Decoder().decodeBytes(raw)),
    ),
  };
}

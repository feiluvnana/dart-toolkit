/// # Filesystem Entries (`FileSystemEntry`)
///
/// One thing on the filesystem, as a value: where it is, what kind of thing it
/// is, how big it is and when it last changed. It is what every `io` member
/// that used to hand back a `dart:io` handle hands back now.
///
/// Seventeen signatures named `File`, `Directory`, `FileSystemEntity` or
/// `FileStat` through 5.1.0, which leaked four types whose API this library
/// does not control, does not document and cannot change — to buy exactly one
/// `.path` across the whole repository. Rule 6 asks for real types at the
/// boundary; it was written about parameters, and the return side had never
/// been swept.
///
/// The door is still there, once: [FileSystemEntry.entity], the way `Json.raw`
/// and `Markup.document` are. Reaching for it is a visible choice rather than
/// the default.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

// ============================================================================
// FILESYSTEM ENTRIES (FileSystemEntry)
// ============================================================================

/// What kind of thing an entry is.
///
/// Read off the entry itself and not what it points at, so a symlink is
/// [link] whatever sits on the other end of it — which is the question
/// `io.find` could never answer, and the reason a script that walks a tree
/// could not tell a loop from a file.
enum FileSystemEntryKind {
  /// A regular file.
  file,

  /// A directory.
  directory,

  /// A symbolic link, whatever it resolves to.
  link,
}

/// One thing on the filesystem: a file, a directory or a link.
///
/// A **snapshot**, not a handle — what was at [path] when it was looked at.
/// There is no descriptor here and nothing to close, which is the property
/// that lets every `io` member stay complete in itself:
///
/// ```dart
/// for (final entry in io.dir.list('out').collect(.list())) {
///   if (entry.isdir) continue;
///   if (entry.ext == '.part') io.remove(entry.path);
/// }
/// ```
///
/// [kind] describes the entry; [size] and [modified] describe what it
/// resolves to, since Dart offers no `lstat`. For a symlink to a file that is
/// the target's size, and [islink] is still `true`.
final class FileSystemEntry {
  /// Creates an entry. Prefer `io.stat`, `io.dir.list` or `io.dir.walk`,
  /// which fill
  /// these in from the disk.
  const FileSystemEntry({
    required this.path,
    required this.kind,
    required this.size,
    required this.modified,
  });

  /// The path it was reached by.
  final String path;

  /// Whether this is a file, a directory or a link.
  final FileSystemEntryKind kind;

  /// Length in bytes, and `0` for a directory.
  ///
  /// A directory's own on-disk size is a block count that answers nothing
  /// anybody asks, so it reads as zero. What is *in* a directory is
  /// `io.dir.list(entry.path)`.
  final int size;

  /// When the contents last changed.
  final DateTime modified;

  /// The last segment of [path], extension included.
  String get name => p.basename(path);

  /// The last segment of [path] without its extension.
  String get stem => p.basenameWithoutExtension(path);

  /// The extension of [path], including the leading dot.
  String get ext => p.extension(path);

  /// The directory holding this entry.
  String get dirname => p.dirname(path);

  /// Whether this is a regular file.
  bool get isfile => kind == FileSystemEntryKind.file;

  /// Whether this is a directory.
  bool get isdir => kind == FileSystemEntryKind.directory;

  /// Whether this is a symbolic link.
  bool get islink => kind == FileSystemEntryKind.link;

  /// Whether there is nothing in it.
  ///
  /// Zero bytes for a file, and no entries for a directory — which is the
  /// question somebody asking about a directory means, where `size == 0` is
  /// true of every directory and therefore an answer to nothing.
  bool get empty {
    if (!isdir) return size == 0;
    final directory = Directory(path);
    if (!directory.existsSync()) return true;
    return directory.listSync(followLinks: false).isEmpty;
  }

  /// The `dart:io` handle, for the call this does not cover.
  ///
  /// The one deliberate leak, the way `Json.raw` and `Markup.document` are: a
  /// typed surface with a single documented door to what is underneath, so
  /// that needing the door shows up in review. Passing a [File] to another
  /// package is `entry.entity`; everything this library does takes the
  /// [path].
  FileSystemEntity get entity => switch (kind) {
    FileSystemEntryKind.file => File(path),
    FileSystemEntryKind.directory => Directory(path),
    FileSystemEntryKind.link => Link(path),
  };

  @override
  String toString() => 'FileSystemEntry($path, ${kind.name}, $size)';

  @override
  bool operator ==(Object other) =>
      other is FileSystemEntry &&
      other.path == path &&
      other.kind == kind &&
      other.size == size &&
      other.modified == modified;

  @override
  int get hashCode => Object.hash(path, kind, size, modified);
}

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
  link;

  /// Shorthand alias for [directory].
  static FileSystemEntryKind get dir => directory;
}

/// One thing on the filesystem: a file, a directory or a link.
///
/// A **snapshot**, not a handle — what was at [path] when it was looked at.
/// There is no descriptor here and nothing to close, which is the property
/// that lets every `io` member stay complete in itself:
///
/// ```dart
/// for (final entry in Files.listSync('out')) {
///   if (entry.isDir) continue;
///   if (fileExtension(entry.path) == '.part') Files.removeSync(entry.path);
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
  ///
  /// The one piece of path arithmetic this type keeps, defined as the
  /// `io.path` call so there is one implementation of it. It survives because
  /// `e.name` is in nearly every listing loop and
  /// `io.path.filename(e.path)` inside a `where` is genuinely worse.
  ///
  /// `stem`, `ext` and `dirname` were here through 5.5.0 and are not: they
  /// were `io.path.stem(e.path)`, `io.path.ext(e.path)` and
  /// `io.path.dirname(e.path)` under four other names, on the same input, and
  /// `io.path` is the domain that owns string arithmetic on a path.
  String get name => p.basename(path);

  /// Whether this entry currently exists on disk.
  bool get exists =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  /// Whether this is a regular file.
  ///
  /// [isfile], [isdir] and [islink] read [kind], which the one stat this
  /// snapshot came from already answered. `io.isfile(path)` costs a syscall
  /// for the same question, so these are not a second spelling of it — they
  /// are the cheap question about a value you are holding.
  bool get isfile => kind == FileSystemEntryKind.file;

  /// CamelCase alias for [isfile].
  bool get isFile => isfile;

  /// Whether this is a directory.
  bool get isdir => kind == FileSystemEntryKind.directory;

  /// CamelCase alias for [isdir].
  bool get isDir => isdir;

  /// Whether this is a symbolic link.
  bool get islink => kind == FileSystemEntryKind.link;

  /// CamelCase alias for [islink].
  bool get isLink => islink;

  /// Whether this entry holds nothing — zero bytes, for a file or a link.
  ///
  /// **Always `false` for a directory**, and reading the disk is why. This
  /// answered the directory question through 5.4.0 by calling `listSync`
  /// inside the getter, which broke the type's own promise — a snapshot of
  /// one stat, not a handle — and made `io.async.empty` block on every
  /// directory it was asked about, from the accessor whose whole point is
  /// that it does not.
  ///
  /// Counting what is in a directory is a second listing, so it is a second
  /// call and says which accessor it is on: `io.dir.empty(path)` blocks and
  /// `io.async.dir.empty(path)` does not. `io.empty(path)` still answers for
  /// either kind, by asking the right one.
  bool get empty => !isdir && size == 0;

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

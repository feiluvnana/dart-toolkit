/// # Listing, Walking & Globbing (internal)
///
/// Implementation behind `io.dir.list`, `io.dir.walk`, `io.dir.find`,
/// `io.dir.glob` and `io.stat`. Every one of them hands back a
/// [FileSystemEntry], which is what took the `dart:io` types back out of the
/// public signatures.
///
/// Not exported: reach these operations through `io.dir.*`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../io/entry.dart';

// ============================================================================
// LISTING, WALKING & GLOBBING (Entries)
// ============================================================================

/// Static listing helpers backing `io.dir.*`.
class Entries {
  const Entries._();

  /// The kind of thing at [path], or `null` when there is nothing there.
  ///
  /// Links are not followed, so a symlink reports [FileSystemEntryKind.link]
  /// whatever it points at — including when it points at nothing.
  static FileSystemEntryKind? kind(String path) =>
      _kind(FileSystemEntity.typeSync(path, followLinks: false));

  /// The kind of thing at [path] without blocking.
  static Future<FileSystemEntryKind?> kindAsync(String path) async =>
      _kind(await FileSystemEntity.type(path, followLinks: false));

  static FileSystemEntryKind? _kind(FileSystemEntityType type) =>
      switch (type) {
        FileSystemEntityType.file => FileSystemEntryKind.file,
        FileSystemEntityType.directory => FileSystemEntryKind.directory,
        FileSystemEntityType.link => FileSystemEntryKind.link,
        _ => null,
      };

  /// The entry at [path], or `null` when there is nothing there.
  static FileSystemEntry? at(String path) {
    final found = kind(path);
    return found == null ? null : _fill(path, found);
  }

  /// The entry at [path] without blocking, or `null` when nothing is there.
  static Future<FileSystemEntry?> atAsync(String path) async {
    final found = await kindAsync(path);
    if (found == null) return null;
    if (found == FileSystemEntryKind.directory) {
      return FileSystemEntry(
        path: path,
        kind: found,
        size: 0,
        modified: (await FileStat.stat(path)).modified,
      );
    }
    final stat = await FileStat.stat(path);
    return FileSystemEntry(
      path: path,
      kind: found,
      size: stat.size < 0 ? 0 : stat.size,
      modified: stat.modified,
    );
  }

  /// Builds an entry for [path], reading size and mtime off the disk.
  ///
  /// A directory's size is zero rather than its block count, and a stat that
  /// fails — a broken link, or an entry deleted between the listing and this
  /// call — reads as zero bytes at the epoch rather than throwing partway
  /// through a walk.
  static FileSystemEntry _fill(String path, FileSystemEntryKind kind) {
    final stat = FileStat.statSync(path);
    final directory = kind == FileSystemEntryKind.directory;
    return FileSystemEntry(
      path: path,
      kind: kind,
      size: directory || stat.size < 0 ? 0 : stat.size,
      modified: stat.modified,
    );
  }

  /// Everything directly under [dir], read as it is walked.
  static Iterable<FileSystemEntry> list(
    String dir, {
    FileSystemEntryKind? only,
    String? match,
  }) => walk(dir, only: only, match: match, depth: 1);

  /// Everything under [dir], to [depth] levels.
  ///
  /// [depth] counts levels below [dir], so `1` is the same set [list] gives
  /// and `null` is the whole tree. [match] is a glob, tested against the
  /// entry's name when it holds no `/` and against the path relative to [dir]
  /// when it does. [follow] descends through symlinked directories, keeping a
  /// set of resolved paths so a link that points at its own ancestor stops
  /// rather than recursing forever.
  /// A directory is opened when the walk reaches it and not before, so a
  /// reader that stops early — `take.first(10)`, a `first.where` — costs the
  /// directories it actually looked in. The set of resolved link targets is
  /// built inside this body, which runs once per walk, so walking the same
  /// iterable twice follows the same links both times.
  static Iterable<FileSystemEntry> walk(
    String dir, {
    FileSystemEntryKind? only,
    String? match,
    int? depth,
    bool follow = true,
  }) sync* {
    yield* _step(
      dir,
      1,
      root: dir,
      only: only,
      matcher: match == null ? null : glob(match),
      rooted: match != null && match.contains('/'),
      depth: depth,
      follow: follow,
      seen: <String>{},
    );
  }

  static Iterable<FileSystemEntry> _step(
    String current,
    int level, {
    required String root,
    required FileSystemEntryKind? only,
    required RegExp? matcher,
    required bool rooted,
    required int? depth,
    required bool follow,
    required Set<String> seen,
  }) sync* {
    if (depth != null && level > depth) return;
    final List<FileSystemEntity> children;
    try {
      children = Directory(current).listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final child in children) {
      final kind = _kind(
        FileSystemEntity.typeSync(child.path, followLinks: false),
      );
      if (kind == null) continue;
      final entry = _fill(child.path, kind);
      if (_keeps(entry, only, matcher, rooted, root)) yield entry;
      if (depth != null && level >= depth) continue;
      if (entry.isdir) {
        yield* _step(
          child.path,
          level + 1,
          root: root,
          only: only,
          matcher: matcher,
          rooted: rooted,
          depth: depth,
          follow: follow,
          seen: seen,
        );
      } else if (entry.islink && follow) {
        if (!FileSystemEntity.isDirectorySync(child.path)) continue;
        final String real;
        try {
          real = Directory(child.path).resolveSymbolicLinksSync();
        } on FileSystemException {
          continue;
        }
        if (!seen.add(real)) continue;
        yield* _step(
          child.path,
          level + 1,
          root: root,
          only: only,
          matcher: matcher,
          rooted: rooted,
          depth: depth,
          follow: follow,
          seen: seen,
        );
      }
    }
  }

  /// The non-blocking twin of [walk].
  static Future<List<FileSystemEntry>> walkAsync(
    String dir, {
    FileSystemEntryKind? only,
    String? match,
    int? depth,
    bool follow = true,
  }) async {
    final out = <FileSystemEntry>[];
    final matcher = match == null ? null : glob(match);
    final rooted = match != null && match.contains('/');
    final seen = <String>{};

    Future<void> step(String current, int level) async {
      if (depth != null && level > depth) return;
      final children = <FileSystemEntity>[];
      try {
        await for (final child in Directory(current).list(followLinks: false)) {
          children.add(child);
        }
      } on FileSystemException {
        return;
      }
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        final entry = await atAsync(child.path);
        if (entry == null) continue;
        if (_keeps(entry, only, matcher, rooted, dir)) out.add(entry);
        if (depth != null && level >= depth) continue;
        if (entry.isdir) {
          await step(child.path, level + 1);
        } else if (entry.islink && follow) {
          if (!await FileSystemEntity.isDirectory(child.path)) continue;
          final String real;
          try {
            real = await Directory(child.path).resolveSymbolicLinks();
          } on FileSystemException {
            continue;
          }
          if (!seen.add(real)) continue;
          await step(child.path, level + 1);
        }
      }
    }

    await step(dir, 1);
    return out;
  }

  static bool _keeps(
    FileSystemEntry entry,
    FileSystemEntryKind? only,
    RegExp? matcher,
    bool rooted,
    String dir,
  ) {
    if (only != null && entry.kind != only) return false;
    if (matcher == null) return true;
    final subject = rooted
        ? p.relative(entry.path, from: dir).replaceAll(r'\', '/')
        : entry.name;
    return matcher.hasMatch(subject);
  }

  /// Every entry matching the shell-style [pattern], relative to the cwd.
  ///
  /// The leading segments that hold no wildcard become the directory to walk
  /// from, so `out/reports/*.csv` opens one directory rather than the whole
  /// tree. A `**` anywhere in the pattern makes the walk recursive.
  static Iterable<FileSystemEntry> expand(String pattern) sync* {
    final (base, rest) = _split(pattern);
    if (rest.isEmpty) {
      final single = at(p.normalize(base));
      if (single != null) yield single;
      return;
    }
    final recursive = rest.contains('**');
    final matcher = glob(rest);
    for (final entry in walk(
      base,
      depth: recursive ? null : p.split(rest).length,
    )) {
      final relative = p.relative(entry.path, from: base).replaceAll(r'\', '/');
      if (matcher.hasMatch(relative)) yield entry;
    }
  }

  /// The non-blocking twin of [expand].
  static Future<List<FileSystemEntry>> expandAsync(String pattern) async {
    final (base, rest) = _split(pattern);
    if (rest.isEmpty) {
      final single = await atAsync(p.normalize(base));
      return single == null ? const [] : [single];
    }
    final recursive = rest.contains('**');
    final matcher = glob(rest);
    final out = <FileSystemEntry>[];
    for (final entry in await walkAsync(
      base,
      depth: recursive ? null : p.split(rest).length,
    )) {
      final relative = p.relative(entry.path, from: base).replaceAll(r'\', '/');
      if (matcher.hasMatch(relative)) out.add(entry);
    }
    return out;
  }

  /// Splits [pattern] into the literal directory to start from and the glob.
  static (String, String) _split(String pattern) {
    final segments = p.split(pattern);
    var cut = 0;
    while (cut < segments.length && !_wild.hasMatch(segments[cut])) {
      cut++;
    }
    final base = cut == 0 ? '.' : p.joinAll(segments.take(cut));
    return (base, segments.skip(cut).join('/'));
  }

  static final _wild = RegExp(r'[*?\[{]');

  /// Compiles a shell-style [pattern] into an anchored regular expression.
  ///
  /// `*` matches within one segment, `**` across segments, `?` one character,
  /// `[abc]` and `[!abc]` a class, and `{a,b}` an alternation. Everything else
  /// is literal — which is the whole point, since `RegExp(r'\.csv$')` was the
  /// price of asking for `*.csv` through 5.1.0.
  static RegExp glob(String pattern) {
    final out = StringBuffer('^');
    var braces = 0;
    for (var i = 0; i < pattern.length; i++) {
      final char = pattern[i];
      switch (char) {
        case '*':
          if (i + 1 < pattern.length && pattern[i + 1] == '*') {
            i++;
            // `**/` also matches zero directories, so `**/*.csv` finds a file
            // sitting directly in the base.
            if (i + 1 < pattern.length && pattern[i + 1] == '/') {
              i++;
              out.write('(?:.*/)?');
            } else {
              out.write('.*');
            }
          } else {
            out.write('[^/]*');
          }
        case '?':
          out.write('[^/]');
        case '[':
          final close = pattern.indexOf(']', i + 1);
          if (close == -1) {
            out.write(r'\[');
            break;
          }
          var body = pattern.substring(i + 1, close);
          if (body.startsWith('!')) body = '^${body.substring(1)}';
          out
            ..write('[')
            ..write(body.replaceAll(r'\', r'\\'))
            ..write(']');
          i = close;
        case '{':
          braces++;
          out.write('(?:');
        case '}':
          if (braces > 0) {
            braces--;
            out.write(')');
          } else {
            out.write(r'\}');
          }
        case ',':
          out.write(braces > 0 ? '|' : ',');
        default:
          out.write(RegExp.escape(char));
      }
    }
    return RegExp('$out\$');
  }
}

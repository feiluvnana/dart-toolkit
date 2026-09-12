/// # Paths (`io.path.*`)
///
/// Everything `io` can answer about a path **without touching the disk**.
///
/// It is a sub-namespace for the reason `io.csv` is one: a cohesive
/// vocabulary with its own nouns — segments, extensions, separators — and it
/// is the only corner of `io` where nothing is read, written or created. That
/// is also why it has no twin under `io.async`: there is nothing to wait for.
///
/// ```dart
/// final out = io.path.join('out', io.path.stem(src) + '.json');
/// io.path.dirname(out);    // 'out'
/// io.path.filename(out);   // 'report.json'
/// io.path.ext(out);        // '.json'
/// ```
///
/// Four of these are renames, and all four were named for the wrong half of
/// what they did. `io.dir(path)` returned the parent and read like it made
/// one; `io.base` and `io.name` differed only in whether the extension
/// survived, which neither word said. `dirname`, `filename` and `stem` are
/// the words every other library on the table uses.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../src/fs.dart';

// ============================================================================
// PATHS (io.path.*)
// ============================================================================

/// Entry point for path arithmetic, reachable as `io.path`.
///
/// Paths are plain strings. Given a [FileSystemEntry], pass its
/// [FileSystemEntry.path].
class PathAccessor {
  /// Creates the accessor. Prefer the shared `io.path` instance.
  const PathAccessor();

  /// The current working directory.
  ///
  /// It was `io.dir.cwd` through 5.5.0. A directory, yes — but this domain is
  /// defined as the one corner where nothing is read, written or created, and
  /// asking the process where it is standing reads no disk. Moving it deleted
  /// the only exception `io.dir`'s mirror test had to carry.
  String get cwd => Fs.cwd;

  /// The current user's home directory.
  ///
  /// `$HOME` on POSIX and `%USERPROFILE%` on Windows, falling back to
  /// `%HOMEDRIVE%%HOMEPATH%` and finally to [cwd], so this never returns
  /// `null` for a script to handle.
  String get home => Fs.home;

  /// Joins path segments using the platform separator.
  String join(
    String part1, [
    String? part2,
    String? part3,
    String? part4,
    String? part5,
    String? part6,
    String? part7,
    String? part8,
  ]) => p.join(part1, part2, part3, part4, part5, part6, part7, part8);

  /// The directory portion of [path].
  ///
  /// ```dart
  /// io.path.dirname('a/b/c.txt');   // 'a/b'
  /// ```
  ///
  /// This reads a string and touches nothing. *Creating* that directory is
  /// `io.dir.makeParent`, which is a different verb in a different namespace
  /// — where through 5.1.0 the two were `io.dir` and `io.parent`, each named
  /// for what the other one did.
  String dirname(String path) => p.dirname(path);

  /// The final segment of [path], including any extension.
  ///
  /// ```dart
  /// io.path.filename('a/b/c.tar.gz');   // 'c.tar.gz'
  /// ```
  String filename(String path) => p.basename(path);

  /// The final segment of [path] without its extension.
  ///
  /// ```dart
  /// io.path.stem('a/b/c.tar.gz');   // 'c.tar'
  /// ```
  String stem(String path) => p.basenameWithoutExtension(path);

  /// The extension of [path], including the leading dot.
  String ext(String path) => p.extension(path);

  /// The segments of [path], separators dropped.
  ///
  /// ```dart
  /// io.path.parts('a/b/c.txt');   // ['a', 'b', 'c.txt']
  /// ```
  ///
  /// An absolute path keeps its root as the first segment, so the result
  /// always rejoins to what went in.
  List<String> parts(String path) => p.split(path);

  /// [path] with `.`, `..` and duplicate separators resolved.
  ///
  /// Pure string arithmetic: no symlink is followed and nothing is checked
  /// for existence, so this works on a path that is not there.
  ///
  /// ```dart
  /// io.path.normalize('out/./reports/../a.txt');   // 'out/a.txt'
  /// ```
  String normalize(String path) => p.normalize(path);

  /// [path] made absolute against the current directory.
  String abs(String path) => p.absolute(path);

  /// [path] made relative to [from], or to the current directory.
  String rel(String path, {String? from}) => p.relative(path, from: from);

  /// [path] with a leading `~` and any `$VAR` references resolved.
  ///
  /// `~` expands to [home] only at the start of the path, which is the
  /// only place a shell expands it either. `$VAR` and `${VAR}` read from the
  /// process environment, and a name that is not set expands to nothing —
  /// the same as a shell, and the reason this is not `env.read`'s job.
  ///
  /// ```dart
  /// io.path.expand('~/.config/mytool/config.json');
  /// io.path.expand(r'$XDG_CACHE_HOME/mytool');
  /// ```
  String expand(String path) {
    var out = path;
    if (out == '~') {
      out = home;
    } else if (out.startsWith('~/') || out.startsWith('~\\')) {
      out = p.join(home, out.substring(2));
    }
    return out.replaceAllMapped(
      _variable,
      (m) => Platform.environment[m.group(1) ?? m.group(2)!] ?? '',
    );
  }

  static final _variable = RegExp(r'\$\{(\w+)\}|\$(\w+)');

  /// Replaces characters that are illegal in filenames. See [Fs.sanitize].
  String sanitize(String name, {String replace = '_', bool full = false}) =>
      Fs.sanitize(name, replace: replace, full: full);
}

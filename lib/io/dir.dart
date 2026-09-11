/// # Directories (`io.dir.*`)
///
/// Making directories, and looking inside them.
///
/// Creating a directory is not what `io` is mainly for, and neither is
/// listing one — they are a vocabulary of their own, with their own nouns:
/// entries, depth, links to follow or not. Rule 3 calls that a sub-namespace,
/// and putting them here leaves `io` itself holding what it is actually
/// about, which is one file at a time.
///
/// ```dart
/// io.dir.make('out/reports');
/// io.dir.list('out');                       // one level, everything
/// io.dir.list('out', only: .directory);
/// io.dir.walk('out', match: '*.csv');       // the whole tree, a glob
/// io.dir.walk('out', depth: 2);
/// io.dir.glob('out/**/*.json');
/// ```
///
/// [list] is one level and returns everything; [walk] is recursive. That is
/// the split Python (`iterdir`/`walk`), Node (`readdir`/`readdir {recursive}`)
/// and Go (`ReadDir`/`WalkDir`) all make, and through 5.1.0 this library made
/// neither: `io.find` carried both on one member with a `recursive:` flag
/// while also silently dropping every directory it walked past, so listing a
/// folder was not possible at all.
///
/// The name `io.dir` was a path function through 5.1.0 — it returned the
/// parent of a path and created nothing, which is precisely backwards. That
/// reader is `io.path.dirname` now, and the name went to the things that do
/// touch a directory.
library;

import '../collection/sequence.dart';
import '../src/entries.dart';
import '../src/fs.dart';
import 'entry.dart';

// ============================================================================
// DIRECTORIES (io.dir.*)
// ============================================================================

/// Entry point for directories, reachable as `io.dir`.
///
/// Everything here blocks; `io.async.dir` is the same set of names as
/// futures.
class DirAccessor {
  /// Creates the accessor. Prefer the shared `io.dir` instance.
  const DirAccessor();

  /// The current working directory.
  String get cwd => Fs.cwd;

  /// The current user's home directory.
  ///
  /// `$HOME` on POSIX and `%USERPROFILE%` on Windows, falling back to
  /// `%HOMEDRIVE%%HOMEPATH%` and finally to [cwd], so this never returns
  /// `null` for a script to handle.
  String get home => Fs.home;

  // --- Making ---

  /// Creates the directory at [path], including any missing parents.
  ///
  /// Returns the directory whether it had to be created or was already there,
  /// so this is safe to call on every run.
  FileSystemEntry make(String path) => Fs.mkdirSync(path);

  /// Creates the directory *holding* [path], including any missing parents.
  ///
  /// For the write you are about to do with something that is not this
  /// library — every `io` write already does this for itself:
  ///
  /// ```dart
  /// io.dir.makeparent('out/nested/report.txt');   // makes 'out/nested'
  /// io.write('out/nested/report.txt', 'done');    // makes it anyway
  /// ```
  ///
  /// It was `io.parent` through 5.1.0, a name that reads like it returns the
  /// parent and instead creates it. The reader is `io.path.dirname`.
  FileSystemEntry makeparent(String path) => Fs.mkparentSync(path);

  /// Creates a new temporary directory with the given name [prefix].
  FileSystemEntry temp([String prefix = 'tmp_']) => Fs.tempSync(prefix);

  // --- Looking inside ---

  /// Everything directly under [dir]: files, directories and links.
  ///
  /// ```dart
  /// io.dir.list('out');
  /// io.dir.list('out', only: .directory);
  /// io.dir.list('out', match: '*.csv');
  /// ```
  ///
  /// Empty when [dir] does not exist, so a listing needs no [io.exists] in
  /// front of it. [match] is a glob — `*.csv`, not `RegExp(r'\.csv$')`.
  Sequence<FileSystemEntry> list(
    String dir, {
    FileSystemEntryKind? only,
    String? match,
  }) => Sequence(Entries.list(dir, only: only, match: match));

  /// Everything under [dir], however deep.
  ///
  /// ```dart
  /// io.dir.walk('src');                     // the whole tree
  /// io.dir.walk('src', only: .file);
  /// io.dir.walk('src', match: '**/*.dart');
  /// io.dir.walk('src', depth: 2);
  /// io.dir.walk('src', follow: false);      // do not descend into symlinks
  /// ```
  ///
  /// [depth] counts levels below [dir], so `depth: 1` is exactly [list].
  /// [match] is tested against an entry's name when it holds no `/`, and
  /// against its path relative to [dir] when it does.
  ///
  /// [follow] descends through symlinked directories. A link pointing at one
  /// of its own ancestors would otherwise recurse until the stack ran out, so
  /// the walk remembers which real directories it has entered and stops the
  /// second time — the cycle is skipped, not an error.
  Sequence<FileSystemEntry> walk(
    String dir, {
    FileSystemEntryKind? only,
    String? match,
    int? depth,
    bool follow = true,
  }) => Sequence(
    Entries.walk(dir, only: only, match: match, depth: depth, follow: follow),
  );

  /// Files under [dir] matching [pattern], directories and links dropped.
  ///
  /// The narrow question — *give me the mp3s* — where [walk] is the general
  /// one. [pattern] is a [Pattern] tested against the file's name, so a
  /// [RegExp] works; [walk]'s `match:` is the glob.
  ///
  /// ```dart
  /// io.dir.find('music', pattern: RegExp(r'\.mp3$'));
  /// io.dir.walk('music', match: '*.mp3', only: .file);   // the same set
  /// ```
  Sequence<FileSystemEntry> find(
    String dir, {
    Pattern? pattern,
    bool recursive = true,
  }) => Sequence(
    Entries.walk(
      dir,
      only: FileSystemEntryKind.file,
      depth: recursive ? null : 1,
    ).where(
      (entry) => pattern == null || pattern.allMatches(entry.name).isNotEmpty,
    ),
  );

  /// Every entry matching the shell-style [pattern], from the current
  /// directory.
  ///
  /// ```dart
  /// io.dir.glob('out/*.csv');
  /// io.dir.glob('src/**/*.dart');
  /// io.dir.glob('out/report-{2024,2025}.json');
  /// ```
  ///
  /// `*` matches within one segment, `**` across them, `?` one character,
  /// `[abc]` a class and `{a,b}` an alternation. The leading segments with no
  /// wildcard in them are the directory the walk starts from, so
  /// `out/reports/*.csv` opens one directory rather than the whole tree.
  Sequence<FileSystemEntry> glob(String pattern) =>
      Sequence(Entries.expand(pattern));

  /// Deletes every file under [dir] matching [pattern], and returns how many.
  ///
  /// The sweep, where [io.remove] is the single entity. Both were called
  /// `delete` and `remove` through 4.0.0 — synonyms, so neither name said
  /// which was which.
  ///
  /// ```dart
  /// io.remove('out/report.pdf');                          // one entity
  /// io.dir.sweep('out', pattern: RegExp(r'\.part$'));     // everything
  /// ```
  ///
  /// The listing is taken in full before the first delete: a walk reads the
  /// disk as it goes, and deleting under a walk in progress is the one thing
  /// a lazy listing cannot be asked to survive.
  int sweep(String dir, {Pattern? pattern, bool recursive = false}) {
    var count = 0;
    for (final entry in find(
      dir,
      pattern: pattern,
      recursive: recursive,
    ).collect(.list())) {
      try {
        entry.entity.deleteSync();
        count++;
      } catch (_) {}
    }
    return count;
  }
}

/// The non-blocking mirror of [DirAccessor], reachable as `io.async.dir`.
///
/// Every member that touches the disk appears here under the same name and
/// arguments, returning a future. [DirAccessor.cwd] and [DirAccessor.home]
/// do not, since neither reads anything.
class DirAsyncAccessor {
  /// Creates the accessor. Prefer the shared `io.async.dir` instance.
  const DirAsyncAccessor();

  /// Creates the directory at [path], including any missing parents.
  Future<FileSystemEntry> make(String path) => Fs.mkdir(path);

  /// Creates the directory holding [path], including any missing parents.
  Future<FileSystemEntry> makeparent(String path) => Fs.mkparent(path);

  /// Creates a new temporary directory with the given name [prefix].
  Future<FileSystemEntry> temp([String prefix = 'tmp_']) => Fs.temp(prefix);

  /// Everything directly under [dir]: files, directories and links.
  Future<Sequence<FileSystemEntry>> list(
    String dir, {
    FileSystemEntryKind? only,
    String? match,
  }) async => Sequence(
    await Entries.walkAsync(dir, only: only, match: match, depth: 1),
  );

  /// Everything under [dir], however deep. See [DirAccessor.walk].
  Future<Sequence<FileSystemEntry>> walk(
    String dir, {
    FileSystemEntryKind? only,
    String? match,
    int? depth,
    bool follow = true,
  }) async => Sequence(
    await Entries.walkAsync(
      dir,
      only: only,
      match: match,
      depth: depth,
      follow: follow,
    ),
  );

  /// Files under [dir] matching [pattern]. See [DirAccessor.find].
  Future<Sequence<FileSystemEntry>> find(
    String dir, {
    Pattern? pattern,
    bool recursive = true,
  }) async => Sequence(
    (await Entries.walkAsync(
      dir,
      only: FileSystemEntryKind.file,
      depth: recursive ? null : 1,
    )).where(
      (entry) => pattern == null || pattern.allMatches(entry.name).isNotEmpty,
    ),
  );

  /// Every entry matching the shell-style [pattern]. See [DirAccessor.glob].
  Future<Sequence<FileSystemEntry>> glob(String pattern) async =>
      Sequence(await Entries.expandAsync(pattern));

  /// Deletes every file under [dir] matching [pattern], and returns how many.
  Future<int> sweep(
    String dir, {
    Pattern? pattern,
    bool recursive = false,
  }) async {
    var count = 0;
    for (final entry in (await find(
      dir,
      pattern: pattern,
      recursive: recursive,
    )).collect(.list())) {
      try {
        await entry.entity.delete();
        count++;
      } catch (_) {}
    }
    return count;
  }
}

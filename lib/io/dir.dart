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
/// io.dir.sweep('out', match: '*.part');
/// ```
///
/// [DirAccessor.list] is one level and returns everything;
/// [DirAccessor.walk] is recursive. That is the split Python
/// (`iterdir`/`walk`), Node (`readdir`/`readdir {recursive}`) and Go
/// (`ReadDir`/`WalkDir`) all make, and through 5.1.0 this library made
/// neither: `io.find` carried both on one member with a `recursive:` flag
/// while also silently dropping every directory it walked past, so listing a
/// folder was not possible at all.
///
/// ## One matcher, one depth axis
///
/// Every member that looks at more than one entry takes the same three
/// filters — `only:` for the kind, `match:` for a **glob**, `depth:` for how
/// far down — and nothing else. Through 5.4.0 there were three vocabularies
/// for *filter a tree*: `walk`'s glob, `find`'s `Pattern` with a
/// `recursive:` bool, and `glob`'s pattern-as-the-whole-argument. `find` is
/// gone, because its own doc said it was `walk(only: .file, match: …)`; a
/// [RegExp] filter is the collection vocabulary's job now, one
/// `transform` further on:
///
/// ```dart
/// // setup: final re = RegExp(r'\.mp3$');
/// io.dir.walk('music', only: .file, match: '*.mp3');
/// io.dir.walk('music').transform(.where((e) => re.hasMatch(e.name)));
/// ```
///
/// The name `io.dir` was a path function through 5.1.0 — it returned the
/// parent of a path and created nothing, which is precisely backwards. That
/// reader is `io.path.dirname` now, and the name went to the things that do
/// touch a directory.
library;

import '../collection/flow.dart';
import '../collection/sequence.dart';
import '../src/entries.dart';
import '../src/fs.dart';
import 'entry.dart';

// ============================================================================
// DIRECTORIES (io.dir.*)
// ============================================================================

/// Entry point for directories, reachable as `io.dir`.
///
/// Everything here blocks; `io.async.dir` is the same set of names,
/// returning futures or flows.
class DirAccessor {
  /// Creates the accessor. Prefer the shared `io.dir` instance.
  const DirAccessor();

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

  /// Deletes entries under [dir], and returns how many went.
  ///
  /// The sweep, where [IoAccessor.remove] is the single entity. Both were
  /// called `delete` and `remove` through 4.0.0 — synonyms, so neither name
  /// said which was which.
  ///
  /// ```dart
  /// io.remove('out/report.pdf');              // one entity
  /// io.dir.sweep('out', match: '*.part');     // everything matching
  /// io.dir.sweep('out', match: '*.tmp', depth: 1);
  /// ```
  ///
  /// [only], [match] and [depth] filter exactly as they do on [walk] —
  /// one matcher language and one depth axis across the whole namespace.
  /// Through 5.4.0 this took a `Pattern` and a `recursive:` bool while its
  /// siblings took a glob and a `depth:`, and defaulted to one level while
  /// the member it was built from defaulted to the whole tree.
  ///
  /// **Directories are left alone** unless [only] asks for them by name: a
  /// sweep that also removed the directories it walked is [IoAccessor.remove]
  /// under another name. When it does ask, the deepest paths go first, so a
  /// directory is emptied before it is removed and nothing is counted twice.
  ///
  /// The listing is taken in full before the first delete: a walk reads the
  /// disk as it goes, and deleting under a walk in progress is the one thing
  /// a lazy listing cannot be asked to survive.
  int sweep(
    String dir, {
    FileSystemEntryKind? only,
    String? match,
    int? depth,
  }) {
    var count = 0;
    for (final entry in _sweepable(
      walk(dir, only: only, match: match, depth: depth).collect(.list()),
      only,
    )) {
      try {
        entry.entity.deleteSync(recursive: entry.isdir);
        count++;
      } catch (_) {}
    }
    return count;
  }

  /// How much the tree under [dir] holds, in bytes.
  ///
  /// Every regular file under [dir], added up. `io.size(dir)` is `0` by
  /// design — a directory's own on-disk size answers nothing anybody asks —
  /// so this is the member that answers *how big is this folder*.
  ///
  /// Links are counted as nothing rather than as their target, so a tree
  /// that links to itself, or twice to one large file, is not counted twice.
  int size(String dir) => walk(
    dir,
    only: FileSystemEntryKind.file,
  ).collect(.sum((entry) => entry.size)).toInt();

  /// Whether the directory at [path] holds no entries.
  ///
  /// The directory half of `io.empty`, which is a second listing and so a
  /// second call — see [FileSystemEntry.empty], which stopped answering it.
  /// A path that is not there reads as empty, so a listing loop needs no
  /// [IoAccessor.exists] in front of it.
  bool empty(String path) => Entries.empty(path);

  /// Creates a symbolic link at [path] pointing at [target].
  ///
  /// [target] is written into the link exactly as given, so a relative target
  /// resolves against the link's own directory — which is what makes a
  /// `latest` pointer survive its parent being moved:
  ///
  /// ```dart
  /// io.dir.link('out/latest', 'run-2026-09-11');
  /// io.dir.target('out/latest');     // 'run-2026-09-11'
  /// ```
  ///
  /// Here rather than on `io` because a link is a kind of entry rather than a
  /// file, and [target] would have collided with nothing useful on `io`
  /// anyway. Replaces whatever link is already at [path]; throws when
  /// something that is not a link is.
  FileSystemEntry link(String path, String target) => Fs.linkSync(path, target);

  /// What the link at [path] points at, or `null` when [path] is not a link.
  ///
  /// The raw target, not the resolved one: a relative link reads back
  /// relative. `io.path.join(io.path.dirname(path), target)` is the absolute
  /// form when that is what you wanted.
  String? target(String path) => Fs.targetSync(path);
}

/// The non-blocking mirror of [DirAccessor], reachable as `io.async.dir`.
///
/// Every member that touches the disk appears here under the same name and
/// arguments: single operations return futures, and listing operations
/// return a [Flow] so large trees are walked as they arrive.
/// Every member of [DirAccessor] appears here, with no exceptions — `cwd` and
/// `home` were the two, and they are `io.path.cwd` and `io.path.home` now,
/// because they read nothing and that is `io.path`'s whole membership rule.
///
/// The listings are [Flow.of] flows — **re-derivable**, so a second terminal
/// walks the disk again rather than throwing, which is exactly what a second
/// walk of the blocking [Sequence] does. Through 5.4.0 the two sides were
/// documented as *the same four words, differing only in the `await`*, and
/// that was true of one terminal and false of anything that read the listing
/// twice.
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
  Flow<FileSystemEntry> list(
    String dir, {
    FileSystemEntryKind? only,
    String? match,
  }) =>
      Flow.of(() => Entries.walkAsync(dir, only: only, match: match, depth: 1));

  /// Everything under [dir], however deep. See [DirAccessor.walk].
  Flow<FileSystemEntry> walk(
    String dir, {
    FileSystemEntryKind? only,
    String? match,
    int? depth,
    bool follow = true,
  }) => Flow.of(
    () => Entries.walkAsync(
      dir,
      only: only,
      match: match,
      depth: depth,
      follow: follow,
    ),
  );

  /// Every entry matching the shell-style [pattern]. See [DirAccessor.glob].
  Flow<FileSystemEntry> glob(String pattern) =>
      Flow.of(() => Entries.expandAsync(pattern));

  /// Deletes entries under [dir], and returns how many went.
  /// See [DirAccessor.sweep].
  ///
  /// The listing is taken in full before the first delete. Through 5.4.0 the
  /// flow rewrite made this twin delete *under a live walk* — the one thing
  /// the blocking twin's own doc says a lazy listing cannot survive.
  Future<int> sweep(
    String dir, {
    FileSystemEntryKind? only,
    String? match,
    int? depth,
  }) async {
    var count = 0;
    final listing = await walk(
      dir,
      only: only,
      match: match,
      depth: depth,
    ).collect(.list());
    for (final entry in _sweepable(listing, only)) {
      try {
        await entry.entity.delete(recursive: entry.isdir);
        count++;
      } catch (_) {}
    }
    return count;
  }

  /// How much the tree under [dir] holds, in bytes. See [DirAccessor.size].
  Future<int> size(String dir) async => (await walk(
    dir,
    only: FileSystemEntryKind.file,
  ).collect(.sum((entry) => entry.size))).toInt();

  /// Whether the directory at [path] holds no entries. See [DirAccessor.empty].
  Future<bool> empty(String path) => Entries.emptyAsync(path);

  /// Creates a symbolic link at [path] pointing at [target].
  /// See [DirAccessor.link].
  Future<FileSystemEntry> link(String path, String target) =>
      Fs.link(path, target);

  /// What the link at [path] points at, or `null`. See [DirAccessor.target].
  Future<String?> target(String path) => Fs.target(path);
}

/// The entries a sweep may remove, deepest first.
///
/// A directory is only swept when [only] named it, and then children come
/// before parents so an entry a recursive delete would have taken anyway is
/// counted once rather than twice.
List<FileSystemEntry> _sweepable(
  List<FileSystemEntry> found,
  FileSystemEntryKind? only,
) {
  final wanted = only == FileSystemEntryKind.directory
      ? found
      : found.where((entry) => !entry.isdir).toList();
  return wanted..sort((a, b) => b.path.length.compareTo(a.path.length));
}

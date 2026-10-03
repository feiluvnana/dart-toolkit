part of '../../fs.dart';

final _invalidPathChars = RegExp(r'[:*?"<>|\r\n\t]');
final _invalidNameChars = RegExp(r'[/\\:*?"<>|]');
final _whitespaceCollapse = RegExp(r'\s+');
final _braceSlash = RegExp(r'\{[^}]*/');
final _classEscape = RegExp(r'[\\^\[\]]');
final _controlChars = RegExp(r'[\x00-\x1f]');
final _tempName = RegExp(r'^\..+\.[0-9a-f]{16}\.tmp$');

/// The type of filesystem entity at a [Path].
///
/// {@category Files}
enum PathType { file, dir, link, none }

/// The front door for filesystem operations and paths.
///
/// {@category Files}
abstract final class Fs {
  /// Wraps [path] as a [Path].
  static Path path(String path) => Path(path);

  /// The current working directory.
  static Path get current => Path.current;

  /// The user's home directory.
  static Path get home => Path.home;

  /// The system temporary directory.
  static Path get temp => Path.temp;

  /// Runs [body] with a fresh, empty directory under [temp], deleted afterwards.
  static Future<R> tempDir<R>(FutureOr<R> Function(Path dir) body) => Path.tempDir(body);
}

/// A filesystem path that is also a [String], with path and filesystem helpers.
///
/// {@category Files}
extension type const Path(String path) implements String {
  /// The user's home directory.
  static Path get home => Path(Env.getOrNull('HOME') ?? Env.getOrNull('USERPROFILE') ?? Directory.current.path);

  /// The system temporary directory. For a directory of your own, see [tempDir].
  static Path get temp => Path(Directory.systemTemp.path);

  /// Runs [body] with a fresh, empty directory under [temp], deleted afterwards whether
  /// [body] returned or threw, and returns what [body] returned.
  ///
  /// ```dart
  /// final names = await Path.tempDir((dir) async {
  ///   await archive.extractTo(dir);
  ///   return [for (final f in dir.filesSync(recursive: true)) f.name];
  /// });
  /// ```
  static Future<R> tempDir<R>(FutureOr<R> Function(Path dir) body) async {
    final dir = Path((await Directory.systemTemp.createTemp('dart_toolkit_')).path);
    try {
      return await body(dir);
    } finally {
      // A failed cleanup must not replace what [body] returned or threw.
      await dir.delete(recursive: true).catchError((Object _) {});
    }
  }

  /// The current working directory.
  static Path get current => Path(Directory.current.path);

  /// Appends [part] to this path.
  Path operator /(String part) => Path(p.join(path, part));

  /// The canonical form of this path, with `.` and `..` segments resolved.
  ///
  /// An extension type cannot override `==`, so `Path('/a/b/../b')` and `Path('/a/b')` are
  /// distinct map keys: normalize at map boundaries, `map[p.normalized]`.
  Path get normalized => Path(p.normalize(path));

  /// The final component of this path (e.g. `'song.mp3'` or `'folder'`).
  String get name => p.basename(path);

  /// The final component without its file extension (e.g. `'song'` from `'song.mp3'`).
  String get stem => p.basenameWithoutExtension(path);

  /// The file extension without leading dot (e.g. `'mp3'` from `'song.mp3'`), or empty string.
  String get ext {
    final e = p.extension(path);
    return e.startsWith('.') ? e.substring(1) : e;
  }

  /// The parent directory as a [Path].
  Path get parent => Path(p.dirname(path));

  /// Whether this path starts at a root.
  bool get isAbsolute => p.isAbsolute(path);

  /// This path made absolute against the working directory, and normalized.
  Path get absolute => Path(p.normalize(p.absolute(path)));

  /// This path relative to [from], else to the working directory.
  Path relativeTo([String? from]) => Path(p.relative(path, from: from));

  /// This path with its extension replaced by [ext], with or without the dot; `''` removes it.
  Path withExt(String ext) => Path(p.setExtension(path, ext.isEmpty || ext.startsWith('.') ? ext : '.$ext'));

  /// This path with its final component replaced by [name].
  Path withName(String name) => parent / name;

  /// The individual path segments.
  List<String> get segments => p.split(path);

  /// This path as a [Link]. See [links] for the links *inside* this directory.
  Link get asLink => Link(path);

  /// This path as a [File]. See [files] for the files *inside* this directory.
  File get asFile => File(path);

  /// This path as a [Directory]. See [dirs] for the directories *inside* it.
  Directory get asDir => Directory(path);

  /// The entity type here; a link is not followed.
  Future<PathType> type() async => _pathType(await FileSystemEntity.type(path, followLinks: false));

  /// Whether anything, a dangling link included, is at this path.
  Future<bool> exists() async => await type() != PathType.none;

  /// The entity type here, synchronously.
  PathType typeSync() => _pathType(FileSystemEntity.typeSync(path, followLinks: false));

  /// Whether anything is at this path, synchronously.
  bool existsSync() => typeSync() != PathType.none;

  /// When this file or directory was last modified.
  Future<DateTime> modified() async => (await FileStat.stat(path)).modified;

  /// When this file or directory was last modified, synchronously.
  DateTime modifiedSync() => FileStat.statSync(path).modified;

  /// Whether this was last modified more than [age] ago, or is not there at all — the
  /// question a cache asks: `if (await cache.olderThan(1.h)) refresh();`.
  Future<bool> olderThan(Duration age) async => _older(await FileStat.stat(path), age);

  /// Whether this was last modified more than [age] ago, or is not there; see [olderThan].
  bool olderThanSync(Duration age) => _older(FileStat.statSync(path), age);

  /// Creates this file if it does not exist, else sets its modification time to now.
  Future<File> touch() async {
    if (await asFile.exists()) {
      await asFile.setLastModified(DateTime.now());
      return asFile;
    }
    await asFile.parent.create(recursive: true);
    return asFile.create();
  }

  /// [touch], synchronously.
  File touchSync() {
    if (asFile.existsSync()) {
      asFile.setLastModifiedSync(DateTime.now());
    } else {
      asFile.parent.createSync(recursive: true);
      asFile.createSync();
    }
    return asFile;
  }

  /// Sets this path's permission bits, as `chmod` does, through a link: [mode] is octal
  /// (`'755'`, `'0600'`) or symbolic (`'+x'`, `'u+rw,go-w'`, `'a=r'`).
  ///
  /// On Windows only the owner's write bit means anything: without it the file is read-only.
  /// A [mode] that is neither form is a [FormatException].
  Future<void> chmod(String mode) async => chmodSync(mode);

  /// Sets this path's permission bits synchronously; see [chmod].
  void chmodSync(String mode) => _chmod(path, _modeOf(mode, path));

  /// The size in bytes of this file, or of everything under this directory.
  ///
  /// This path is followed if it is a link; links inside a directory are not, so nothing is
  /// counted twice. A directory is walked in a worker isolate, a sync stat per file.
  Future<int> size() async => switch (_pathType(await FileSystemEntity.type(path))) {
    PathType.file => await asFile.length(),
    PathType.dir => await Isolate.run(() => _dirSize(path)),
    _ => 0,
  };

  /// [size], synchronously.
  int sizeSync() => switch (_pathType(FileSystemEntity.typeSync(path))) {
    PathType.file => asFile.lengthSync(),
    PathType.dir => _dirSize(path),
    _ => 0,
  };

  /// This path with invalid filesystem characters replaced, and control characters removed,
  /// in every component; separators survive (on POSIX `\` is a name character, not one). For
  /// one component use [StringPathExtensions.filename].
  Path get sanitized {
    final useSlash = !Platform.isWindows || path.contains('/') || !path.contains(r'\');
    final root = p.rootPrefix(path);
    final rawParts = path.substring(root.length).split(Platform.isWindows ? RegExp(r'[/\\]') : '/');
    final parts = [
      for (final part in rawParts)
        part
            .replaceAll(_invalidPathChars, '_')
            .replaceAll(_controlChars, '')
            .replaceAll(_whitespaceCollapse, ' ')
            .trim(),
    ];
    final sep = useSlash ? '/' : p.separator;
    return Path(root + parts.join(sep));
  }

  /// Reads this file as a string.
  Future<String> readText({Encoding encoding = utf8}) => asFile.readAsString(encoding: encoding);

  /// Reads this file as a string synchronously.
  String readTextSync({Encoding encoding = utf8}) => asFile.readAsStringSync(encoding: encoding);

  /// Reads this file as raw bytes.
  Future<Uint8List> readBytes() => asFile.readAsBytes();

  /// Reads this file as raw bytes synchronously.
  Uint8List readBytesSync() => asFile.readAsBytesSync();

  /// Reads this file as a list of lines.
  Future<List<String>> readLines({Encoding encoding = utf8}) => asFile.readAsLines(encoding: encoding);

  /// Streams this file's lines without holding the file; for the whole list use [readLines].
  Stream<String> lines({Encoding encoding = utf8}) =>
      asFile.openRead().transform(encoding.decoder).transform(const LineSplitter());

  /// Reads this file as a list of lines synchronously.
  List<String> readLinesSync({Encoding encoding = utf8}) => asFile.readAsLinesSync(encoding: encoding);

  /// Writes [content] to this file, creating parent directories if not present.
  ///
  /// Atomic: the bytes go to a temporary file beside this one, renamed over it, so a reader
  /// (or a ^C halfway) sees the old file or the new one. An existing file keeps its
  /// permissions, and a link keeps pointing where it did. A device or a FIFO is written in
  /// place, and so is a file in a folder that refuses a new one; any other failure leaves the
  /// old file as it was. The new file is a new inode: hard links and xattrs stay with the old.
  Future<File> writeText(String content, {Encoding encoding = utf8}) => writeBytes(encoding.encode(content));

  /// [writeText], synchronously.
  File writeTextSync(String content, {Encoding encoding = utf8}) => writeBytesSync(encoding.encode(content));

  /// Writes [bytes] to this file; atomic, as [writeText] is.
  Future<File> writeBytes(List<int> bytes) =>
      FileBridge.write(path, bytes, chmod: NativeLib.isAvailable ? _chmod : null);

  /// [writeBytes], synchronously.
  File writeBytesSync(List<int> bytes) =>
      FileBridge.writeSync(path, bytes, chmod: NativeLib.isAvailable ? _chmod : null);

  /// Writes [lines] to this file, each ending in a newline; atomic, as [writeText] is.
  Future<File> writeLines(Iterable<String> lines, {Encoding encoding = utf8}) =>
      writeText(lines.map((l) => '$l\n').join(), encoding: encoding);

  /// [writeLines], synchronously.
  File writeLinesSync(Iterable<String> lines, {Encoding encoding = utf8}) =>
      writeTextSync(lines.map((l) => '$l\n').join(), encoding: encoding);

  /// Lists all entities in this directory.
  Stream<Path> list({bool recursive = false, bool followLinks = false}) =>
      asDir.list(recursive: recursive, followLinks: followLinks).map((e) => Path(e.path));

  /// Lists all entities in this directory synchronously.
  List<Path> listSync({bool recursive = false, bool followLinks = false}) =>
      asDir.listSync(recursive: recursive, followLinks: followLinks).map((e) => Path(e.path)).toList();

  /// The files in this directory.
  Stream<Path> files({bool recursive = false, bool followLinks = false, Iterable<String>? extensions}) {
    var s = _only<File>(recursive, followLinks: followLinks);
    if (extensions != null) {
      final exts = {for (final e in extensions) e.startsWith('.') ? e.substring(1).toLowerCase() : e.toLowerCase()};
      s = s.where((p) => exts.contains(p.ext.toLowerCase()));
    }
    return s;
  }

  /// The files in this directory, synchronously.
  List<Path> filesSync({bool recursive = false, bool followLinks = false, Iterable<String>? extensions}) {
    var list = _onlySync<File>(recursive, followLinks: followLinks);
    if (extensions != null) {
      final exts = {for (final e in extensions) e.startsWith('.') ? e.substring(1).toLowerCase() : e.toLowerCase()};
      list = list.where((p) => exts.contains(p.ext.toLowerCase())).toList();
    }
    return list;
  }

  /// The subdirectories of this directory.
  Stream<Path> dirs({bool recursive = false, bool followLinks = false}) =>
      _only<Directory>(recursive, followLinks: followLinks);

  /// The subdirectories of this directory, synchronously.
  List<Path> dirsSync({bool recursive = false, bool followLinks = false}) =>
      _onlySync<Directory>(recursive, followLinks: followLinks);

  /// The symbolic links in this directory.
  Stream<Path> links({bool recursive = false}) => _only<Link>(recursive, followLinks: false);

  /// The symbolic links in this directory, synchronously.
  List<Path> linksSync({bool recursive = false}) => _onlySync<Link>(recursive, followLinks: false);

  Stream<Path> _only<T>(bool recursive, {bool followLinks = false}) =>
      asDir.list(recursive: recursive, followLinks: followLinks).where((e) => e is T).map((e) => Path(e.path));

  List<Path> _onlySync<T>(bool recursive, {bool followLinks = false}) => [
    for (final e in asDir.listSync(recursive: recursive, followLinks: followLinks))
      if (e is T) Path(e.path),
  ];

  /// Streams the files matching [pattern], e.g. `'**/*.mp3'` or `'lib/**/*.{dart,md}'`.
  ///
  /// `*` is any run within one segment, `**` any number of segments, `?` one character,
  /// `[abc]`, `[a-z]` and `[!abc]` one of (or none of) a set, and `{a,b}` either spelling.
  /// A pattern ending in `/` matches directories instead of files: `'**/test/'`. A link is
  /// matched as itself, like a file, and never followed.
  ///
  /// The walk goes only where the pattern can match: `'build/**/*.o'` descends into `build`,
  /// and a pattern without `**` no deeper than it has segments. An unreadable directory is
  /// skipped. [caseSensitive] defaults to the platform's (insensitive on macOS and Windows).
  Stream<Path> glob(String pattern, {bool? caseSensitive}) async* {
    final (start, rest, depth, dirs) = _globPlan(pattern);
    if (start != path && !await Directory(start).exists()) return;
    final matcher = _globToRegex(rest, caseSensitive: caseSensitive);
    final entities = depth == null
        ? Directory(start).list(recursive: true, followLinks: false).handleError((_) {}, test: _unreadable)
        : _walk(Directory(start), depth);
    await for (final entity in entities) {
      if ((entity is Directory) == dirs && matcher.hasMatch(_relative(start, entity.path))) yield Path(entity.path);
    }
  }

  /// Lists the files matching [pattern] synchronously; see [glob].
  List<Path> globSync(String pattern, {bool? caseSensitive}) {
    final (start, rest, depth, dirs) = _globPlan(pattern);
    if (start != path && !Directory(start).existsSync()) return const [];
    final matcher = _globToRegex(rest, caseSensitive: caseSensitive);
    return [
      for (final entity in _walkSync(Directory(start), depth))
        if ((entity is Directory) == dirs && matcher.hasMatch(_relative(start, entity.path))) Path(entity.path),
    ];
  }

  /// Where a [glob] starts (the segments before the first wildcard), what it matches from
  /// there, how deep it can go (unbounded with `**`), and whether it asked for directories.
  (String start, String rest, int? depth, bool dirs) _globPlan(String pattern) {
    var normalized = pattern.replaceAll(r'\', '/');
    final dirs = normalized.length > 1 && normalized.endsWith('/');
    if (dirs) normalized = normalized.substring(0, normalized.length - 1);
    final segments = normalized.split('/');
    var fixed = 0;
    // The last segment is always part of the match, never of the prefix.
    while (fixed < segments.length - 1 && !segments[fixed].contains(_wildcard)) {
      fixed++;
    }
    final prefix = segments.take(fixed).join('/');
    final rest = segments.skip(fixed).join('/');
    // A `/` inside braces — `{a,b/c}` — makes the depth one of several, so it is not bounded.
    final unbounded = rest.contains('**') || _braceSlash.hasMatch(rest);
    final rawStart = p.isAbsolute(pattern)
        ? (prefix.length < p.rootPrefix(pattern).length ? p.rootPrefix(pattern) : prefix)
        : p.join(path, prefix);
    return (p.normalize(rawStart), rest, unbounded ? null : segments.length - fixed, dirs);
  }

  /// Creates a directory at this path.
  Future<Directory> mkdir({bool recursive = true}) => asDir.create(recursive: recursive);

  /// [mkdir], synchronously.
  Directory mkdirSync({bool recursive = true}) {
    asDir.createSync(recursive: recursive);
    return asDir;
  }

  /// Creates a symlink at this path pointing to [target].
  Future<Link> symlink(String target) async {
    await asLink.parent.create(recursive: true);
    return asLink.create(target);
  }

  /// [symlink], synchronously.
  Link symlinkSync(String target) {
    asLink.parent.createSync(recursive: true);
    asLink.createSync(target);
    return asLink;
  }

  /// Copies this file, directory or link to [targetPath].
  ///
  /// A link is copied as a link, whether it is this path or inside this directory, as
  /// `cp -R` does, so a [move] across devices keeps them.
  Future<void> copy(String targetPath, {bool overwrite = false}) async {
    final t = await type();
    _checkCopy(t, targetPath);
    if (overwrite && await Path(targetPath).exists()) {
      await Path(targetPath).delete(recursive: true);
    }
    if (t != PathType.dir) return _copyOne(_entity(t), targetPath);
    await Directory(targetPath).create(recursive: true);
    final modes = [(targetPath, (await asDir.stat()).mode)];
    await for (final entity in asDir.list(recursive: true, followLinks: false)) {
      final dest = p.join(targetPath, p.relative(entity.path, from: path));
      if (entity is Directory) {
        await Directory(dest).create(recursive: true);
        modes.add((dest, (await entity.stat()).mode));
      } else {
        await _copyOne(entity, dest);
      }
    }
    _restoreModes(modes);
  }

  /// [copy], synchronously.
  void copySync(String targetPath, {bool overwrite = false}) {
    final t = typeSync();
    _checkCopy(t, targetPath);
    if (overwrite && Path(targetPath).existsSync()) {
      Path(targetPath).deleteSync(recursive: true);
    }
    if (t != PathType.dir) return _copyOneSync(_entity(t), targetPath);
    Directory(targetPath).createSync(recursive: true);
    final modes = [(targetPath, asDir.statSync().mode)];
    for (final entity in asDir.listSync(recursive: true, followLinks: false)) {
      final dest = p.join(targetPath, p.relative(entity.path, from: path));
      if (entity is Directory) {
        Directory(dest).createSync(recursive: true);
        modes.add((dest, entity.statSync().mode));
      } else {
        _copyOneSync(entity, dest);
      }
    }
    _restoreModes(modes);
  }

  void _checkCopy(PathType t, String targetPath) {
    if (t == PathType.none) throw FileSystemException('Cannot copy non-existent path', path);
    if (t != PathType.dir) return;
    final (from, to) = (_real(path), _real(targetPath));
    if (from == to || p.isWithin(from, to)) {
      throw FileSystemException('Cannot copy a directory into itself', path);
    }
  }

  /// Moves this file or directory to [targetPath], copying and deleting across filesystems.
  ///
  /// A directory already at [targetPath] is replaced only when it is empty, as `rename` does.
  Future<void> move(String targetPath, {bool overwrite = false}) async {
    final t = await type();
    if (t == PathType.none) throw FileSystemException('Cannot move non-existent path', path);
    if (overwrite && await Path(targetPath).exists()) {
      await Path(targetPath).delete(recursive: true);
    }
    await File(targetPath).parent.create(recursive: true);
    try {
      await _entity(t).rename(targetPath);
    } on FileSystemException catch (e) {
      // Only across devices: copying over any other failure (a non-empty directory in the
      // way) would merge into the target and then delete the source.
      if (!_crossDevice(e)) rethrow;
      _checkReplace(t, targetPath);
      await copy(targetPath, overwrite: overwrite);
      await delete(recursive: true);
    }
  }

  /// [move], synchronously.
  void moveSync(String targetPath, {bool overwrite = false}) {
    final t = typeSync();
    if (t == PathType.none) throw FileSystemException('Cannot move non-existent path', path);
    if (overwrite && Path(targetPath).existsSync()) {
      Path(targetPath).deleteSync(recursive: true);
    }
    File(targetPath).parent.createSync(recursive: true);
    try {
      _entity(t).renameSync(targetPath);
    } on FileSystemException catch (e) {
      if (!_crossDevice(e)) rethrow;
      _checkReplace(t, targetPath);
      copySync(targetPath, overwrite: overwrite);
      deleteSync(recursive: true);
    }
  }

  /// Refuses, as rename(2) would, what a copy across devices would merge into or put beside:
  /// a non-empty directory, a directory in place of a file, or a file in place of one.
  void _checkReplace(PathType t, String targetPath) {
    final there = _pathType(FileSystemEntity.typeSync(targetPath, followLinks: false));
    final (reason, code) = switch (there) {
      PathType.dir when t != PathType.dir => ('Is a directory', 21),
      PathType.dir when Directory(targetPath).listSync().isNotEmpty => (
        'Directory not empty',
        Platform.isWindows ? 145 : (Platform.isMacOS ? 66 : 39),
      ),
      PathType.file || PathType.link when t == PathType.dir => ('Not a directory', 20),
      _ => (null, 0),
    };
    if (reason != null) throw FileSystemException('Cannot move to $targetPath', path, OSError(reason, code));
  }

  /// The entity this is, as [t] says: a link is renamed as a link, never through its target.
  FileSystemEntity _entity(PathType t) => switch (t) {
    PathType.dir => asDir,
    PathType.link => asLink,
    _ => asFile,
  };

  /// Deletes this file, directory, or link; nothing there is not an error.
  Future<void> delete({bool recursive = false}) async => switch (await type()) {
    PathType.file => await asFile.delete(),
    PathType.dir => await asDir.delete(recursive: recursive),
    PathType.link => await asLink.delete(),
    PathType.none => null,
  };

  /// [delete], synchronously.
  void deleteSync({bool recursive = false}) => switch (typeSync()) {
    PathType.file => asFile.deleteSync(),
    PathType.dir => asDir.deleteSync(recursive: recursive),
    PathType.link => asLink.deleteSync(),
    PathType.none => null,
  };

  /// Appends [content] to this file, creating parent directories and file if not present.
  Future<File> append(String content, {Encoding encoding = utf8}) async {
    await asFile.parent.create(recursive: true);
    return asFile.writeAsString(content, mode: FileMode.append, encoding: encoding);
  }

  /// [append], synchronously.
  File appendSync(String content, {Encoding encoding = utf8}) {
    asFile.parent.createSync(recursive: true);
    asFile.writeAsStringSync(content, mode: FileMode.append, encoding: encoding);
    return asFile;
  }

  /// Rewrites this file with [from] replaced by [replacement]; the inherited
  /// [String.replaceAll] works on the path text instead.
  Future<File> replaceText(Pattern from, String replacement, {Encoding encoding = utf8}) async =>
      writeText((await readText(encoding: encoding)).replaceAll(from, replacement), encoding: encoding);

  /// [replaceText], synchronously.
  File replaceTextSync(Pattern from, String replacement, {Encoding encoding = utf8}) =>
      writeTextSync(readTextSync(encoding: encoding).replaceAll(from, replacement), encoding: encoding);

  /// The paths that changed under this file or directory, sent as a batch once nothing has
  /// changed for [debounce], so a build that writes a hundred files is one rebuild. A file
  /// is watched through its folder, so it outlives atomic writes; their temporary files are
  /// left out.
  ///
  /// ```dart
  /// await for (final changed in 'lib'.path.changes()) rebuild(changed);
  /// ```
  Stream<Set<Path>> changes({Duration debounce = const Duration(milliseconds: 200)}) {
    late StreamSubscription<FileSystemEvent> events;
    Timer? quiet;
    var batch = <Path>{};
    final out = StreamController<Set<Path>>(
      onCancel: () {
        quiet?.cancel();
        return events.cancel();
      },
    );
    out.onListen = () {
      final isDir = FileSystemEntity.isDirectorySync(path);
      // A file is watched through its folder: an atomic write renames a new file over it,
      // which ends a watch on the file itself.
      final folder = isDir ? path : p.dirname(path);
      if (!isDir && !FileSystemEntity.isDirectorySync(folder)) {
        // A watch on a missing folder never fires and never ends: say so instead.
        events = const Stream<FileSystemEvent>.empty().listen(null);
        out
          ..addError(PathNotFoundException(folder, const OSError('No such file or directory', 2), 'Cannot watch'))
          ..close();
        return;
      }
      final watched = isDir ? asDir.watch(recursive: true) : Directory(folder).watch();
      events = watched.listen(
        (e) {
          final hit = [
            e.path,
            if (e is FileSystemMoveEvent && e.destination != null) e.destination!,
          ].where((f) => isDir ? !_isTemp(p.basename(f)) : p.basename(f) == name);
          if (hit.isEmpty) return;
          batch.addAll(isDir ? hit.map(Path.new) : [this]);
          quiet?.cancel();
          quiet = Timer(debounce, () {
            final ready = batch;
            batch = {};
            out.add(ready);
          });
        },
        onError: out.addError,
        onDone: () {
          quiet?.cancel();
          if (batch.isNotEmpty) out.add(batch);
          out.close();
        },
      );
    };
    return out.stream;
  }
}

/// [String] as a [Path]: `'out'.path`, `'out' / 'a.txt'`.
///
/// {@category Files}
extension StringPathExtensions on String {
  /// This string as a [Path].
  Path get path => Path(this);

  /// Joins this path with [other].
  Path operator /(String other) => Path(this) / other;

  /// This string as a single path component, safe to join with [Path.operator /].
  ///
  /// Separators and reserved characters become `_`, control characters go, whitespace runs
  /// collapse, and the result is never empty, `.` or `..`; at most 255 UTF-8 bytes, keeping
  /// the extension.
  Path get filename {
    final cleaned = replaceAll(
      _whitespaceCollapse,
      ' ',
    ).trim().replaceAll(_controlChars, '').replaceAll(_invalidNameChars, '_');
    final name = switch (cleaned) {
      '' || '.' => '_',
      '..' => '__',
      _ => cleaned,
    };
    return Path(_capFilename(name));
  }
}

/// [path] absolute, with the links on the part of it that exists resolved: `/var/x` and
/// `x` run from `/private/var` are one place.
String _real(String path) {
  var head = p.canonicalize(path);
  final tail = <String>[];
  for (;;) {
    try {
      return p.joinAll([File(head).resolveSymbolicLinksSync(), ...tail.reversed]);
    } on FileSystemException {
      if (p.dirname(head) == head) return p.canonicalize(path);
      tail.add(p.basename(head));
      head = p.dirname(head);
    }
  }
}

bool _older(FileStat stat, Duration age) =>
    stat.type == FileSystemEntityType.notFound || DateTime.now().difference(stat.modified) > age;

int _dirSize(String path) {
  var total = 0;
  for (final e in Directory(path).listSync(recursive: true, followLinks: false)) {
    if (e is File) total += e.lengthSync();
  }
  return total;
}

/// [entity], a file or a link, copied to [dest]; a link keeps its target.
Future<void> _copyOne(FileSystemEntity entity, String dest) async {
  await File(dest).parent.create(recursive: true);
  if (entity is Link) {
    await _deleteNonDir(dest);
    await Link(dest).create(await entity.target());
  } else {
    await (entity as File).copy(dest);
  }
}

void _copyOneSync(FileSystemEntity entity, String dest) {
  File(dest).parent.createSync(recursive: true);
  if (entity is Link) {
    _deleteNonDirSync(dest);
    Link(dest).createSync(entity.targetSync());
  } else {
    (entity as File).copySync(dest);
  }
}

final _tkChmod = NativeBridge.require()
    .lookupFunction<Int32 Function(Pointer<Uint8>, IntPtr, Uint32), int Function(Pointer<Uint8>, int, int)>('tk_chmod');

void _chmod(String path, int mode) {
  if (NativeBridge.withText(path, (ptr, len) => _tkChmod(ptr, len, mode)) < 0) {
    throw FileSystemException(NativeBridge.lastError(), path);
  }
}

/// Copied directories get their modes back deepest first, once filled: a read-only one set
/// first would refuse its contents. Skipped on Windows and without the native library.
void _restoreModes(List<(String, int)> modes) {
  if (Platform.isWindows || !NativeLib.isAvailable) return;
  for (final (dir, mode) in modes.reversed) {
    _chmod(dir, mode & 0xfff);
  }
}

final _octalMode = RegExp(r'^[0-7]{1,4}$');
final _symbolicClause = RegExp(r'^([ugoa]*)((?:[-+=][rwxXst]*)+)$');
final _symbolicOp = RegExp(r'([-+=])([rwxXst]*)');

/// [mode], octal or symbolic (relative to [path]'s current bits), as the bits to set.
int _modeOf(String mode, String path) {
  if (_octalMode.hasMatch(mode)) return int.parse(mode, radix: 8);
  final stat = FileStat.statSync(path);
  if (stat.type == FileSystemEntityType.notFound) throw FileSystemException('No such file or directory', path);
  var bits = stat.mode & 0xfff;
  final isDir = stat.type == FileSystemEntityType.directory;
  for (final clause in mode.split(',')) {
    final m = _symbolicClause.firstMatch(clause);
    if (m == null) throw FormatException('Not an octal or symbolic mode', mode);
    final who = m[1]!.isEmpty || m[1]!.contains('a') ? 'ugo' : m[1]!;
    // The bits [who] covers: rwx and the special bit of each class; with no who at all, as
    // chmod(1) has it, not those the umask clears.
    var mask = 0;
    if (who.contains('u')) mask |= 0x9c0; // 04700
    if (who.contains('g')) mask |= 0x438; // 02070
    if (who.contains('o')) mask |= 0x207; // 01007
    if (m[1]!.isEmpty) mask &= ~_umask;
    for (final op in _symbolicOp.allMatches(m[2]!)) {
      var perm = 0;
      for (final c in op[2]!.split('')) {
        perm |= switch (c) {
          'r' => 0x124, // 0444
          'w' => 0x92, // 0222
          'x' => 0x49, // 0111
          'X' => isDir || bits & 0x49 != 0 ? 0x49 : 0,
          's' => 0xc00, // 06000
          _ => 0x200, // 't', 01000
        };
      }
      perm &= mask;
      bits = switch (op[1]) {
        '+' => bits | perm,
        '-' => bits & ~perm,
        _ => (bits & ~mask) | perm,
      };
    }
  }
  return bits;
}

/// The process umask, read once without umask(2), whose set-and-restore races other isolates:
/// from `/proc` on Linux, else from `sh`. Windows has none.
final int _umask = () {
  if (Platform.isWindows) return 0;
  try {
    final status = File('/proc/self/status').readAsStringSync();
    final m = RegExp(r'^Umask:\s*([0-7]+)', multiLine: true).firstMatch(status);
    if (m != null) return int.parse(m[1]!, radix: 8);
  } on FileSystemException {
    // Not Linux, or no procfs.
  }
  final r = Process.runSync('/bin/sh', ['-c', 'umask']);
  return int.tryParse('${r.stdout}'.trim(), radix: 8) ?? 0x12; // 022
}();

/// Whether [name] is one of [FileBridge]'s temporary files.
bool _isTemp(String name) => _tempName.hasMatch(name);

Future<void> _deleteNonDir(String path) async {
  try {
    await Link(path).delete();
  } catch (_) {
    try {
      await File(path).delete();
    } catch (_) {}
  }
}

void _deleteNonDirSync(String path) {
  try {
    Link(path).deleteSync();
  } catch (_) {
    try {
      File(path).deleteSync();
    } catch (_) {}
  }
}

String _capFilename(String name) {
  if (utf8.encode(name).length <= 255) return name;
  final ext = p.extension(name);
  final extBytes = utf8.encode(ext).length;
  if (extBytes >= 255) return _truncateUtf8(name, 255);
  return _truncateUtf8(name.substring(0, name.length - ext.length), 255 - extBytes) + ext;
}

String _truncateUtf8(String s, int maxBytes) {
  final buf = StringBuffer();
  var total = 0;
  for (final rune in s.runes) {
    final len = rune <= 0x7F
        ? 1
        : rune <= 0x7FF
        ? 2
        : rune <= 0xFFFF
        ? 3
        : 4;
    if (total + len > maxBytes) break;
    buf.writeCharCode(rune);
    total += len;
  }
  return buf.toString();
}

PathType _pathType(FileSystemEntityType type) => switch (type) {
  FileSystemEntityType.file => PathType.file,
  FileSystemEntityType.directory => PathType.dir,
  FileSystemEntityType.link => PathType.link,
  _ => PathType.none,
};

/// Everything under [dir], at most [depth] levels down, skipping what cannot be read;
/// `Directory.list(recursive: true)` has no depth limit.
Stream<FileSystemEntity> _walk(Directory dir, int depth) async* {
  if (depth < 1) return;
  await for (final entity in dir.list(followLinks: false).handleError((_) {}, test: _unreadable)) {
    yield entity;
    if (entity is Directory) yield* _walk(entity, depth - 1);
  }
}

/// [_walk], synchronously; unbounded when [depth] is `null`. An unbounded walk is one
/// `listSync(recursive: true)`, 1.8× faster, redone per directory only if that throws.
List<FileSystemEntity> _walkSync(Directory dir, int? depth, [List<FileSystemEntity>? out]) {
  if (depth == null && out == null) {
    try {
      return dir.listSync(recursive: true, followLinks: false);
    } on FileSystemException {
      // Walked below instead.
    }
  }
  out ??= [];
  if (depth != null && depth < 1) return out;
  try {
    for (final entity in dir.listSync(followLinks: false)) {
      out.add(entity);
      if (entity is Directory) _walkSync(entity, depth == null ? null : depth - 1, out);
    }
  } on FileSystemException {
    // Unreadable: skipped, as `glob` skips it.
  }
  return out;
}

bool _unreadable(Object? e) => e is FileSystemException;

/// [child], under [start], relative to it with forward slashes; a substring, because
/// `p.relative` normalizes per call and dominated a large glob.
String _relative(String start, String child) {
  final rel = child.substring(start.endsWith(p.separator) || start.endsWith('/') ? start.length : start.length + 1);
  return Platform.isWindows ? rel.replaceAll(r'\', '/') : rel;
}

/// A rename that failed only because it crossed filesystems: EXDEV, or Windows' own code.
bool _crossDevice(FileSystemException e) => e.osError?.errorCode == (Platform.isWindows ? 17 : 18);

/// The characters that make a glob segment a pattern rather than a name.
final _wildcard = RegExp(r'[*?[{]');

/// Where the `]` closing the class opened at [open] is, or -1 when it is only a `[`.
int _classEnd(String pattern, int open) {
  var i = open + 1;
  if (i < pattern.length && (pattern[i] == '!' || pattern[i] == '^')) i++;
  // A `]` straight after the opening is one of the set, not its end.
  if (i < pattern.length && pattern[i] == ']') i++;
  final end = pattern.indexOf(']', i);
  return end < 0 || pattern.substring(open, end).contains('/') ? -1 : end;
}

/// Where the `}` closing the brace opened at [open] is, nested braces skipped, or -1 when
/// there is none or only one alternative inside: `b{1}.txt` names itself.
int _braceEnd(String pattern, int open) {
  var depth = 0, choice = false;
  for (var i = open; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == '{') depth++;
    if (c == ',' && depth == 1) choice = true;
    if (c == '}' && --depth == 0) return choice ? i : -1;
  }
  return -1;
}

RegExp _globToRegex(String pattern, {bool? caseSensitive}) {
  final isSensitive = caseSensitive ?? (!Platform.isWindows && !Platform.isMacOS);
  return RegExp(_globSource(pattern), caseSensitive: isSensitive);
}

String _globSource(String pattern) {
  final g = pattern.replaceAll(r'\', '/');
  final buffer = StringBuffer('^');
  // The ends of the braces open around `i`, innermost last: a `,` inside one is `|`.
  final braces = <int>[];
  var i = 0;
  while (i < g.length) {
    final c = g[i];
    final classEnd = c == '[' ? _classEnd(g, i) : -1;
    final braceEnd = c == '{' ? _braceEnd(g, i) : -1;
    if (classEnd > 0) {
      var body = g.substring(i + 1, classEnd);
      final negated = body.startsWith('!') || body.startsWith('^');
      if (negated) body = body.substring(1);
      // Inside a class only `\`, `^` and `[` mean something to RegExp that they do not to a glob.
      body = body.replaceAllMapped(_classEscape, (m) => '\\${m[0]}');
      buffer.write(negated ? '[^/$body]' : '[$body]');
      i = classEnd + 1;
      continue;
    }
    if (g.startsWith('**/', i)) {
      buffer.write('(?:.+/)?');
      i += 3;
      continue;
    }
    if (g.startsWith('**', i)) {
      buffer.write('.*');
      i += 2;
      continue;
    }
    if (braceEnd > 0) {
      braces.add(braceEnd);
      buffer.write('(?:');
    } else if (braces.isNotEmpty && i == braces.last) {
      braces.removeLast();
      buffer.write(')');
    } else {
      buffer.write(switch (c) {
        ',' when braces.isNotEmpty => '|',
        '*' => '[^/]*',
        '?' => '[^/]',
        _ when r'.+()^$[]{}|'.contains(c) => '\\$c',
        _ => c,
      });
    }
    i++;
  }
  return (buffer..write(r'$')).toString();
}

/// Digests and MACs of a file at a [Path].
///
/// {@category Files}
extension PathHashExtensions on Path {
  /// The [algorithm] digest of this file, hex encoded.
  Future<String> hash(Hash algorithm) => asFile.hash(algorithm);

  /// The [algorithm] digest of this file.
  Future<Uint8List> hashBytes(Hash algorithm) => asFile.hashBytes(algorithm);

  /// A 32-bit checksum of this file as an integer: `file.checksum(Hash.crc32c)`.
  Future<int> checksum(Hash algorithm) => asFile.checksum(algorithm);

  /// The HMAC of this file's contents under [key], hex encoded.
  Future<String> hmac(Hash algorithm, List<int> key) => asFile.hmac(algorithm, key);

  /// The HMAC of this file's contents under [key].
  Future<Uint8List> hmacBytes(Hash algorithm, List<int> key) => asFile.hmacBytes(algorithm, key);

  /// The files under this directory that hold the same bytes, in groups of two or more,
  /// largest first; empty files are left out. Only equal sizes are read, by [Hash.xxh3].

  Future<List<List<Path>>> duplicates() => Isolate.run(() {
    final bySize = <int, List<String>>{};
    for (final f in _walkSync(asDir, null).whereType<File>()) {
      (bySize[f.lengthSync()] ??= []).add(f.path);
    }
    bySize.remove(0);
    final candidates = [
      for (final MapEntry(key: size, value: paths) in bySize.entries)
        if (paths.length > 1)
          for (final p in paths) (size, p),
    ];
    final digests = candidates.isEmpty
        ? const <Uint8List>[]
        : Hash.xxh3.filesSync([for (final (_, p) in candidates) p]);
    final groups = <(int, String), List<Path>>{};
    for (var i = 0; i < candidates.length; i++) {
      (groups[(candidates[i].$1, digests[i].hex)] ??= []).add(Path(candidates[i].$2));
    }
    return [
      for (final MapEntry(:value) in groups.entries.toList()..sort((a, b) => b.key.$1.compareTo(a.key.$1)))
        if (value.length > 1) value..sort(),
    ];
  });
}

/// Digests of many files at once: `await paths.hash(Hash.xxh3)`.
///
/// {@category Files}
extension PathsHashExtensions on Iterable<Path> {
  /// Each file's [algorithm] digest, hex encoded, hashed in parallel by the native library.
  Future<Map<Path, String>> hash(Hash algorithm) async {
    final paths = toList();
    if (paths.isEmpty) return {};
    final digests = await algorithm.files([for (final p in paths) p.path]);
    return {for (var i = 0; i < paths.length; i++) paths[i]: digests[i].hex};
  }
}

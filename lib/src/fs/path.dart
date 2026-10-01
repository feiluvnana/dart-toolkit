part of '../../fs.dart';

final _invalidPathChars = RegExp(r'[:*?"<>|\r\n\t]');
final _invalidNameChars = RegExp(r'[/\\:*?"<>|\r\n\t]');
final _whitespaceCollapse = RegExp(r'\s+');
final _braceSlash = RegExp(r'\{[^}]*/');
final _classEscape = RegExp(r'[\\^\[]');

/// Represents the type of filesystem entity at a [Path].
///
/// {@category Files}
enum PathType { file, dir, link, none }

/// A path representation on top of [String] with canonical normalization and filesystem helpers.
///
/// {@category Files}
extension type const Path(String path) implements String {
  /// The user's home directory.
  static Path get home => Path(Env.getOrNull('HOME') ?? Env.getOrNull('USERPROFILE') ?? Directory.current.path);

  /// The system temporary directory. For a directory of your own, see [tempDir].
  static Path get temp => Path(Directory.systemTemp.path);

  /// Runs [body] with a fresh, empty directory under [temp], deletes it and everything in it
  /// afterwards — whether [body] returned or threw — and returns what [body] returned.
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
      // A failed cleanup leaves a folder in the system temp; it must not replace what [body]
      // returned or threw.
      await dir.delete(recursive: true).catchError((Object _) {});
    }
  }

  /// The current working directory.
  static Path get current => Path(Directory.current.path);

  /// Appends [part] to this path.
  Path operator /(String part) => Path(p.join(path, part));

  /// The canonical form of this path, with `.` and `..` segments resolved.
  ///
  /// `Path` is an extension type over [String] and so cannot override `==`:
  /// `Path('/a/b/../b')` and `Path('/a/b')` are distinct map keys. **Normalize at
  /// map boundaries** — `map[p.normalized]` — to make them coincide.
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

  /// This path relative to [from].
  Path relativeTo(String from) => Path(p.relative(path, from: from));

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

  /// Returns the current entity type.
  Future<PathType> type() async => _pathType(await FileSystemEntity.type(path, followLinks: false));

  /// Checks if this path exists on disk.
  Future<bool> exists() async => await type() != PathType.none;

  /// Returns the current entity type synchronously.
  PathType typeSync() => _pathType(FileSystemEntity.typeSync(path, followLinks: false));

  /// Checks synchronously if this path exists on disk.
  bool existsSync() => typeSync() != PathType.none;

  /// When this file or directory was last modified.
  Future<DateTime> modified() async => (await FileStat.stat(path)).modified;

  /// When this file or directory was last modified, synchronously.
  DateTime modifiedSync() => FileStat.statSync(path).modified;

  /// Whether this was last modified more than [age] ago, or is not there at all — the
  /// question a cache asks: `if (await cache.olderThan(1.h)) refresh();`.
  Future<bool> olderThan(Duration age) async {
    final stat = await FileStat.stat(path);
    return stat.type == FileSystemEntityType.notFound || DateTime.now().difference(stat.modified) > age;
  }

  /// Whether this was last modified more than [age] ago, or is not there; see [olderThan].
  bool olderThanSync(Duration age) {
    final stat = FileStat.statSync(path);
    return stat.type == FileSystemEntityType.notFound || DateTime.now().difference(stat.modified) > age;
  }

  /// Creates this file if it does not exist, else sets its modification time to now.
  Future<File> touch() async {
    if (await asFile.exists()) {
      await asFile.setLastModified(DateTime.now());
      return asFile;
    }
    await asFile.parent.create(recursive: true);
    return asFile.create();
  }

  /// Creates this file if it does not exist, else sets its modification time to now.
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

  /// Calculates the file size or recursive directory size in bytes.
  ///
  /// A link is measured as what it points at, as `du -L` does for the path it is given;
  /// links met inside a directory are not followed, so nothing is counted twice.
  ///
  /// A directory is walked in a worker isolate: a stat per file is far faster there than as
  /// one `await` each.
  Future<int> size() async => switch (_pathType(await FileSystemEntity.type(path))) {
    PathType.file => await asFile.length(),
    PathType.dir => await _isolate(_dirSize, path),
    _ => 0,
  };

  /// Calculates the file size or recursive directory size in bytes synchronously.
  int sizeSync() => switch (_pathType(FileSystemEntity.typeSync(path))) {
    PathType.file => asFile.lengthSync(),
    PathType.dir => _dirSize(path),
    _ => 0,
  };

  /// This path with invalid filesystem characters replaced in every component.
  ///
  /// Separators survive, because this is a path. For a single component — a scraped
  /// title that may contain `/` — use [StringPathExtensions.filename].
  Path get sanitized {
    // The root — `/`, `C:\`, `\\server\share` — is kept whole: it is the one place a `:` belongs.
    final root = p.rootPrefix(path);
    return Path(
      root +
          p.joinAll([
            for (final part in p.split(path.substring(root.length)))
              part.replaceAll(_invalidPathChars, '_').replaceAll(_whitespaceCollapse, ' ').trim(),
          ]),
    );
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

  /// Writes [content] string to this file, creating parent directories if not present.
  ///
  /// The write is atomic: the bytes go to a temporary file beside this one, which is then
  /// renamed over it, so a reader — or a ^C halfway — sees the old file or the new one, never
  /// half of either. An existing file keeps its permissions, and a link keeps pointing where
  /// it did, with the file it leads to replaced. A device or a FIFO is written in place.
  Future<File> writeText(String content, {Encoding encoding = utf8}) => writeBytes(encoding.encode(content));

  /// Writes [content] string to this file synchronously, atomically; see [writeText].
  File writeTextSync(String content, {Encoding encoding = utf8}) => writeBytesSync(encoding.encode(content));

  /// Writes raw [bytes] to this file, creating parent directories if not present; atomic, as
  /// [writeText] is.
  Future<File> writeBytes(List<int> bytes) async {
    final (:target, :mode) = _writePlan(path);
    if (target == null) return asFile.writeAsBytes(bytes);
    // A file already there has its folder; only a new one may need it made.
    if (mode == null) await File(target).parent.create(recursive: true);
    final tmp = File(_tempBeside(target));
    try {
      await tmp.writeAsBytes(bytes);
    } on FileSystemException {
      // A folder that takes no new file, around a file that may be written: in place, then.
      await tmp.delete().catchError((Object _) => tmp);
      return asFile.writeAsBytes(bytes);
    }
    try {
      if (mode != null) _chmod(tmp.path, mode);
      await tmp.rename(target);
    } catch (_) {
      await tmp.delete().catchError((Object _) => tmp);
      rethrow;
    }
    return asFile;
  }

  /// Writes raw [bytes] to this file synchronously, atomically; see [writeText].
  File writeBytesSync(List<int> bytes) {
    final (:target, :mode) = _writePlan(path);
    if (target == null) {
      asFile.writeAsBytesSync(bytes);
      return asFile;
    }
    if (mode == null) File(target).parent.createSync(recursive: true);
    final tmp = File(_tempBeside(target));
    try {
      tmp.writeAsBytesSync(bytes);
    } on FileSystemException {
      _deleteQuietly(tmp);
      asFile.writeAsBytesSync(bytes);
      return asFile;
    }
    try {
      if (mode != null) _chmod(tmp.path, mode);
      tmp.renameSync(target);
    } catch (_) {
      _deleteQuietly(tmp);
      rethrow;
    }
    return asFile;
  }

  /// Writes [lines] to this file, each ending in a newline, creating parent directories if
  /// not present; atomic, as [writeText] is.
  Future<File> writeLines(Iterable<String> lines, {Encoding encoding = utf8}) =>
      writeText(lines.map((l) => '$l\n').join(), encoding: encoding);

  /// Writes [lines] to this file synchronously, atomically; see [writeLines].
  File writeLinesSync(Iterable<String> lines, {Encoding encoding = utf8}) =>
      writeTextSync(lines.map((l) => '$l\n').join(), encoding: encoding);

  /// Lists all entities in this directory.
  Stream<Path> list({bool recursive = false, bool followLinks = false}) =>
      asDir.list(recursive: recursive, followLinks: followLinks).map((e) => Path(e.path));

  /// Lists all entities in this directory synchronously.
  List<Path> listSync({bool recursive = false, bool followLinks = false}) =>
      asDir.listSync(recursive: recursive, followLinks: followLinks).map((e) => Path(e.path)).toList();

  /// Lists only files located in this directory.
  Stream<Path> files({bool recursive = false}) =>
      asDir.list(recursive: recursive, followLinks: false).where((e) => e is File).map((e) => Path(e.path));

  /// Lists only files located in this directory synchronously.
  List<Path> filesSync({bool recursive = false}) =>
      asDir.listSync(recursive: recursive, followLinks: false).whereType<File>().map((e) => Path(e.path)).toList();

  /// Lists only subdirectories located in this directory.
  Stream<Path> dirs({bool recursive = false}) =>
      asDir.list(recursive: recursive, followLinks: false).where((e) => e is Directory).map((e) => Path(e.path));

  /// Lists only subdirectories located in this directory synchronously.
  List<Path> dirsSync({bool recursive = false}) =>
      asDir.listSync(recursive: recursive, followLinks: false).whereType<Directory>().map((e) => Path(e.path)).toList();

  /// Lists only symbolic links located in this directory.
  Stream<Path> links({bool recursive = false}) =>
      asDir.list(recursive: recursive, followLinks: false).where((e) => e is Link).map((e) => Path(e.path));

  /// Lists only symbolic links located in this directory synchronously.
  List<Path> linksSync({bool recursive = false}) =>
      asDir.listSync(recursive: recursive, followLinks: false).whereType<Link>().map((e) => Path(e.path)).toList();

  /// Streams the files matching [pattern], e.g. `'**/*.mp3'` or `'lib/**/*.{dart,md}'`.
  ///
  /// `*` is any run within one segment, `**` any number of segments, `?` one character,
  /// `[abc]`, `[a-z]` and `[!abc]` one of (or none of) a set, and `{a,b}` either spelling.
  /// A pattern ending in `/` matches directories instead of files: `'**/test/'`. A link is
  /// matched as itself, like a file, and never followed.
  ///
  /// The walk goes only where the pattern can match: `'build/**/*.o'` descends into
  /// `build`, and a pattern without `**` is never followed deeper than it has segments. An
  /// absolute pattern starts from its own root; a directory that cannot be read is skipped.
  ///
  /// Defaults to platform case sensitivity (case-sensitive on Linux, insensitive on Windows/macOS).
  /// Pass [caseSensitive] to override.
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

  /// Where a [glob] has to start, what it matches from there, and how deep it can go.
  ///
  /// The segments before the first wildcard are a directory, not a pattern, and the
  /// segments after it bound the depth unless one of them is `**`. Walking the whole
  /// subtree and filtering the result instead meant a glob under one directory paid for
  /// every other directory beside it.
  ///
  /// The fourth value is whether the pattern asked for directories, by ending in `/`.
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
    return (
      p.isAbsolute(pattern) ? (prefix.isEmpty ? p.rootPrefix(pattern) : prefix) : p.join(path, prefix),
      rest,
      unbounded ? null : segments.length - fixed,
      dirs,
    );
  }

  /// Creates a directory at this path.
  Future<Directory> mkdir({bool recursive = true}) => asDir.create(recursive: recursive);

  /// Creates a directory at this path synchronously.
  Directory mkdirSync({bool recursive = true}) {
    asDir.createSync(recursive: recursive);
    return asDir;
  }

  /// Creates a symlink at this path pointing to [target].
  Future<Link> symlink(String target) async {
    await asLink.parent.create(recursive: true);
    return asLink.create(target);
  }

  /// Creates a symlink at this path pointing to [target] synchronously.
  Link symlinkSync(String target) {
    asLink.parent.createSync(recursive: true);
    asLink.createSync(target);
    return asLink;
  }

  /// Copies this file, directory or link to [targetPath].
  ///
  /// A link is copied as a link, with the same target, whether it is this path or inside
  /// this directory — as `cp -R` does — so a [move] across devices keeps them.
  Future<void> copy(String targetPath) async {
    switch (await type()) {
      case PathType.file:
        await File(targetPath).parent.create(recursive: true);
        await asFile.copy(targetPath);
      case PathType.link:
        await File(targetPath).parent.create(recursive: true);
        await _deleteNonDir(targetPath);
        await Link(targetPath).create(await asLink.target());
      case PathType.dir:
        if (path == targetPath || p.isWithin(path, targetPath)) {
          throw FileSystemException('Cannot copy a directory into itself', path);
        }
        await Directory(targetPath).create(recursive: true);
        final modes = [(targetPath, (await asDir.stat()).mode)];
        await for (final entity in asDir.list(recursive: true, followLinks: false)) {
          final dest = p.join(targetPath, p.relative(entity.path, from: path));
          switch (entity) {
            case Directory():
              await Directory(dest).create(recursive: true);
              modes.add((dest, (await entity.stat()).mode));
            case Link():
              await File(dest).parent.create(recursive: true);
              await _deleteNonDir(dest);
              await Link(dest).create(await entity.target());
            case File():
              await File(dest).parent.create(recursive: true);
              await entity.copy(dest);
          }
        }
        _restoreModes(modes);
      case PathType.none:
        throw FileSystemException('Cannot copy non-existent path', path);
    }
  }

  /// Copies this file, directory or link to [targetPath] synchronously; see [copy].
  void copySync(String targetPath) {
    switch (typeSync()) {
      case PathType.file:
        File(targetPath).parent.createSync(recursive: true);
        asFile.copySync(targetPath);
      case PathType.link:
        File(targetPath).parent.createSync(recursive: true);
        _deleteNonDirSync(targetPath);
        Link(targetPath).createSync(asLink.targetSync());
      case PathType.dir:
        if (path == targetPath || p.isWithin(path, targetPath)) {
          throw FileSystemException('Cannot copy a directory into itself', path);
        }
        Directory(targetPath).createSync(recursive: true);
        final modes = [(targetPath, asDir.statSync().mode)];
        for (final entity in asDir.listSync(recursive: true, followLinks: false)) {
          final dest = p.join(targetPath, p.relative(entity.path, from: path));
          switch (entity) {
            case Directory():
              Directory(dest).createSync(recursive: true);
              modes.add((dest, entity.statSync().mode));
            case Link():
              File(dest).parent.createSync(recursive: true);
              _deleteNonDirSync(dest);
              Link(dest).createSync(entity.targetSync());
            case File():
              File(dest).parent.createSync(recursive: true);
              entity.copySync(dest);
          }
        }
        _restoreModes(modes);
      case PathType.none:
        throw FileSystemException('Cannot copy non-existent path', path);
    }
  }

  /// Moves this file or directory to [targetPath], copying and deleting across filesystems.
  ///
  /// A directory already at [targetPath] is replaced only when it is empty, as `rename` does.
  Future<void> move(String targetPath) async {
    final t = await type();
    if (t == PathType.none) throw FileSystemException('Cannot move non-existent path', path);
    await File(targetPath).parent.create(recursive: true);
    try {
      await _entity(t).rename(targetPath);
    } on FileSystemException catch (e) {
      // Only a rename across devices becomes copy-and-delete: any other failure — a
      // non-empty directory in the way, a permission — is the answer, and copying over it
      // would merge into the target and then delete the source.
      if (!_crossDevice(e)) rethrow;
      await copy(targetPath);
      await delete(recursive: true);
    }
  }

  /// Moves this file or directory to [targetPath] synchronously, copying and deleting across filesystems.
  void moveSync(String targetPath) {
    final t = typeSync();
    if (t == PathType.none) throw FileSystemException('Cannot move non-existent path', path);
    File(targetPath).parent.createSync(recursive: true);
    try {
      _entity(t).renameSync(targetPath);
    } on FileSystemException catch (e) {
      if (!_crossDevice(e)) rethrow;
      copySync(targetPath);
      deleteSync(recursive: true);
    }
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

  /// Deletes this file, directory, or link synchronously.
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

  /// Appends [content] to this file synchronously, creating parent directories and file if not present.
  File appendSync(String content, {Encoding encoding = utf8}) {
    asFile.parent.createSync(recursive: true);
    asFile.writeAsStringSync(content, mode: FileMode.append, encoding: encoding);
    return asFile;
  }

  /// Rewrites this file, replacing occurrences of [from] with [replacement].
  ///
  /// Writes to disk. The inherited [String.replaceAll] operates on the path text.
  Future<File> replaceText(Pattern from, String replacement, {Encoding encoding = utf8}) async {
    final text = await readText(encoding: encoding);
    return writeText(text.replaceAll(from, replacement), encoding: encoding);
  }

  /// Rewrites this file synchronously, replacing occurrences of [from] with [replacement].
  File replaceTextSync(Pattern from, String replacement, {Encoding encoding = utf8}) {
    final text = readTextSync(encoding: encoding);
    return writeTextSync(text.replaceAll(from, replacement), encoding: encoding);
  }

  /// The paths that changed under this file or directory, a batch at a time: a batch is
  /// sent once nothing has changed for [debounce], so a save that is five events, or a
  /// build that writes a hundred files, is one batch rather than a hundred rebuilds.
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
    out.onListen = () => events = asFile
        .watch(recursive: FileSystemEntity.isDirectorySync(path))
        .listen(
          (e) {
            batch.add(Path(e.path));
            if (e is FileSystemMoveEvent && e.destination != null) batch.add(Path(e.destination!));
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
    return out.stream;
  }
}

/// Convenience extension on [String] to convert to [Path] or join paths.
///
/// {@category Files}
extension StringPathExtensions on String {
  /// Wraps this string into a [Path].
  Path get path => Path(this);

  /// Joins this path with [other].
  Path operator /(String other) => Path(this) / other;

  /// This string as a single path component, safe to join with [Path.operator /].
  ///
  /// Separators and reserved characters become `_`, whitespace runs collapse, and
  /// the result is never empty, `.` or `..`. Use [Path.sanitized] for a whole path, which
  /// keeps its separators.
  Path get filename {
    final cleaned = replaceAll(_invalidNameChars, '_').replaceAll(_whitespaceCollapse, ' ').trim();
    final name = switch (cleaned) {
      '' || '.' => '_',
      '..' => '__',
      _ => cleaned,
    };
    return Path(_capFilename(name));
  }
}

/// What a recursive [Path.size] adds up, in a worker isolate or on this one.
int _dirSize(String path) => Directory(
  path,
).listSync(recursive: true, followLinks: false).whereType<File>().fold(0, (a, f) => a + f.lengthSync());

/// [f] of [arg] in a worker isolate, sent nothing but [arg].
Future<R> _isolate<A, R>(R Function(A) f, A arg) => Isolate.run(() => f(arg));

final _tkChmod = NativeBridge.require()
    .lookupFunction<Int32 Function(Pointer<Uint8>, IntPtr, Uint32), int Function(Pointer<Uint8>, int, int)>('tk_chmod');

void _chmod(String path, int mode) {
  if (NativeBridge.withText(path, (ptr, len) => _tkChmod(ptr, len, mode)) < 0) {
    throw FileSystemException(NativeBridge.lastError(), path);
  }
}

/// Copied directories get their source's modes back, deepest first, once everything is in
/// them: a read-only directory set first would refuse its own contents. Where the native
/// library did not load, or on Windows, where a directory has no mode, they keep the default.
void _restoreModes(List<(String, int)> modes) {
  if (Platform.isWindows || !NativeLib.isAvailable) return;
  for (final (dir, mode) in modes.reversed) {
    _chmod(dir, mode & 0xfff);
  }
}

final _octalMode = RegExp(r'^[0-7]{1,4}$');
final _symbolicClause = RegExp(r'^([ugoa]*)((?:[-+=][rwxXst]*)+)$');
final _symbolicOp = RegExp(r'([-+=])([rwxXst]*)');

/// [mode], octal or symbolic, as the bits to set on [path]; symbolic modes start from its
/// current ones.
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
    // The bits [who] covers: rwx and the special bit of each class.
    var mask = 0;
    if (who.contains('u')) mask |= 0x9c0; // 04700
    if (who.contains('g')) mask |= 0x438; // 02070
    if (who.contains('o')) mask |= 0x207; // 01007
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

/// Where an atomic write renames its temporary file to, and the mode to give it first.
///
/// That is this path, or the file a link here leads to, with the existing file's mode. It
/// is no target at all — write in place — for anything but a regular file or nothing: a
/// device, a FIFO, `/dev/stdout`, a dangling link, which a rename would replace or could not
/// reach; and for an existing file whose mode cannot be carried over because the native
/// library did not load.
({String? target, int? mode}) _writePlan(String path) {
  const inPlace = (target: null, mode: null);
  final stat = FileStat.statSync(path);
  final isLink = FileSystemEntity.isLinkSync(path);
  if (stat.type == FileSystemEntityType.notFound) {
    // `/dev/null` stats as nothing at all, and only `exists` sees it.
    return isLink || File(path).existsSync() ? inPlace : (target: path, mode: null);
  }
  if (stat.type != FileSystemEntityType.file) return inPlace;
  if (Platform.isWindows) return isLink ? inPlace : (target: path, mode: null);
  final target = isLink ? File(path).resolveSymbolicLinksSync() : path;
  // A regular file by its mode, and not one of the kernel's own: `/dev/stdout` redirected
  // to a file is a link to one, and renaming over that would leave the shell's copy behind.
  if (stat.mode & 0xf000 != 0x8000 ||
      !NativeLib.isAvailable ||
      _kernelOwned(p.absolute(path)) ||
      _kernelOwned(target)) {
    return inPlace;
  }
  // A rename replaces a file it could not write, so the permission is asked first: a
  // read-only file refuses this write as it refused one in place.
  File(target).openSync(mode: FileMode.append).closeSync();
  return (target: target, mode: stat.mode & 0xfff);
}

bool _kernelOwned(String path) => path.startsWith('/dev/') || path.startsWith('/proc/');

void _deleteQuietly(File file) {
  try {
    file.deleteSync();
  } on FileSystemException {
    // Never written, or already gone.
  }
}

var _tempCount = 0;

/// A name beside [target] for its next contents, unique to this process and isolate.
String _tempBeside(String target) => p.join(
  p.dirname(target),
  '.${p.basename(target)}.$pid.${DateTime.now().microsecondsSinceEpoch}.${_tempCount++}.tmp',
);

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
  final bytes = utf8.encode(name);
  if (bytes.length <= 255) return name;
  final ext = p.extension(name);
  final extBytes = utf8.encode(ext);
  if (extBytes.length >= 255) {
    return _truncateUtf8(name, 255);
  }
  final base = name.substring(0, name.length - ext.length);
  final budget = 255 - extBytes.length;
  final truncated = _truncateUtf8(base, budget);
  return '$truncated$ext';
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

final _globCache = <(String, bool), RegExp>{};

/// Everything under [dir], at most [depth] levels down, skipping what cannot be read.
///
/// `Directory.list(recursive: true)` has no depth, so a glob that cannot match below its
/// own segment count would still walk everything there; with `**` it is the faster walk.
Stream<FileSystemEntity> _walk(Directory dir, int depth) async* {
  if (depth < 1) return;
  await for (final entity in dir.list(followLinks: false).handleError((_) {}, test: _unreadable)) {
    yield entity;
    if (entity is Directory) yield* _walk(entity, depth - 1);
  }
}

/// [_walk], synchronously; unbounded when [depth] is `null`.
///
/// An unbounded walk is one `listSync(recursive: true)` — about 1.8× faster than a listing
/// per directory — and only when that throws, at the first directory it cannot read, is it
/// walked again a directory at a time so the unreadable one can be skipped.
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

/// [child], somewhere under [start], relative to it and with forward slashes. A substring:
/// `p.relative` normalizes both paths per call and was most of what a large glob cost.
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

/// Where the `}` closing the brace opened at [open] is, nested braces skipped, or -1.
int _braceEnd(String pattern, int open) {
  var depth = 0;
  for (var i = open; i < pattern.length; i++) {
    if (pattern[i] == '{') depth++;
    if (pattern[i] == '}' && --depth == 0) return i;
  }
  return -1;
}

RegExp _globToRegex(String pattern, {bool? caseSensitive}) {
  final isSensitive = caseSensitive ?? (!Platform.isWindows && !Platform.isMacOS);
  final cached = _globCache[(pattern, isSensitive)];
  if (cached != null) return cached;
  final normalized = pattern.replaceAll(r'\', '/');
  final buffer = StringBuffer('^');
  // The ends of the braces open around `i`, innermost last: a `,` inside one is `|`.
  final braces = <int>[];
  var i = 0;
  while (i < normalized.length) {
    final c = normalized[i];
    if (c == '[' && _classEnd(normalized, i) > 0) {
      final end = _classEnd(normalized, i);
      var body = normalized.substring(i + 1, end);
      final negated = body.startsWith('!') || body.startsWith('^');
      if (negated) body = body.substring(1);
      // Inside a class only `\`, `^` and `[` mean something to RegExp that they do not to a glob.
      body = body.replaceAllMapped(_classEscape, (m) => '\\${m[0]}');
      buffer.write(negated ? '[^/$body]' : '[$body]');
      i = end + 1;
      continue;
    }
    if (c == '{' && _braceEnd(normalized, i) > 0) {
      braces.add(_braceEnd(normalized, i));
      buffer.write('(?:');
      i++;
      continue;
    }
    if (braces.isNotEmpty && i == braces.last) {
      braces.removeLast();
      buffer.write(')');
      i++;
      continue;
    }
    if (c == ',' && braces.isNotEmpty) {
      buffer.write('|');
      i++;
      continue;
    }
    if (c == '*' && i + 1 < normalized.length && normalized[i + 1] == '*') {
      if (i + 2 < normalized.length && normalized[i + 2] == '/') {
        buffer.write('(?:.+/)?');
        i += 3;
        continue;
      } else {
        buffer.write('.*');
        i += 2;
        continue;
      }
    } else if (c == '*') {
      buffer.write('[^/]*');
    } else if (c == '?') {
      buffer.write('[^/]');
    } else if (r'.+()^$[]{}|'.contains(c)) {
      buffer.write('\\$c');
    } else {
      buffer.write(c);
    }
    i++;
  }
  buffer.write(r'$');
  return _globCache[(pattern, isSensitive)] = RegExp(buffer.toString(), caseSensitive: isSensitive);
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

  /// The files under this directory that hold the same bytes, each group two or more paths,
  /// the largest files first. Empty files are left out.
  ///
  /// Only files of equal size are compared, by [Hash.xxh3] in parallel, so a tree of unique
  /// sizes costs one walk and no reads at all.
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

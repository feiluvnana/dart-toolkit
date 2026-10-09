part of '../../path.dart';

final _invalidPathChars = RegExp(r'[:*?"<>|\r\n\t]');
final _invalidNameChars = RegExp(r'[/\\:*?"<>|]');
final _whitespaceCollapse = RegExp(r'\s+');
final _controlChars = RegExp(r'[\x00-\x1f]');

/// What Windows strips from a name's end, and the device names it opens whatever the extension.
final _trailingDots = RegExp(r'[. ]+$');
final _deviceName = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)', caseSensitive: false);

/// The type of filesystem entity at a [Path].
///
/// {@category Files}
enum PathType { file, dir, link, none }

/// The order a listing comes back in; without one, the file system's. [natural] sorts
/// `a/2.txt` before `a/10.txt`; the others stat each path once, ties in plain path order.
///
/// {@category Files}
enum Order { natural, newest, oldest, largest, smallest }

/// A batch of changes [PathExtensions.changes] reports.
///
/// {@category Files}
final class FileChanges {
  final Set<Path> added;
  final Set<Path> modified;
  final Set<Path> removed;

  const FileChanges({this.added = const {}, this.modified = const {}, this.removed = const {}});

  bool get isEmpty => added.isEmpty && modified.isEmpty && removed.isEmpty;
  bool get isNotEmpty => !isEmpty;
  Set<Path> get all => {...added, ...modified, ...removed};

  @override
  String toString() => 'FileChanges(added: ${added.length}, modified: ${modified.length}, removed: ${removed.length})';
}

extension on Path {
  String get _p => this;
}

/// Everything a [Path] does: its parts, which are pure and synchronous, and everything that
/// touches the disk, which is async. A long operation (copy, move, delete, trash) is a [Task]:
/// it reports progress, can be cancelled, and a stopped one leaves nothing half-done.
///
/// ```dart
/// final out = Path.cwd / 'out';
/// await (out / 'notes.txt').writeText('hi');                 // atomic
/// await for (final f in out.files(only: '**/*.txt')) print(f.name);
/// await (out / 'notes.txt').copy(into: 'backup').show('Copying');
/// ```
///
/// {@category Files}
extension PathExtensions on Path {
  // ---- parts

  /// [part] appended to this path, normalized. An absolute [part] replaces this path, as
  /// `p.join` has it: `dir / '/etc/x'` is `/etc/x`.
  Path operator /(String part) => Path(p.normalize(p.join(_p, part)));

  /// The canonical form of this path, with `.` and `..` segments resolved.
  ///
  /// Every path the library builds (`/`, `parent`, `withExt`, `relativeTo`, listings) is
  /// already normalized, so `base / 'a' / '..' / 'b' == base / 'b'`. Only a path built by
  /// hand from a raw string can still differ: wrap it in `.normalized` once, where it enters.
  Path get normalized => Path(p.normalize(_p));

  /// The final component (`'song.mp3'`, `'folder'`).
  String get name => p.basename(_p);

  /// The final component without its extension (`'song'` from `'song.mp3'`).
  String get stem => p.basenameWithoutExtension(_p);

  /// The extension without its dot (`'mp3'` from `'song.mp3'`), or `''`. Only the last one:
  /// `'a.tar.gz'` has `'gz'`.
  String get ext {
    final e = p.extension(_p);
    return e.startsWith('.') ? e.substring(1) : e;
  }

  /// The folder this is in.
  Path get parent => Path(p.dirname(_p));

  /// Whether this path starts at a root.
  bool get isAbsolute => p.isAbsolute(_p);

  /// This path made absolute against the working directory, and normalized.
  Path get absolute => Path(p.normalize(p.absolute(_p)));

  /// This path relative to [from], else to the working directory.
  Path relativeTo([String? from]) => Path(p.relative(_p, from: from));

  /// This path with its last extension replaced by [ext], with or without the dot; `''`
  /// removes it.
  Path withExt(String ext) => Path(p.setExtension(_p, ext.isEmpty || ext.startsWith('.') ? ext : '.$ext'));

  /// The individual path segments.
  List<String> get segments => p.split(_p);

  /// This path with invalid filesystem characters replaced, and control characters removed,
  /// in every component; separators survive (on POSIX `\` is a name character, not one). For
  /// one component use [StringPathExtensions.filename].
  Path get sanitized {
    final useSlash = !Platform.isWindows || _p.contains('/') || !_p.contains(r'\');
    final root = p.rootPrefix(_p);
    final rawParts = _p.substring(root.length).split(Platform.isWindows ? RegExp(r'[/\\]') : '/');
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

  // ---- questions

  /// Whether anything, a dangling link included, is at this path.
  Future<bool> exists() async => await type() != PathType.none;

  /// What is here; a link is not followed.
  Future<PathType> type() async => _pathType(await FileSystemEntity.type(_p, followLinks: false));

  /// Whether this is a folder, or a link to one.
  Future<bool> isDir() => FileSystemEntity.isDirectory(_p);

  /// Whether this is a file, or a link to one.
  Future<bool> isFile() => FileSystemEntity.isFile(_p);

  /// Whether this is a link, dangling or not.
  Future<bool> isLink() => FileSystemEntity.isLink(_p);

  /// The size in bytes of this file, or of everything under this folder (links inside not
  /// followed, so nothing counts twice), walked on a worker isolate; a
  /// [PathNotFoundException] when nothing is here. A link here is followed.
  Future<int> size() async => switch (_pathType(await FileSystemEntity.type(_p))) {
    PathType.file => await File(_p).length(),
    PathType.dir => await Isolate.run(() => _dirSize(_p)),
    _ => throw _notFound(_p, 'Cannot measure'),
  };

  /// When this was last modified, or a [PathNotFoundException]: a missing path has no last
  /// modification. [olderThan] answers `true` for one, where that is the question.
  Future<DateTime> modified() async {
    final stat = await FileStat.stat(_p);
    return stat.type == FileSystemEntityType.notFound ? throw _notFound(_p, 'Cannot stat') : stat.modified;
  }

  /// Whether this was last modified more than [age] ago, or is not there at all: the question
  /// a cache asks, `if (await cache.olderThan(1.h)) refresh();`.
  Future<bool> olderThan(Duration age) async {
    final stat = await FileStat.stat(_p);
    return stat.type == FileSystemEntityType.notFound || Clock.current.now().difference(stat.modified) > age;
  }

  /// The bytes free to this user on the volume this path is on, asked on a worker isolate; a
  /// [PathNotFoundException] when nothing is here.
  Future<int> free() async {
    final at = absolute._p;
    final type = await FileSystemEntity.type(at);
    if (type == FileSystemEntityType.notFound) throw _notFound(at, 'Cannot read free space of');
    final dir = type == FileSystemEntityType.directory ? at : p.dirname(at);
    return Isolate.run(() => Platform.isWindows ? _Sys.freeWindows(dir) : _Sys.freePosix(dir));
  }

  // ---- reading

  /// This file's text.
  Future<String> readText({Encoding encoding = utf8}) => File(_p).readAsString(encoding: encoding);

  /// This file's bytes from [start] up to [end] (its length when `null` or past it): a range
  /// past the end is empty. A negative [start], or an [end] before [start], is an
  /// [ArgumentError].
  Future<Uint8List> readBytes({int start = 0, int? end}) async {
    if (start < 0) throw ArgumentError.value(start, 'start', 'Invalid start: negative');
    if (end != null && end < start) throw ArgumentError.value(end, 'end', 'Invalid end: before start ($start)');
    if (start == 0 && end == null) return File(_p).readAsBytes();
    final raf = await File(_p).open();
    try {
      final length = await raf.length();
      final to = end == null || end > length ? length : end;
      if (start >= to) return Uint8List(0);
      await raf.setPosition(start);
      return await raf.read(to - start);
    } finally {
      await raf.close();
    }
  }

  /// This file's lines, read whole. For a large file, [lines] streams them.
  Future<List<String>> readLines({Encoding encoding = utf8}) => File(_p).readAsLines(encoding: encoding);

  /// This file's lines as they are read, in constant memory: decoded as one stream, so a
  /// character or a `\r\n` that two reads cut arrives whole. `\n`, `\r\n` and `\r` end a line.
  ///
  /// ```dart
  /// await for (final line in Path('huge.log').lines()) if (line.contains('ERROR')) print(line);
  /// ```
  Stream<String> lines({Encoding encoding = utf8}) =>
      File(_p).openRead().transform(encoding.decoder).transform(const LineSplitter());

  /// This file's bytes from [start] up to [end] (its length), as they are read; the file is
  /// opened on listen and closed when the stream ends or is cancelled.
  Stream<List<int>> chunks({int start = 0, int? end}) {
    if (start < 0) throw ArgumentError.value(start, 'start', 'Invalid start: negative');
    if (end != null && end < start) throw ArgumentError.value(end, 'end', 'Invalid end: before start ($start)');
    return File(_p).openRead(start, end);
  }

  // ---- writing

  /// Writes [text] to this file, making its folders.
  ///
  /// Atomic: the bytes go to a temporary file beside this one, renamed over it, so a reader
  /// (or a ^C halfway) sees the old file or the new one. An existing file keeps its
  /// permissions, and a link keeps pointing where it did. A device or a FIFO is written in
  /// place, and so is a file in a folder that refuses a new one; any other failure leaves the
  /// old file as it was. The new file is a new inode: hard links and xattrs stay with the old.
  Future<Path> writeText(String text, {Encoding encoding = utf8}) => writeBytes(encoding.encode(text));

  /// Writes [bytes] to this file; atomic, as [writeText] is.
  Future<Path> writeBytes(List<int> bytes) async {
    await FileBridge.write(_p, bytes, chmod: _chmodder);
    return this;
  }

  /// Writes [lines] to this file, each ending in a newline; atomic, as [writeText] is.
  Future<Path> writeLines(Iterable<String> lines, {Encoding encoding = utf8}) =>
      writeText(lines.map((l) => '$l\n').join(), encoding: encoding);

  /// Writes [source] to this file as it arrives; atomic, as [writeText] is, so the file changes
  /// only once [source] is done, and an error in it leaves the old file as it was.
  ///
  /// ```dart
  /// await Path('copy.iso').write(Path('disc.iso').chunks());
  /// ```
  Future<Path> write(Stream<List<int>> source) async {
    await FileBridge.writeStream(_p, source, chmod: _chmodder);
    return this;
  }

  /// Adds [text] to the end of this file, in place, making it and its folders when missing.
  Future<Path> appendText(String text, {Encoding encoding = utf8}) => appendBytes(encoding.encode(text));

  /// Adds [bytes] to the end of this file, in place, making it and its folders when missing.
  Future<Path> appendBytes(List<int> bytes) => append(Stream.value(bytes));

  /// Adds [source] to the end of this file as it arrives, in place, making it and its folders
  /// when missing.
  Future<Path> append(Stream<List<int>> source) async {
    await File(_p).parent.create(recursive: true);
    final sink = File(_p).openWrite(mode: FileMode.append);
    try {
      await sink.addStream(source);
    } finally {
      await sink.close();
    }
    return this;
  }

  /// Rewrites this file with every [from] replaced by [to], atomically.
  Future<Path> replaceText(Pattern from, String to, {Encoding encoding = utf8}) async =>
      writeText((await readText(encoding: encoding)).replaceAll(from, to), encoding: encoding);

  /// Makes this file (and its folders) when missing, else sets its modification time, a
  /// folder's too, to [at] (now when `null`).
  Future<Path> touch({DateTime? at}) async {
    final time = at ?? Clock.current.now();
    switch (await FileSystemEntity.type(_p)) {
      case FileSystemEntityType.notFound:
        await File(_p).create(recursive: true);
        if (at != null) await File(_p).setLastModified(time);
      case FileSystemEntityType.directory:
        _Sys.touchDir(_p, time);
      default:
        await File(_p).setLastModified(time);
    }
    return this;
  }

  /// Sets this path's permission bits, as `chmod` does, through a link: [mode] is octal
  /// (`'755'`, `'0600'`) or symbolic (`'+x'`, `'u+rw,go-w'`, `'a=r'`, which change the bits
  /// there). A [Mode] is checked where it is written, rather than here.
  ///
  /// On Windows only the owner's write bit means anything: without it the file is read-only.
  /// A [mode] that is neither form is a [FormatException]; nothing here is a
  /// [PathNotFoundException]; without the native library this is an [UnsupportedError].
  Future<Path> chmod(String mode) async {
    final bits = await _modeOf(Mode(mode), _p);
    _chmod(_p, bits);
    return this;
  }

  // ---- listings

  /// The files in this folder: everything that is not a folder, a link listed as itself and
  /// never followed.
  ///
  /// Every listing ([files], [dirs], [entries]) takes the same words:
  /// - [only], a glob relative to this folder: `*` any run within one segment, `**` any number
  ///   of segments (a glob with `**` is recursive; one without goes no deeper than its
  ///   segments), `?` one character, `[abc]`/`[a-z]`/`[!abc]` a set, `{a,b}` either. Without
  ///   it, this folder's own entries. Case follows the platform (insensitive on macOS and
  ///   Windows).
  /// - [ignore], `.gitignore` patterns relative to this folder (`'build/'`, `'*.g.dart'`,
  ///   `'!keep.txt'`), and [gitignore], which honours the `.gitignore` files on the way and
  ///   skips `.git`: an ignored folder is never entered.
  /// - [hidden] false leaves out names starting with `.` below this folder, and never enters
  ///   such a folder.
  /// - [newerThan] keeps what changed within that long; [minSize] (files only) what is at
  ///   least that many bytes.
  /// - [order] sorts the listing, which then arrives once complete.
  ///
  /// A folder below that cannot be read is skipped; this folder missing is a
  /// [PathNotFoundException].
  ///
  /// ```dart
  /// final mp3 = dir.files(only: '**/*.mp3', ignore: ['node_modules/'], order: Order.newest);
  /// ```
  Stream<Path> files({
    String? only,
    Iterable<String>? ignore,
    bool gitignore = false,
    bool hidden = true,
    int? minSize,
    Duration? newerThan,
    Order? order,
  }) => _listing(_p, _Kind.files, only, ignore, gitignore, hidden, minSize, newerThan, order);

  /// The folders in this folder; the words are [files]'. A link to a folder is not one.
  Stream<Path> dirs({
    String? only,
    Iterable<String>? ignore,
    bool gitignore = false,
    bool hidden = true,
    Duration? newerThan,
    Order? order,
  }) => _listing(_p, _Kind.dirs, only, ignore, gitignore, hidden, null, newerThan, order);

  /// Everything in this folder, files, folders and links; the words are [files]'.
  Stream<Path> entries({
    String? only,
    Iterable<String>? ignore,
    bool gitignore = false,
    bool hidden = true,
    Duration? newerThan,
    Order? order,
  }) => _listing(_p, _Kind.entries, only, ignore, gitignore, hidden, null, newerThan, order);

  // ---- long operations

  /// Copies this file, folder or link: [to] names the copy, or [into] is a folder it goes in
  /// under its own name; exactly one of them. Answers where it landed.
  ///
  /// A file is copied to a temporary file beside its destination and renamed into place, so a
  /// stopped or failed copy leaves no half file and the destination, if any, as it was. A
  /// folder onto a folder merges, and [conflict] settles each file inside that is already
  /// there: [Conflict.skip] (the default, a rerun neither destroys nor duplicates; nothing
  /// copied is `Done(fresh: false)`), `overwrite` (renamed over, never deleted first),
  /// `rename` (a free `name (1).ext`), `fail` (a [PathExistsException]), `newer`.
  ///
  /// A link is copied as a link, here or inside a folder, as `cp -R` does. Reports bytes for a
  /// file and files for a folder; nothing here is a [PathNotFoundException].
  Task<Path> copy({String? to, String? into, Conflict conflict = Conflict.skip}) {
    final dest = _destination('copy', to, into);
    return TaskInternals.start(this, _label(_p), (work) => _copy(work, _p, dest, conflict));
  }

  /// Moves this file, folder or link: [to] names where, or [into] is a folder it goes in
  /// under its own name; exactly one of them. Answers where it went.
  ///
  /// A rename where it can be one; across devices, a copy (as [copy] makes it) then a delete. A
  /// folder onto a folder merges, [conflict] settling each file as for [copy]; an `overwrite`
  /// is a rename over the file there, never a delete first. Nothing here is a
  /// [PathNotFoundException].
  Task<Path> move({String? to, String? into, Conflict conflict = Conflict.skip}) {
    final dest = _destination('move', to, into);
    return TaskInternals.start(this, _label(_p), (work) => _move(work, _p, dest, conflict));
  }

  /// Deletes this file, link, or empty folder; a folder with anything in it only when
  /// [recursive]. Nothing here is `Done(fresh: false)`, not an error. A link is deleted, never
  /// what it points to.
  Task<void> delete({bool recursive = false}) =>
      TaskInternals.start(this, _label(_p), (work) => _delete(work, _p, recursive));

  /// Deletes every empty folder under this one, deepest first (so a folder holding only empty
  /// ones goes too), and this one if it ends up empty. Reports the folders as it goes; one it
  /// cannot delete is left. This folder missing is a [PathNotFoundException].
  Task<void> deleteEmpty() => TaskInternals.start(this, _label(_p), (work) => _deleteEmpty(work, _p));

  /// Moves this file or folder to the trash of the volume it is on: on macOS `~/.Trash` or the
  /// volume's `.Trashes`, on Linux the XDG trash with its `.trashinfo`, on Windows the Recycle
  /// Bin. A name the trash already holds gets a free `name (n).ext`.
  ///
  /// Where the platform would delete it for good instead (no trash on that volume, a removable
  /// or network drive), it is an [UnsupportedError] and the file stays.
  Task<void> trash() => TaskInternals.start(this, _label(_p), (work) => _trash(work, _p));

  /// Makes this folder, and the folders above it; one already there is `Done(fresh: false)`.
  Task<Path> mkdir() => TaskInternals.start(this, _label(_p), (work) async {
    if (await FileSystemEntity.isDirectory(_p)) TaskInternals.stale(work);
    await Directory(_p).create(recursive: true);
    return this;
  });

  /// Makes this path a link to [target], and its folders; [target] is stored as it is given,
  /// so a relative one is relative to this link's folder.
  Task<Path> symlink(String target) => TaskInternals.start(this, _label(_p), (work) async {
    await Link(_p).create(target, recursive: true);
    return this;
  });

  // ---- watching

  /// The paths that changed under this folder or at this file, a batch at a time once nothing
  /// has changed for [debounce], so a build that writes a hundred files is one rebuild. A file
  /// is watched through its folder, so it outlives atomic writes; their temporary files are
  /// left out. A missing folder fails the stream with a [PathNotFoundException]; the enclosing
  /// [Cancel.scope] ends it with a [CancelledException].
  ///
  /// ```dart
  /// await for (final changed in Path('lib').changes()) rebuild(changed);
  /// ```
  Stream<FileChanges> changes({Duration debounce = const Duration(milliseconds: 200)}) => _changes(_p, debounce);

  /// The lines appended to this file from now on, as `tail -F` follows it: a truncated file is
  /// read again from its start, and so is one replaced by another (a rotated log); a missing
  /// one is waited for. The file is opened per read and never held, so a rotation on Windows
  /// is not blocked. The enclosing [Cancel.scope] ends it with a [CancelledException].
  ///
  /// ```dart
  /// await for (final line in Path('app.log').tail()) if (line.contains('ready')) break;
  /// ```
  Stream<String> tail({Encoding encoding = utf8}) => _tail(_p, encoding);

  /// Runs [body] holding an exclusive lock on this file, across processes and isolates, and
  /// answers what it returned:
  ///
  /// ```dart
  /// await Path('job.lock').lock(() async => publish(), wait: false);
  /// ```
  ///
  /// The file (and its folders) is made when missing and left in place afterwards. The lock is
  /// the operating system's (`fcntl` on POSIX, `LockFileEx` on Windows), so it is released when
  /// the process ends, however it ends. While another holds it, this waits for as long as the
  /// enclosing [Cancel.scope] allows; with [wait] false it is a [FileSystemException] naming the
  /// lock.
  Future<T> lock<T>(FutureOr<T> Function() body, {bool wait = true}) => _lock(_p, body, wait);

  /// The files under this folder that hold the same bytes, in groups of two or more, largest
  /// first, each group sorted; empty files are left out. Only files sharing a size and their
  /// first 4 KiB are read whole. Reports the files sized, then the bytes hashed; this folder
  /// missing is a [PathNotFoundException].
  Task<List<List<Path>>> duplicates() => TaskInternals.start(this, _label(_p), (work) => _duplicates(work, _p));

  /// Where a copy or move to [to] or [into] lands: exactly one of them.
  String _destination(String verb, String? to, String? into) => switch ((to, into)) {
    (final to?, null) => to,
    (null, final into?) => p.join(into, name),
    (null, null) => throw ArgumentError('Cannot $verb $_p: give to: or into:'),
    _ => throw ArgumentError('Cannot $verb $_p: give to: or into:, not both'),
  };
}

/// [String] as a [Path]: `'out'.path`, `'out'.path / 'a.txt'`.
///
/// {@category Files}
extension StringPathExtensions on String {
  /// This string as a [Path].
  Path get path => Path(this);

  /// This string as a single path component, safe to join with [PathExtensions.operator /].
  ///
  /// Separators and reserved characters become `_`, control characters go, whitespace runs
  /// collapse, and the result is never empty, `.` or `..`; at most 255 UTF-8 bytes, keeping
  /// the extension. A trailing `.` or space goes and a Windows device name (`nul.txt`, `COM1`)
  /// gains a leading `_`, on every platform.
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
    final capped = _capFilename(name).replaceFirst(_trailingDots, '');
    return Path(switch (capped) {
      '' => '_',
      _ when _deviceName.hasMatch(capped) => '_$capped',
      _ => capped,
    });
  }
}

/// [path] as a row names it: its folder and name.
String _label(String path) {
  final parts = p.split(path);
  return parts.length < 2 ? path : p.joinAll(parts.sublist(parts.length - 2));
}

/// The [PathNotFoundException] a missing input is, said the same way everywhere.
PathNotFoundException _notFound(String path, [String message = '']) =>
    PathNotFoundException(path, const OSError('No such file or directory', 2), message);

PathType _pathType(FileSystemEntityType type) => switch (type) {
  FileSystemEntityType.file => PathType.file,
  FileSystemEntityType.directory => PathType.dir,
  FileSystemEntityType.link => PathType.link,
  _ => PathType.none,
};

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

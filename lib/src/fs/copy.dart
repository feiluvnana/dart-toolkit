part of '../path.dart';

/// A file past this size is copied by the native library on a worker, reporting its bytes and
/// stopped part way by a cancel; a smaller one by `File.copy`, too quick to need either.
const _nativeCopy = 64 << 20;

/// How many files of a folder are copied or moved at once.
const _fileConcurrency = 8;

final _tkCopyFile = NativeBridge.main
    .require()
    .lookupFunction<
      Int32 Function(Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr, NativeProgress, Pointer<Uint8>),
      int Function(Pointer<Uint8>, int, Pointer<Uint8>, int, NativeProgress, Pointer<Uint8>)
    >('tk_copy_file');

/// What a worker runs to copy [src] to [temp]: only plain values cross with it.
int Function(NativeProgress, Pointer<Uint8>) _copyCall(String src, String temp) => (progress, stop) {
  final code = NativeBridge.main.withText(
    src,
    (s, sl) => NativeBridge.main.withText(temp, (d, dl) => _tkCopyFile(s, sl, d, dl, progress, stop)),
  );
  if (code < 0) {
    final error = NativeBridge.fileError(NativeBridge.main.lastError(), src, 'Cannot copy $src');
    throw error is FormatException ? FileSystemException('Cannot copy: ${error.message}', src) : error;
  }
  return code;
};

/// The temporary files one operation has beside its destinations: what is still there when it
/// ends is deleted, after whatever was writing to it has finished.
final class _Temps {
  final _live = <String>{};
  final _busy = <Future<void>>{};

  _Temps(Work work) {
    work.defer(() async {
      await Future.wait([..._busy]);
      for (final temp in _live) {
        await FileBridge.gone(temp);
      }
    });
  }

  /// A new name beside [target], as an atomic write's temporary file is named, so a watch
  /// leaves it out.
  String beside(String target) {
    final temp = FileBridge.temp(target);
    _live.add(temp);
    return temp;
  }

  /// [temp] renamed into place: nothing to clean up.
  void landed(String temp) => _live.remove(temp);

  /// [future], waited for before anything is deleted.
  Future<T> track<T>(Future<T> future) {
    final settled = future.then<void>((_) {}, onError: (Object _) {});
    _busy.add(settled);
    settled.whenComplete(() => _busy.remove(settled));
    return future;
  }
}

/// Where a write of [src] to [target] goes under [conflict] (the file there, a free name
/// beside it, or `null` to leave it), claimed until [FileBridge.release].
Future<String?> _settle(String src, String target, Conflict conflict, String verb) async => FileBridge.settle(
  target,
  conflict,
  verb: verb,
  subject: src,
  source: conflict == Conflict.newer ? (await FileStat.stat(src)).modified : null,
);

/// Refuses [verb] of the folder [src] to [dest] inside it, however the two are spelled.
Future<void> _refuseInside(String src, String dest, String verb) async {
  final (from, to) = (await _real(src), await _real(dest));
  if (from == to || _isWithin(from, to)) throw FileSystemException('Cannot $verb a folder into itself: $dest', src);
}

/// [path] absolute, with the links on the part of it that exists resolved: `/var/x` and `x`
/// run from `/private/var` are one place.
Future<String> _real(String path) async {
  var head = _canonical(path);
  final tail = <String>[];
  for (;;) {
    try {
      return tail.reversed.fold<String>(await File(head).resolveSymbolicLinks(), _join);
    } on FileSystemException {
      if (_dirname(head) == head) return _canonical(path);
      tail.add(_basename(head));
      head = _dirname(head);
    }
  }
}

/// [_copy]'s and [_move]'s file: [src], a file or a link ([link] when the caller knows), put at
/// [target], whose folder is there, through a temporary file beside it. With [bytes], the
/// copy's bytes are reported on [work].
Future<void> _put(Work work, _Temps temps, String src, String target, {required bool bytes, bool? link}) async {
  final temp = temps.beside(target);
  if (link ?? await FileSystemEntity.isLink(src)) {
    await Link(temp).create(await Link(src).target());
    await FileBridge.rename(Link(temp), target);
  } else {
    final size = bytes || NativeBridge.main.isLoaded ? (await FileStat.stat(src)).size : 0;
    if (size > _nativeCopy && NativeBridge.main.isLoaded) {
      await NativeBridge.main.run(
        work,
        _copyCall(src, temp),
        onProgress: bytes ? (r) => work.amount(r.bytes, total: r.bytesTotal) : null,
      );
    } else {
      await temps.track(File(src).copy(temp));
      if (bytes) work.amount(size, total: size);
    }
    Cancel.check();
    await FileBridge.rename(File(temp), target);
  }
  temps.landed(temp);
}

/// [PathExtensions.copy].
Future<Path> _copy(Work work, String src, String dest, Conflict conflict) async {
  final type = await FileSystemEntity.type(src, followLinks: false);
  if (type == FileSystemEntityType.notFound) throw FileBridge.notFound(src, 'Cannot copy');
  final temps = _Temps(work);
  if (type == FileSystemEntityType.directory) return _copyDir(work, temps, src, dest, conflict);
  final target = await _settle(src, dest, conflict, 'copy');
  if (target == null) {
    TaskInternals.stale(work);
    return Path(dest);
  }
  try {
    if (await _sameFile(src, target)) {
      TaskInternals.stale(work);
      return Path(target);
    }
    await Directory(_dirname(target)).create(recursive: true);
    await _put(work, temps, src, target, bytes: true);
  } finally {
    FileBridge.release(target);
  }
  return Path(target);
}

/// Whether [a] and [b] are one file: a case variant on a disk that does not tell case apart,
/// or a hard link. Copying one onto the other is done already.
Future<bool> _sameFile(String a, String b) async {
  try {
    return await FileSystemEntity.identical(a, b);
  } on FileSystemException {
    return false; // b is not there
  }
}

/// The folder [src] copied to [dest]: built beside it and renamed in when nothing is there, so a
/// stopped copy leaves no half folder; merged into a folder that is there, [conflict] settling
/// each file.
Future<Path> _copyDir(Work work, _Temps temps, String src, String dest, Conflict conflict) async {
  await _refuseInside(src, dest, 'copy');
  switch (await FileSystemEntity.type(dest, followLinks: false)) {
    case FileSystemEntityType.notFound:
      await Directory(_dirname(dest)).create(recursive: true);
      final temp = temps.beside(dest);
      await _fill(work, temps, src, temp, Conflict.fail, fresh: true);
      await FileBridge.rename(Directory(temp), dest);
      temps.landed(temp);
      return Path(dest);
    case FileSystemEntityType.directory:
      if (!await _fill(work, temps, src, dest, conflict)) TaskInternals.stale(work);
      return Path(dest);
    default:
      // A file where the folder would go: the folder is in conflict with it as a whole.
      final target = await _settle(src, dest, conflict, 'copy');
      if (target == null) {
        TaskInternals.stale(work);
        return Path(dest);
      }
      FileBridge.release(target);
      if (target == dest) throw FileSystemException('Cannot copy a folder over a file: $dest', src);
      return _copyDir(work, temps, src, target, conflict);
  }
}

/// The folder [from], under a folder of the destination, put at [to]: the folder there, one
/// made, or `null` when [conflict] leaves it out. A file or link in its way is never walked
/// through: `overwrite` replaces it with the folder, `rename` makes the folder at a free name
/// beside it. [made] gets each folder made, with its source's mode.
Future<String?> _folder(String from, String to, Conflict conflict, String verb, List<(String, int)> made) async {
  var target = to;
  switch (await FileSystemEntity.type(to, followLinks: false)) {
    case FileSystemEntityType.directory:
      return to;
    case FileSystemEntityType.notFound:
      break;
    default:
      final settled = await _settle(from, to, conflict, verb);
      if (settled == null) return null;
      FileBridge.release(settled);
      // A rename over a file cannot put a folder there: the file goes, then the folder is made.
      if (settled == to) await FileBridge.gone(to);
      target = settled;
  }
  await Directory(target).create();
  made.add((target, (await FileStat.stat(from)).mode));
  return target;
}

/// Where [path]'s last separator is.
int _lastSeparator(String path) {
  final slash = path.lastIndexOf('/');
  if (!Platform.isWindows) return slash;
  final back = path.lastIndexOf(r'\');
  return back > slash ? back : slash;
}

/// At most [_fileConcurrency] bodies at once: [add] waits for a free slot, so what waits is
/// never more than the slots. The first failure stops what is not yet added, and [drain]
/// throws it once everything running has ended.
final class _Slots {
  final _running = <Future<void>>{};
  (Object, StackTrace)? _failed;

  Future<void> add(Future<void> Function() body) async {
    while (_running.length >= _fileConcurrency) {
      await Future.any(_running);
    }
    _throwFailed();
    Cancel.check();
    late final Future<void> running;
    running = body()
        .catchError((Object e, StackTrace s) => _failed ??= (e, s))
        .whenComplete(() => _running.remove(running));
    _running.add(running);
  }

  Future<void> drain() async {
    await Future.wait([..._running]);
    _throwFailed();
  }

  void _throwFailed() {
    if (_failed case (final e, final s)) Error.throwWithStackTrace(e, s);
  }
}

/// Everything under the folder [src] put into the folder [dest], which is there: each file
/// settled by [conflict], and so is a folder that a file or link stands in the way of. Folder by
/// folder, so only one folder's listing is held, [_fileConcurrency] files at a time; with
/// [move], each file is renamed and the folders it empties go. [Conflict.fail] checks every
/// name before anything is written, unless [fresh] says [dest] was just made. With [count], it
/// reports the files. Answers whether any was written.
Future<bool> _merge(
  Work work,
  _Temps temps,
  String src,
  String dest,
  Conflict conflict, {
  required bool move,
  bool fresh = false,
  bool count = true,
  List<(String, int)>? made,
  String? verb,
  String? subject,
}) async {
  final doing = verb ?? (move ? 'move' : 'copy');
  final root = _trimmed(src);
  var total = 0;
  if (count || (conflict == Conflict.fail && !fresh)) {
    await for (final e in Directory(root).list(recursive: true, followLinks: false)) {
      if (e is! Directory) total++;
      if (conflict != Conflict.fail || fresh) continue;
      final to = _join(dest, _relative(root, e.path));
      final there = await FileSystemEntity.type(to, followLinks: false);
      if (there == FileSystemEntityType.notFound || (e is Directory && there == FileSystemEntityType.directory)) {
        continue;
      }
      throw PathExistsException(to, const OSError(), 'Cannot $doing ${subject ?? e.path}: $to exists');
    }
  }
  final folders = made ?? [];
  // The source folders, parents first, so they go deepest first once emptied.
  final dirs = <String>[];
  final slots = _Slots();
  var done = 0, wrote = false;
  if (count) work.amount(0, total: total, unit: Unit.items);
  Future<void> put(String from, String to, bool link) async {
    final target = await _settle(from, to, conflict, doing);
    if (target != null) {
      try {
        if (move) {
          await _rename(work, temps, from, target, isDir: false, link: link, bytes: false);
        } else {
          await _put(work, temps, from, target, bytes: false, link: link);
        }
        wrote = true;
      } finally {
        FileBridge.release(target);
      }
    }
    work.step(_relative(root, from));
    if (count) work.amount(++done, total: total, unit: Unit.items);
  }

  final pending = [(root, dest)];
  while (pending.isNotEmpty) {
    final (from, into) = pending.removeLast();
    // Listed whole before anything moves: a folder read while files leave it can skip some.
    for (final entity in await Directory(from).list(followLinks: false).toList()) {
      final to = _join(into, entity.path.substring(_lastSeparator(entity.path) + 1));
      if (entity is Directory) {
        dirs.add(entity.path);
        final target = await _folder(entity.path, to, conflict, doing, folders);
        if (target != null) pending.add((entity.path, target));
      } else {
        await slots.add(() => put(entity.path, to, entity is Link));
      }
    }
  }
  await slots.drain();
  _restoreModes(folders);
  if (move) {
    // Emptied folders go, deepest first; one a skip left a file in stays.
    for (final dir in [...dirs.reversed, root]) {
      try {
        await Directory(dir).delete();
      } on FileSystemException catch (_) {} // not empty: a skipped file is still in it
    }
  }
  return wrote;
}

/// [path] without the separators it ends in, as a listing's entries name their folder.
String _trimmed(String path) {
  var end = path.length;
  while (end > 1 && _lastSeparator(path.substring(0, end)) == end - 1) {
    end--;
  }
  return path.substring(0, end);
}

/// Everything under [src] put into the folder [dest], made when missing (then [fresh]); each
/// file settled by [conflict]. Reports the files; answers whether any was written.
Future<bool> _fill(Work work, _Temps temps, String src, String dest, Conflict conflict, {bool fresh = false}) async {
  final made = <(String, int)>[];
  // A folder that was there keeps its own mode: only the ones made here get the source's.
  if (!await Directory(dest).exists()) {
    await Directory(dest).create(recursive: true);
    made.add((dest, (await FileStat.stat(src)).mode));
  }
  return _merge(work, temps, src, dest, conflict, move: false, fresh: fresh, made: made);
}

/// [PathExtensions.move].
Future<Path> _move(Work work, String src, String dest, Conflict conflict) async {
  final type = await FileSystemEntity.type(src, followLinks: false);
  if (type == FileSystemEntityType.notFound) throw FileBridge.notFound(src, 'Cannot move');
  if (_equals(_absolute(src), _absolute(dest))) {
    TaskInternals.stale(work);
    return Path(dest);
  }
  final isDir = type == FileSystemEntityType.directory;
  if (isDir) await _refuseInside(src, dest, 'move');
  if (isDir && await FileSystemEntity.type(dest, followLinks: false) == FileSystemEntityType.directory) {
    return _mergeMove(work, src, dest, conflict);
  }
  // Settled even when nothing is there: the claim keeps a second move from landing on it too.
  final target = await _settle(src, dest, conflict, 'move');
  if (target == null) {
    TaskInternals.stale(work);
    return Path(dest);
  }
  try {
    if (isDir && await FileSystemEntity.type(target, followLinks: false) != FileSystemEntityType.notFound) {
      throw FileSystemException('Cannot move a folder over a file: $target', src);
    }
    await Directory(_dirname(target)).create(recursive: true);
    await _rename(work, _Temps(work), src, target, isDir: isDir, link: type == FileSystemEntityType.link);
  } finally {
    FileBridge.release(target);
  }
  return Path(target);
}

/// [src] renamed to [target]; across devices, copied there (as [_copy] copies, so atomically)
/// and then deleted, a file's bytes reported when [bytes]. A file renamed over a file replaces
/// it in one step.
Future<void> _rename(
  Work work,
  _Temps temps,
  String src,
  String target, {
  required bool isDir,
  required bool link,
  bool bytes = true,
}) async {
  try {
    final entity = isDir
        ? Directory(src)
        : link
        ? Link(src)
        : File(src) as FileSystemEntity;
    await FileBridge.rename(entity, target);
    return;
  } on FileSystemException catch (e) {
    if (!_crossDevice(e)) rethrow;
  }
  if (isDir) {
    final temp = temps.beside(target);
    await _fill(work, temps, src, temp, Conflict.fail, fresh: true);
    await FileBridge.rename(Directory(temp), target);
    temps.landed(temp);
    await Directory(src).delete(recursive: true);
  } else {
    await _put(work, temps, src, target, bytes: bytes, link: link);
    await _deleteOne(src);
  }
}

/// The folder [src] moved into the folder [dest]: each file renamed into place and settled by
/// [conflict], as is a folder a file or link stands in the way of; what a skip leaves behind
/// stays in [src], with its folders.
Future<Path> _mergeMove(Work work, String src, String dest, Conflict conflict) async {
  if (!await _merge(work, _Temps(work), src, dest, conflict, move: true)) TaskInternals.stale(work);
  return Path(dest);
}

/// What `archive` merges an extraction through: the moves of `copy.dart` and the path grammar,
/// from outside `path`. Not API.
abstract final class PathInternals {
  /// [path] against the working directory, not normalized.
  static String absolute(String path) => _absolute(path);

  /// Whether [a] and [b] are one place, however each is spelled.
  static bool equals(String a, String b) => _equals(a, b);

  /// Whether [child] is strictly under [parent].
  static bool isWithin(String parent, String child) => _isWithin(parent, child);

  /// Runs [body] reading paths the Windows way when [windows] (else the POSIX way), against the
  /// working directory [cwd]: how the tests check both grammars on one machine.
  static T styled<T>(T Function() body, {required bool windows, String? cwd}) {
    final (wasWindows, wasCwd) = (_windows, _cwdOverride);
    _windows = windows;
    _cwdOverride = cwd;
    try {
      return body();
    } finally {
      _windows = wasWindows;
      _cwdOverride = wasCwd;
    }
  }

  /// What is under the folder [from] moved into the folder [into], made when missing, as a
  /// folder move merges (with [Conflict.fail] checking every name first); [flatten]ed, every
  /// file and link lands in [into] itself, a folder of its name making it take a free one.
  /// Reports only its step. Answers whether anything moved.
  /// [subject] names what is merged in a [PathExistsException]: `Cannot unarchive <subject>`.
  static Future<bool> merge(
    Work work,
    String from,
    String into,
    Conflict conflict, {
    required bool flatten,
    required String subject,
  }) async {
    await Directory(into).create(recursive: true);
    work.step('merging');
    if (!flatten) {
      return _merge(
        work,
        _Temps(work),
        from,
        into,
        conflict,
        move: true,
        count: false,
        verb: 'unarchive',
        subject: subject,
      );
    }
    final moves = [
      await for (final e in Directory(from).list(recursive: true, followLinks: false))
        if (e is! Directory) (e, _join(into, _basename(e.path))),
    ];
    if (conflict == Conflict.fail) {
      final names = <String>{};
      for (final (_, to) in moves) {
        if (!names.add(to) || await FileSystemEntity.type(to, followLinks: false) != FileSystemEntityType.notFound) {
          throw PathExistsException(to, const OSError(), 'Cannot unarchive $subject: $to exists');
        }
      }
    }
    var moved = false;
    for (final (entity, to) in moves) {
      // A folder of that name is no file to replace or skip for: the file takes a free name.
      final policy = await FileSystemEntity.isDirectory(to) ? Conflict.rename : conflict;
      final target = await _settle(entity.path, to, policy, 'unarchive');
      if (target == null) continue;
      try {
        await FileBridge.rename(entity, target);
        moved = true;
      } finally {
        FileBridge.release(target);
      }
    }
    return moved;
  }
}

/// A rename that failed only because it crossed file systems: EXDEV, or Windows' own code.
bool _crossDevice(FileSystemException e) => e.osError?.errorCode == (Platform.isWindows ? 17 : 18);

/// Deletes the file or link at [path]; on Windows a read-only one is made writable first.
Future<void> _deleteOne(String path) async {
  final entity = await FileSystemEntity.isLink(path) ? Link(path) : File(path) as FileSystemEntity;
  try {
    await entity.delete();
  } on FileSystemException catch (e) {
    if (!Platform.isWindows || e.osError?.errorCode != 5 || entity is Link) rethrow;
    _chmod(path, 0x1b6); // 0666: no longer read-only
    await entity.delete();
  }
}

/// [PathExtensions.delete].
Future<void> _delete(Work work, String path, bool recursive) async {
  switch (await FileSystemEntity.type(path, followLinks: false)) {
    case FileSystemEntityType.notFound:
      TaskInternals.stale(work);
    case FileSystemEntityType.directory:
      try {
        await Directory(path).delete(recursive: recursive);
      } on FileSystemException catch (e) {
        // A read-only file in it refuses on Windows: made writable, then deleted.
        if (!Platform.isWindows || !recursive || e.osError?.errorCode != 5) rethrow;
        await for (final entity in Directory(path).list(recursive: true, followLinks: false)) {
          if (entity is! Link) _chmod(entity.path, 0x1b6);
        }
        await Directory(path).delete(recursive: true);
      }
    default:
      await _deleteOne(path);
  }
}

/// [PathExtensions.deleteEmpty].
Future<void> _deleteEmpty(Work work, String root) async {
  if (!await Directory(root).exists()) throw FileBridge.notFound(root, 'Cannot delete empty folders in');
  final dirs = [
    await for (final e in Directory(
      root,
    ).list(recursive: true, followLinks: false).handleError((_) {}, test: _below(root)))
      if (e is Directory) e.path,
  ]..sort((a, b) => b.length.compareTo(a.length));
  var done = 0;
  for (final dir in [...dirs, root]) {
    Cancel.check();
    try {
      await Directory(dir).delete();
    } on FileSystemException catch (_) {} // not empty, or not ours to delete: left
    work.amount(++done, total: dirs.length + 1, unit: Unit.items);
  }
}

/// [PathExtensions.trash].
Future<void> _trash(Work work, String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return TaskInternals.stale(work);
  final at = _absolute(path);
  if (Platform.isWindows) return Isolate.run(() => _Sys.recycle(at));
  final entity = switch (type) {
    FileSystemEntityType.directory => Directory(at),
    FileSystemEntityType.link => Link(at),
    _ => File(at) as FileSystemEntity,
  };
  if (Platform.isMacOS) return _trashMac(entity);
  if (Platform.isLinux) return _trashLinux(entity);
  throw UnsupportedError('Cannot trash $path: no trash on ${Platform.operatingSystem}');
}

/// [entity] into `~/.Trash`, or into its volume's `.Trashes/<uid>` when it is on another one:
/// never a copy across volumes.
Future<void> _trashMac(FileSystemEntity entity) async {
  final home = _join(Path.home, '.Trash');
  await Directory(home).create(recursive: true);
  if (await _trashInto(entity, home) case final _?) return;
  final top = await _mountOf(entity.path);
  final bin = _join(_join(top, '.Trashes'), '${_Sys.uid()}');
  try {
    await Directory(bin).create(recursive: true);
  } on FileSystemException {
    throw UnsupportedError('Cannot trash ${entity.path}: its volume has no trash this user can write');
  }
  if (await _trashInto(entity, bin) == null) {
    throw UnsupportedError('Cannot trash ${entity.path}: its volume has no trash on it');
  }
}

/// [entity] renamed into the folder [bin] under a free name; `null` when [bin] is on another
/// volume, where a move would be a copy.
Future<String?> _trashInto(FileSystemEntity entity, String bin, {Future<void> Function(String name)? before}) async {
  final target = FileBridge.settle(
    _join(bin, _basename(entity.path)),
    Conflict.rename,
    verb: 'trash',
    subject: entity.path,
  )!;
  try {
    await before?.call(_basename(target));
    await FileBridge.rename(entity, target);
    return target;
  } on FileSystemException catch (e) {
    if (_crossDevice(e)) return null;
    rethrow;
  } finally {
    FileBridge.release(target);
  }
}

/// The folder [path]'s volume is mounted at: the highest folder above it on the same device.
Future<String> _mountOf(String path) async {
  final id = _fileId(path) ?? (throw UnsupportedError('Cannot find the volume of $path without the native library'));
  var top = _dirname(path);
  while (_dirname(top) != top && _fileId(_dirname(top))?.$1 == id.$1) {
    top = _dirname(top);
  }
  return top;
}

/// [entity] into the XDG trash: the home trash when it is on that volume, else its volume's
/// `.Trash/<uid>` (when an administrator made one, sticky and no link) or `.Trash-<uid>`. Its
/// `.trashinfo` is written first, and removed again if the move fails.
Future<void> _trashLinux(FileSystemEntity entity) async {
  final data = Env.get<String?>('XDG_DATA_HOME') ?? _join(_join(Path.home, '.local'), 'share');
  final at = entity.path;
  Future<String?> into(String trash, String Function(String path) named) async {
    final files = _join(trash, 'files'), info = _join(trash, 'info');
    await Directory(files).create(recursive: true);
    await Directory(info).create(recursive: true);
    String? record;
    final date = Clock.current.now().format('yyyy-MM-ddTHH:mm:ss');
    try {
      final moved = await _trashInto(
        entity,
        files,
        before: (name) async {
          record = _join(info, '$name.trashinfo');
          await File(record!).writeAsString('[Trash Info]\nPath=${named(at)}\nDeletionDate=$date\n');
        },
      );
      if (moved == null && record != null) await File(record!).delete();
      return moved;
    } catch (_) {
      if (record != null) await FileBridge.gone(record!);
      rethrow;
    }
  }

  if (await into(_join(data, 'Trash'), (path) => Uri.file(path).path) != null) return;
  final top = await _mountOf(at);
  String relative(String path) => Uri.file(_relativePath(path, from: top)).path;
  final shared = _join(top, '.Trash');
  final sharedStat = await FileStat.stat(shared);
  if (sharedStat.type == FileSystemEntityType.directory &&
      !await FileSystemEntity.isLink(shared) &&
      sharedStat.mode & 0x200 != 0) {
    if (await into(_join(shared, '${_Sys.uid()}'), relative) != null) return;
  }
  try {
    if (await into(_join(top, '.Trash-${_Sys.uid()}'), relative) != null) return;
  } on FileSystemException {
    // No trash this user can make on that volume: refused below.
  }
  throw UnsupportedError('Cannot trash $at: its volume has no trash on it');
}

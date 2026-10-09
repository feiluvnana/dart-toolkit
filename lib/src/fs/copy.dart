part of '../../path.dart';

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
        await _gone(temp);
      }
    });
  }

  /// A new name beside [target], as an atomic write's temporary file is named, so a watch
  /// leaves it out.
  String beside(String target) {
    final temp = p.join(p.dirname(target), '.${p.basename(target)}.${FileBridge.token()}.tmp');
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

/// [path] deleted, whatever it is; one already gone is no matter.
Future<void> _gone(String path) async {
  try {
    switch (await FileSystemEntity.type(path, followLinks: false)) {
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      case FileSystemEntityType.notFound:
        return;
      case FileSystemEntityType.link:
        await Link(path).delete();
      default:
        await File(path).delete();
    }
  } on FileSystemException catch (_) {} // gone already, or not ours to delete: left
}

/// Throws a [CancelledException] when [work] has been asked to stop.
void _check(Work work) {
  if (work.isStopped) throw CancelledException('${Cancel.reason ?? 'cancelled'}');
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
  if (from == to || p.isWithin(from, to)) throw FileSystemException('Cannot $verb a folder into itself: $dest', src);
}

/// [path] absolute, with the links on the part of it that exists resolved: `/var/x` and `x`
/// run from `/private/var` are one place.
Future<String> _real(String path) async {
  var head = p.canonicalize(path);
  final tail = <String>[];
  for (;;) {
    try {
      return p.joinAll([await File(head).resolveSymbolicLinks(), ...tail.reversed]);
    } on FileSystemException {
      if (p.dirname(head) == head) return p.canonicalize(path);
      tail.add(p.basename(head));
      head = p.dirname(head);
    }
  }
}

/// [_copy]'s and [_move]'s file: [src], a file or a link, put at [target] through a temporary
/// file beside it. With [bytes], the copy's bytes are reported on [work].
Future<void> _put(Work work, _Temps temps, String src, String target, {required bool bytes}) async {
  await Directory(p.dirname(target)).create(recursive: true);
  final temp = temps.beside(target);
  if (await FileSystemEntity.isLink(src)) {
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
    _check(work);
    await FileBridge.rename(File(temp), target);
  }
  temps.landed(temp);
}

/// [PathExtensions.copy].
Future<Path> _copy(Work work, String src, String dest, Conflict conflict) async {
  final type = await FileSystemEntity.type(src, followLinks: false);
  if (type == FileSystemEntityType.notFound) throw _notFound(src, 'Cannot copy');
  final temps = _Temps(work);
  if (type == FileSystemEntityType.directory) return _copyDir(work, temps, src, dest, conflict);
  final target = await _settle(src, dest, conflict, 'copy');
  if (target == null || await _sameFile(src, target)) {
    TaskInternals.stale(work);
    return Path(target ?? dest);
  }
  try {
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
      await Directory(p.dirname(dest)).create(recursive: true);
      final temp = temps.beside(dest);
      await _fill(work, temps, src, temp, Conflict.fail);
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

/// Everything under [src] put into the folder [dest], made when missing; each file settled by
/// [conflict]. Reports the files; answers whether any was written.
Future<bool> _fill(Work work, _Temps temps, String src, String dest, Conflict conflict) async {
  final made = <(String, int)>[];
  final files = <(String from, String to)>[];
  await Directory(dest).create(recursive: true);
  made.add((dest, (await FileStat.stat(src)).mode));
  await for (final entity in Directory(src).list(recursive: true, followLinks: false)) {
    final to = p.join(dest, _relative(src, entity.path));
    if (entity is Directory) {
      final there = await Directory(to).exists();
      await Directory(to).create(recursive: true);
      if (!there) made.add((to, (await entity.stat()).mode));
    } else {
      files.add((entity.path, to));
    }
  }
  var done = 0, wrote = false;
  work.amount(0, total: files.length, unit: Unit.items);
  for (var i = 0; i < files.length; i += _fileConcurrency) {
    _check(work);
    await Future.wait([
      for (final (from, to) in files.skip(i).take(_fileConcurrency))
        () async {
          final target = await _settle(from, to, conflict, 'copy');
          if (target != null) {
            try {
              await _put(work, temps, from, target, bytes: false);
              wrote = true;
            } finally {
              FileBridge.release(target);
            }
          }
          work
            ..step(_relative(src, from))
            ..amount(++done, total: files.length, unit: Unit.items);
        }(),
    ]);
  }
  _restoreModes(made);
  return wrote;
}

/// [PathExtensions.move].
Future<Path> _move(Work work, String src, String dest, Conflict conflict) async {
  final type = await FileSystemEntity.type(src, followLinks: false);
  if (type == FileSystemEntityType.notFound) throw _notFound(src, 'Cannot move');
  if (p.equals(p.absolute(src), p.absolute(dest))) {
    TaskInternals.stale(work);
    return Path(dest);
  }
  final isDir = type == FileSystemEntityType.directory;
  if (isDir) await _refuseInside(src, dest, 'move');
  final there = await FileSystemEntity.type(dest, followLinks: false);
  if (isDir && there == FileSystemEntityType.directory) return _mergeMove(work, src, dest, conflict);
  final target = there == FileSystemEntityType.notFound ? dest : await _settle(src, dest, conflict, 'move');
  if (target == null) {
    TaskInternals.stale(work);
    return Path(dest);
  }
  try {
    if (isDir && await FileSystemEntity.type(target, followLinks: false) != FileSystemEntityType.notFound) {
      throw FileSystemException('Cannot move a folder over a file: $target', src);
    }
    await Directory(p.dirname(target)).create(recursive: true);
    await _rename(work, src, target, isDir: isDir);
  } finally {
    FileBridge.release(target);
  }
  return Path(target);
}

/// [src] renamed to [target]; across devices, copied there (as [_copy] copies, so atomically)
/// and then deleted, a file's bytes reported when [bytes]. A file renamed over a file replaces
/// it in one step.
Future<void> _rename(Work work, String src, String target, {required bool isDir, bool bytes = true}) async {
  try {
    final entity = isDir
        ? Directory(src)
        : await FileSystemEntity.isLink(src)
        ? Link(src)
        : File(src) as FileSystemEntity;
    await FileBridge.rename(entity, target);
    return;
  } on FileSystemException catch (e) {
    if (!_crossDevice(e)) rethrow;
  }
  final temps = _Temps(work);
  if (isDir) {
    final temp = temps.beside(target);
    await _fill(work, temps, src, temp, Conflict.fail);
    await FileBridge.rename(Directory(temp), target);
    temps.landed(temp);
    await Directory(src).delete(recursive: true);
  } else {
    await _put(work, temps, src, target, bytes: bytes);
    await _deleteOne(src);
  }
}

/// The folder [src] moved into the folder [dest]: each file renamed into place and settled by
/// [conflict]; what a skip leaves behind stays in [src], with its folders.
Future<Path> _mergeMove(Work work, String src, String dest, Conflict conflict) async {
  final files = <(String from, String to)>[];
  final dirs = <String>[];
  await for (final entity in Directory(src).list(recursive: true, followLinks: false)) {
    final to = p.join(dest, _relative(src, entity.path));
    if (entity is Directory) {
      dirs.add(entity.path);
      await Directory(to).create(recursive: true);
    } else {
      files.add((entity.path, to));
    }
  }
  var done = 0, moved = false;
  work.amount(0, total: files.length, unit: Unit.items);
  for (var i = 0; i < files.length; i += _fileConcurrency) {
    _check(work);
    await Future.wait([
      for (final (from, to) in files.skip(i).take(_fileConcurrency))
        () async {
          final target = await _settle(from, to, conflict, 'move');
          if (target != null) {
            try {
              await _rename(work, from, target, isDir: false, bytes: false);
              moved = true;
            } finally {
              FileBridge.release(target);
            }
          }
          work
            ..step(_relative(src, from))
            ..amount(++done, total: files.length, unit: Unit.items);
        }(),
    ]);
  }
  // Emptied folders go, deepest first; one a skip left a file in stays.
  for (final dir in [...dirs.reversed, src]) {
    try {
      await Directory(dir).delete();
    } on FileSystemException catch (_) {} // not empty: a skipped file is still in it
  }
  if (!moved) TaskInternals.stale(work);
  return Path(dest);
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
  if (!await Directory(root).exists()) throw _notFound(root, 'Cannot delete empty folders in');
  final dirs = [
    await for (final e in Directory(
      root,
    ).list(recursive: true, followLinks: false).handleError((_) {}, test: _below(root)))
      if (e is Directory) e.path,
  ]..sort((a, b) => b.length.compareTo(a.length));
  var done = 0;
  for (final dir in [...dirs, root]) {
    _check(work);
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
  final at = p.absolute(path);
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
  final home = p.join(Path.home, '.Trash');
  await Directory(home).create(recursive: true);
  if (await _trashInto(entity, home) case final _?) return;
  final top = await _mountOf(entity.path);
  final bin = p.join(top, '.Trashes', '${_Sys.uid()}');
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
    p.join(bin, p.basename(entity.path)),
    Conflict.rename,
    verb: 'trash',
    subject: entity.path,
  )!;
  try {
    await before?.call(p.basename(target));
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
  var top = p.dirname(path);
  while (p.dirname(top) != top && _fileId(p.dirname(top))?.$1 == id.$1) {
    top = p.dirname(top);
  }
  return top;
}

/// [entity] into the XDG trash: the home trash when it is on that volume, else its volume's
/// `.Trash/<uid>` (when an administrator made one, sticky and no link) or `.Trash-<uid>`. Its
/// `.trashinfo` is written first, and removed again if the move fails.
Future<void> _trashLinux(FileSystemEntity entity) async {
  final data = Env.get<String?>('XDG_DATA_HOME') ?? p.join(Path.home, '.local', 'share');
  final at = entity.path;
  Future<String?> into(String trash, String Function(String path) named) async {
    final files = p.join(trash, 'files'), info = p.join(trash, 'info');
    await Directory(files).create(recursive: true);
    await Directory(info).create(recursive: true);
    String? record;
    final date = Clock.current.now().format('yyyy-MM-ddTHH:mm:ss');
    try {
      final moved = await _trashInto(
        entity,
        files,
        before: (name) async {
          record = p.join(info, '$name.trashinfo');
          await File(record!).writeAsString('[Trash Info]\nPath=${named(at)}\nDeletionDate=$date\n');
        },
      );
      if (moved == null && record != null) await File(record!).delete();
      return moved;
    } catch (_) {
      if (record != null) await _gone(record!);
      rethrow;
    }
  }

  if (await into(p.join(data, 'Trash'), (path) => Uri.file(path).path) != null) return;
  final top = await _mountOf(at);
  String relative(String path) => Uri.file(p.relative(path, from: top)).path;
  final shared = p.join(top, '.Trash');
  final sharedStat = await FileStat.stat(shared);
  if (sharedStat.type == FileSystemEntityType.directory &&
      !await FileSystemEntity.isLink(shared) &&
      sharedStat.mode & 0x200 != 0) {
    if (await into(p.join(shared, '${_Sys.uid()}'), relative) != null) return;
  }
  try {
    if (await into(p.join(top, '.Trash-${_Sys.uid()}'), relative) != null) return;
  } on FileSystemException {
    // No trash this user can make on that volume: refused below.
  }
  throw UnsupportedError('Cannot trash $at: its volume has no trash on it');
}

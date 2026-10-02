part of '../../core.dart';

/// The atomic write `fs` (`Path.writeBytes`), `formats` (`JsonDocument.save`) and `collection`
/// (`Table.save`) share: public only because those are separate libraries, and not covered by
/// the versioning promise.
abstract final class FileBridge {
  static final _random = Random.secure();

  /// Writes [bytes] to [path] through a temporary file renamed over it, creating parent
  /// directories. [chmod] gives the temporary file the old one's mode; without it an existing
  /// file is replaced only when a new file already gets that mode, and written in place otherwise.
  static Future<File> write(String path, List<int> bytes, {void Function(String path, int mode)? chmod}) async {
    final file = File(path);
    final (:target, :mode) = _plan(path);
    if (target == null) return file.writeAsBytes(bytes);
    if (mode == null) await File(target).parent.create(recursive: true);
    final opened = _openTemp(target, mode, chmod);
    if (opened == null) return file.writeAsBytes(bytes);
    final (tmp, out) = opened;
    try {
      try {
        await out.writeFrom(bytes);
      } finally {
        await out.close();
      }
      await tmp.rename(target);
    } catch (_) {
      _deleteQuietly(tmp);
      rethrow;
    }
    return file;
  }

  /// [write], synchronously.
  static File writeSync(String path, List<int> bytes, {void Function(String path, int mode)? chmod}) {
    final file = File(path);
    final (:target, :mode) = _plan(path);
    if (target == null) {
      file.writeAsBytesSync(bytes);
      return file;
    }
    if (mode == null) File(target).parent.createSync(recursive: true);
    final opened = _openTemp(target, mode, chmod);
    if (opened == null) {
      file.writeAsBytesSync(bytes);
      return file;
    }
    final (tmp, out) = opened;
    try {
      try {
        out.writeFromSync(bytes);
      } finally {
        out.closeSync();
      }
      tmp.renameSync(target);
    } catch (_) {
      _deleteQuietly(tmp);
      rethrow;
    }
    return file;
  }

  /// Where the temporary file is renamed to (this path, or the file a link here leads to) and
  /// the existing file's mode. No target means write in place: for a device, a FIFO,
  /// `/dev/stdout` or a dangling link, which a rename would replace or could not reach.
  static ({String? target, int? mode}) _plan(String path) {
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
    // Not one of the kernel's own: `/dev/stdout` redirected to a file is a link to one, and
    // renaming over it would leave the shell's copy behind.
    if (stat.mode & 0xf000 != 0x8000 || _kernelOwned(File(path).absolute.path) || _kernelOwned(target)) {
      return inPlace;
    }
    // A rename would replace a read-only file, so ask for write permission first.
    File(target).openSync(mode: FileMode.append).closeSync();
    return (target: target, mode: stat.mode & 0xfff);
  }

  static bool _kernelOwned(String path) => path.startsWith('/dev/') || path.startsWith('/proc/');

  static void _deleteQuietly(File file) {
    try {
      file.deleteSync();
    } on FileSystemException {
      // Never written, or already gone.
    }
  }

  /// A new, empty file beside [target] for its next contents, open for writing and with [mode]
  /// before a byte is in it; `null` when the folder refuses a new file, or [mode] can't be given
  /// without [chmod] (write in place, then). The name is random and the file made exclusively,
  /// so no other writer shares it.
  static (File, RandomAccessFile)? _openTemp(String target, int? mode, void Function(String, int)? chmod) {
    final cut = max(target.lastIndexOf('/'), target.lastIndexOf(Platform.pathSeparator));
    final dir = target.substring(0, cut + 1), name = target.substring(cut + 1);
    for (var tries = 0; ; tries++) {
      final hex = [for (var i = 0; i < 8; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
      final tmp = File('$dir.$name.$hex.tmp');
      try {
        tmp.createSync(exclusive: true);
      } on FileSystemException catch (e) {
        final code = e.osError?.errorCode;
        // Refused, or the name plus the temporary suffix is too long: write in place.
        final refused = Platform.isWindows
            ? const {5, 19, 206}
            : (Platform.isMacOS ? const {1, 13, 30, 63} : const {1, 13, 30, 36});
        if (refused.contains(code)) return null;
        if (code == (Platform.isWindows ? 80 : 17) && tries < 3) continue;
        rethrow;
      }
      if (mode != null && chmod == null && tmp.statSync().mode & 0xfff != mode) {
        _deleteQuietly(tmp);
        return null;
      }
      try {
        final out = tmp.openSync(mode: FileMode.writeOnly);
        try {
          if (mode != null && chmod != null) chmod(tmp.path, mode);
        } catch (_) {
          out.closeSync();
          rethrow;
        }
        return (tmp, out);
      } catch (_) {
        _deleteQuietly(tmp);
        rethrow;
      }
    }
  }
}

part of '../../path.dart';

final _tkChmod = NativeBridge.main
    .require()
    .lookupFunction<Int32 Function(Pointer<Uint8>, IntPtr, Uint32), int Function(Pointer<Uint8>, int, int)>('tk_chmod');

final _tkFileId = NativeBridge.main
    .require()
    .lookupFunction<
      Int32 Function(Pointer<Uint8>, IntPtr, Pointer<Uint64>),
      int Function(Pointer<Uint8>, int, Pointer<Uint64>)
    >('tk_file_id');

/// Which file [path] is — device and inode, or volume and file index — or `null` when it cannot
/// be told (no file there, or no native library): a file renamed keeps it, one put in its place
/// has another.
(int, int)? _fileId(String path) {
  if (!NativeBridge.main.isLoaded) return null;
  final out = NativeBridge.main.alloc(16).cast<Uint64>();
  try {
    return NativeBridge.main.withText(path, (ptr, len) => _tkFileId(ptr, len, out)) < 0 ? null : (out[0], out[1]);
  } finally {
    NativeBridge.main.free(out.cast(), 16);
  }
}

/// Sets [path]'s permission bits to [mode]: one system call, made here.
void _chmod(String path, int mode) {
  if (NativeBridge.main.withText(path, (ptr, len) => _tkChmod(ptr, len, mode)) < 0) {
    final error = NativeBridge.fileError(NativeBridge.main.lastError(), path, 'Cannot chmod $path');
    throw error is FormatException ? FileSystemException('Cannot chmod: ${error.message}', path) : error;
  }
}

/// What gives an atomic write's temporary file the old file's mode: [_chmod], when the native
/// library is there.
void Function(String path, int mode)? get _chmodder => NativeBridge.main.isLoaded ? _chmod : null;

/// Copied folders get their modes back deepest first, once filled: a read-only one set first
/// would refuse its contents. Skipped on Windows and without the native library.
void _restoreModes(List<(String, int)> modes) {
  if (Platform.isWindows || !NativeBridge.main.isLoaded) return;
  for (final (dir, mode) in modes.reversed) {
    _chmod(dir, mode & 0xfff);
  }
}

final _octalMode = RegExp(r'^[0-7]{1,4}$');
final _symbolicClause = RegExp(r'^([ugoa]*)((?:[-+=][rwxXst]*)+)$');
final _symbolicOp = RegExp(r'([-+=])([rwxXst]*)');

/// [mode], octal or symbolic (relative to [path]'s current bits), as the bits to set.
Future<int> _modeOf(Mode mode, String path) async {
  if (mode.bits case final bits?) {
    if (await FileSystemEntity.type(path) == FileSystemEntityType.notFound) throw _notFound(path, 'Cannot chmod');
    return bits;
  }
  final clauses = [for (final clause in mode.split(',')) _symbolicClause.firstMatch(clause)!];
  final stat = await FileStat.stat(path);
  if (stat.type == FileSystemEntityType.notFound) throw _notFound(path, 'Cannot chmod');
  var bits = stat.mode & 0xfff;
  final isDir = stat.type == FileSystemEntityType.directory;
  for (final m in clauses) {
    final who = m[1]!.isEmpty || m[1]!.contains('a') ? 'ugo' : m[1]!;
    // The bits [who] covers: rwx and the special bit of each class; with no who at all, as
    // chmod(1) has it, not those the umask clears.
    var mask = 0;
    if (who.contains('u')) mask |= 0x9c0; // 04700
    if (who.contains('g')) mask |= 0x438; // 02070
    if (who.contains('o')) mask |= 0x207; // 01007
    if (m[1]!.isEmpty) mask &= ~await _umask;
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

/// The process umask, read once and only when a mode needs it, without umask(2), whose
/// set-and-restore races other isolates: from `/proc` on Linux, else from `sh`. Windows has none.
final Future<int> _umask = () async {
  if (Platform.isWindows) return 0;
  try {
    final status = await File('/proc/self/status').readAsString();
    final m = RegExp(r'^Umask:\s*([0-7]+)', multiLine: true).firstMatch(status);
    if (m != null) return int.parse(m[1]!, radix: 8);
  } on FileSystemException {
    // Not Linux, or no procfs.
  }
  final r = await Process.run('/bin/sh', ['-c', 'umask']);
  return int.tryParse('${r.stdout}'.trim(), radix: 8) ?? 0x12; // 022
}();

/// The bytes of the files under [path]; an unreadable folder is skipped.
int _dirSize(String path) {
  var total = 0;
  for (final e in _walkSync(Directory(path))) {
    if (e is File) total += e.lengthSync();
  }
  return total;
}

/// Everything under [dir], skipping what cannot be read: one `listSync(recursive: true)`, 1.8×
/// faster, redone per folder only if that throws. For a worker isolate.
List<FileSystemEntity> _walkSync(Directory dir, [List<FileSystemEntity>? out]) {
  if (out == null) {
    try {
      return dir.listSync(recursive: true, followLinks: false);
    } on FileSystemException {
      // Walked below instead.
    }
  }
  out ??= [];
  try {
    for (final entity in dir.listSync(followLinks: false)) {
      out.add(entity);
      if (entity is Directory) _walkSync(entity, out);
    }
  } on FileSystemException {
    // Unreadable: skipped, as listings skip it.
  }
  return out;
}

/// The C and Windows calls behind [PathExtensions.free], [PathExtensions.trash] and a folder's
/// [PathExtensions.touch], each looked up once.
abstract final class _Sys {
  static final _libc = DynamicLibrary.process();
  static final _malloc = _libc.lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>('malloc');
  static final _free = _libc.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');

  /// `statfs` on macOS, whose `statvfs` counts blocks in 32 bits (wrong past 16 TiB);
  /// `statvfs` elsewhere. Intel macOS names the 64-bit `statfs` `statfs$INODE64`.
  static final _statfs = _libc
      .lookupFunction<Int32 Function(Pointer<Uint8>, Pointer<Void>), int Function(Pointer<Uint8>, Pointer<Void>)>(
        !Platform.isMacOS
            ? 'statvfs'
            : _libc.providesSymbol(r'statfs$INODE64')
            ? r'statfs$INODE64'
            : 'statfs',
      );

  /// [text] as a NUL-terminated C string from `malloc`, freed by the caller.
  static Pointer<Uint8> _cString(String text) {
    final units = utf8.encode(text);
    final ptr = _malloc(units.length + 1).cast<Uint8>();
    ptr.asTypedList(units.length + 1)
      ..setAll(0, units)
      ..[units.length] = 0;
    return ptr;
  }

  static int freePosix(String path) {
    const size = 4096; // more than either struct
    final buf = _malloc(size).cast<Uint8>();
    final text = _cString(path);
    try {
      if (_statfs(text, buf.cast()) < 0) throw FileSystemException('Cannot read free space', path);
      final data = ByteData.sublistView(buf.asTypedList(size));
      // macOS `struct statfs`: u32 f_bsize at 0, u64 f_bavail at 24. Linux `struct statvfs`:
      // f_bsize at 0, f_frsize at 8, f_bavail at 32, all 64-bit.
      if (Platform.isMacOS) return data.getUint32(0, Endian.host) * data.getUint64(24, Endian.host);
      final frsize = data.getUint64(8, Endian.host);
      return (frsize > 0 ? frsize : data.getUint64(0, Endian.host)) * data.getUint64(32, Endian.host);
    } finally {
      _free(buf.cast());
      _free(text.cast());
    }
  }

  static final _utimes = _libc
      .lookupFunction<Int32 Function(Pointer<Uint8>, Pointer<Int64>), int Function(Pointer<Uint8>, Pointer<Int64>)>(
        'utimes',
      );

  /// The folder [path]'s access and modification times set to [at], by `utimes`; dart:io sets
  /// a file's only. Windows is in PLAN.md.
  static void touchDir(String path, DateTime at) {
    if (Platform.isWindows) throw UnsupportedError('Cannot touch a folder on Windows: $path');
    final micros = at.microsecondsSinceEpoch;
    // Two `struct timeval`s, each a 64-bit seconds and a 64-bit (padded) microseconds.
    final times = _malloc(32).cast<Int64>();
    final text = _cString(path);
    try {
      for (final i in [0, 2]) {
        times[i] = micros ~/ 1000000;
        times[i + 1] = micros % 1000000;
      }
      if (_utimes(text, times) < 0) throw FileSystemException('Cannot touch', path);
    } finally {
      _free(times.cast());
      _free(text.cast());
    }
  }

  static final _getuid = _libc.lookupFunction<Uint32 Function(), int Function()>('getuid');

  /// This process's user id, which names a volume's trash folder.
  static int uid() => _getuid();

  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _localAlloc = _kernel32
      .lookupFunction<Pointer<Void> Function(Uint32, IntPtr), Pointer<Void> Function(int, int)>('LocalAlloc');
  static final _localFree = _kernel32
      .lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');
  static final _diskFree = _kernel32
      .lookupFunction<
        Int32 Function(Pointer<Uint16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
        int Function(Pointer<Uint16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)
      >('GetDiskFreeSpaceExW');
  static final _shell32 = DynamicLibrary.open('shell32.dll');
  static final _fileOperation = _shell32.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
    'SHFileOperationW',
  );
  static final _queryRecycleBin = _shell32
      .lookupFunction<Int32 Function(Pointer<Uint16>, Pointer<Void>), int Function(Pointer<Uint16>, Pointer<Void>)>(
        'SHQueryRecycleBinW',
      );

  /// [text] as UTF-16 with [nuls] terminating zeros, zero-filled memory from `LocalAlloc`.
  static Pointer<Uint16> _wide(String text, int nuls) {
    final units = text.codeUnits;
    final ptr = _localAlloc(0x0040, (units.length + nuls) * 2).cast<Uint16>();
    ptr.asTypedList(units.length).setAll(0, units);
    return ptr;
  }

  static final _getDriveType = _kernel32
      .lookupFunction<Uint32 Function(Pointer<Uint16>), int Function(Pointer<Uint16>)>('GetDriveTypeW');

  /// The free bytes of the volume holding the folder [dir]: the folder itself is asked, so a
  /// mount point answers for the volume mounted there.
  static int freeWindows(String dir) {
    final path = _wide(dir.endsWith(r'\') || dir.endsWith('/') ? dir : '$dir\\', 1);
    final counts = _localAlloc(0x0040, 24).cast<Uint64>();
    try {
      if (_diskFree(path, counts, counts + 1, counts + 2) == 0) {
        throw FileSystemException('Cannot read free space', dir);
      }
      return counts.value;
    } finally {
      _localFree(path.cast());
      _localFree(counts.cast());
    }
  }

  /// [path] to the Recycle Bin by `SHFileOperationW`, `pFrom` a double-NUL-terminated list.
  /// Refused where the shell would delete it for good: a drive that is not fixed (removable,
  /// network, RAM), or one without a Recycle Bin; and should the shell still find it cannot
  /// recycle it (too big for the bin), it asks rather than deletes (`FOF_WANTNUKEWARNING`).
  static void recycle(String path) {
    if (path.startsWith(r'\\') || path.startsWith('//')) {
      throw UnsupportedError('Cannot trash $path: a network path has no Recycle Bin');
    }
    final root = p.rootPrefix(p.absolute(path));
    final rootPtr = _wide(root.endsWith(r'\') ? root : '$root\\', 1);
    // SHQUERYRBINFO: a DWORD size, then two 64-bit counts.
    final info = _localAlloc(0x0040, 24);
    try {
      // DRIVE_FIXED is 3.
      if (_getDriveType(rootPtr) != 3) throw UnsupportedError('Cannot trash $path: its drive has no Recycle Bin');
      info.cast<Uint32>().value = 24;
      if (_queryRecycleBin(rootPtr, info) != 0) {
        throw UnsupportedError('Cannot trash $path: its drive has no Recycle Bin');
      }
    } finally {
      _localFree(rootPtr.cast());
      _localFree(info);
    }
    final from = _wide(path, 2);
    final op = _localAlloc(0x0040, 64);
    try {
      final data = ByteData.sublistView(op.cast<Uint8>().asTypedList(64));
      final is64 = sizeOf<IntPtr>() == 8;
      data.setUint32(is64 ? 8 : 4, 3, Endian.host); // wFunc = FO_DELETE
      if (is64) {
        data.setUint64(16, from.address, Endian.host);
      } else {
        data.setUint32(8, from.address, Endian.host);
      }
      // FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT | FOF_WANTNUKEWARNING
      data.setUint16(is64 ? 32 : 16, 0x0040 | 0x0010 | 0x0400 | 0x0004 | 0x4000, Endian.host);
      final res = _fileOperation(op);
      if (res != 0) throw FileSystemException('Cannot move to the Recycle Bin (error $res)', path);
    } finally {
      _localFree(op);
      _localFree(from.cast());
    }
  }
}

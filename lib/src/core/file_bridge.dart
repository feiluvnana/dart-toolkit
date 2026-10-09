part of '../core.dart';

/// The atomic write `fs` (`Path.writeBytes`), `formats` (`JsonDocument.save`) and `collection`
/// (`Table.save`) share, and the extension `formats` and `collection` pick a format by: public only because those are separate libraries, and not covered by
/// the versioning promise.
abstract final class FileBridge {
  /// The first free `name (n).ext` beside [taken], as Finder and `cp -n` write it: for
  /// `ConflictPolicy.rename` wherever a file lands.
  ///
  /// [claimed] holds names already promised to someone else (a rename plan's other targets): they
  /// are taken too, and the answer is added to it, so two callers never get one name.
  static String free(String taken, {Set<String>? claimed}) {
    final slash = max(taken.lastIndexOf('/'), Platform.isWindows ? taken.lastIndexOf(r'\') : -1);
    final (dir, name) = (taken.substring(0, slash + 1), taken.substring(slash + 1));
    final dot = name.lastIndexOf('.');
    final (base, ext) = dot > 0 ? (name.substring(0, dot), name.substring(dot)) : (name, '');
    for (var n = 1; ; n++) {
      final candidate = '$dir$base ($n)$ext';
      if (claimed != null && claimed.contains(candidate)) continue;
      if (FileSystemEntity.typeSync(candidate, followLinks: false) == FileSystemEntityType.notFound) {
        claimed?.add(candidate);
        return candidate;
      }
    }
  }

  /// Where a write to [target] goes under [conflict], or `null` to leave what is there
  /// ([Conflict.skip], and [Conflict.newer] when [source] is not newer). [verb] and [subject]
  /// word the [PathExistsException] of [Conflict.fail]: `Cannot verb subject: target exists`. A name [Conflict.rename] picks is claimed until [release]d, so two writers never
  /// pick one name. Folders are never in conflict: callers merge them.
  static String? settle(
    String target,
    Conflict conflict, {
    required String verb,
    required String subject,
    DateTime? source,
  }) {
    if (_claims.contains(target) && conflict == Conflict.rename) return free(target, claimed: _claims);
    final there = FileSystemEntity.typeSync(target, followLinks: false);
    if (there == FileSystemEntityType.notFound) return target;
    return switch (conflict) {
      Conflict.skip => null,
      Conflict.overwrite => target,
      Conflict.rename => free(target, claimed: _claims),
      Conflict.fail => throw PathExistsException(target, const OSError(), 'Cannot $verb $subject: $target exists'),
      Conflict.newer when source == null => throw ArgumentError.value(
        conflict,
        'conflict',
        'Invalid conflict: nothing to compare with',
      ),
      Conflict.newer => source!.isAfter(FileStat.statSync(target).modified) ? target : null,
    };
  }

  /// Gives up the claim [settle] made on [path], once the file is there or will not be.
  static void release(String path) => _claims.remove(path);

  static final _claims = <String>{};

  /// What every `Saveable.save` does: [bytes] written atomically to [to] (whose folder must be
  /// there), settled by [conflict]
  /// (a value in memory has no time, so [Conflict.newer] is an [ArgumentError]), as a task about
  /// the file; a skip is `Done(fresh: false)`.
  static Task<Path> save(String to, Conflict conflict, String subject, FutureOr<List<int>> Function() bytes) {
    if (conflict == Conflict.newer) {
      throw ArgumentError.value(conflict, 'conflict', 'Invalid conflict: a value in memory has no time to compare');
    }
    return TaskInternals.start(Path(to), label(to), (work) async {
      // A save writes a file and never makes folders: a mistyped folder is news, not a new tree.
      final folder = File(to).parent;
      if (!await folder.exists()) {
        throw PathNotFoundException(folder.path, const OSError('No such directory', 2), 'Cannot save $subject to $to');
      }
      final target = settle(to, conflict, verb: 'save', subject: subject);
      if (target == null) {
        TaskInternals.stale(work);
        return Path(to);
      }
      try {
        await write(target, await bytes());
      } finally {
        if (conflict == Conflict.rename) release(target);
      }
      return Path(target);
    });
  }

  /// How a status names the file at [path]: its folder and its name.
  static String label(String path) {
    final parts = path.split(Platform.isWindows ? _bothSlashes : '/')..removeWhere((p) => p.isEmpty);
    return parts.length < 2 ? path : '${parts[parts.length - 2]}/${parts.last}';
  }

  static final _bothSlashes = RegExp(r'[/\\]');

  static final _random = Random.secure();

  /// 16 random hex digits: a name no other run picks.
  static String token() => [for (var i = 0; i < 8; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

  /// [text], read from [path], parsed by [parse]; what it cannot read is a [FormatException]
  /// naming the file — `Invalid TOML in bad.toml: …` — with the text and offset, so it prints
  /// the line and a caret.
  static T parsed<T>(String format, String path, String text, T Function(String text) parse) {
    try {
      return parse(text);
    } on FormatException catch (e) {
      var message = e.message;
      var offset = e.offset;
      // A parser that says where by line: `TOML line 2: …`.
      if (RegExp('^$format line (\\d+): ').firstMatch(message) case final m?) {
        message = message.substring(m.end);
        offset ??= _lineStart(text, int.parse(m[1]!));
      } else if (message.startsWith('$format: ')) {
        message = message.substring(format.length + 2);
      }
      Error.throwWithStackTrace(
        FormatException('Invalid $format in $path: $message', e.source is String ? e.source : text, offset),
        StackTrace.current,
      );
    }
  }

  /// Where line [line] (1-based) of [text] starts.
  static int _lineStart(String text, int line) {
    var at = 0;
    for (var n = 1; n < line; n++) {
      final next = text.indexOf('\n', at);
      if (next < 0) return at;
      at = next + 1;
    }
    return at;
  }

  static final _pubSnapshot = RegExp(r'^(.+\.dart)-[\w.]+\.snapshot$');
  static final _fileFrame = RegExp(r'\((file:[^)]+?)(?::\d+){1,2}\)');

  /// The running script's file, as `Path.here` names it; `''` when it has no file. Here, so
  /// `Env.load` finds a `.env` beside it without importing `path`.
  static String script() {
    final uri = Platform.script;
    if (uri.scheme != 'file') return '';
    final script = uri.toFilePath();
    final sep = Platform.pathSeparator;
    String dirname(String path) => path.substring(0, max(0, max(path.lastIndexOf('/'), path.lastIndexOf(sep))));
    String basename(String path) => path.substring(max(path.lastIndexOf('/'), path.lastIndexOf(sep)) + 1);
    // `dart run` and `dart pub global run` run `.dart_tool/pub/bin/<pkg>/<name>.dart-<ver>.snapshot`.
    final snapshot = _pubSnapshot.firstMatch(basename(script));
    if (snapshot != null) {
      final lib = Isolate.resolvePackageUriSync(Uri.parse('package:${basename(dirname(script))}/'));
      // `lib`'s URI ends in `/`: its package's folder is two cuts up.
      if (lib != null) return [dirname(dirname(lib.toFilePath())), 'bin', snapshot[1]!].join(sep);
    }
    // `dart test` runs a temporary kernel file: the test file is the first `file:` frame.
    if (basename(dirname(script)).startsWith('dart_test.kernel.')) {
      final frame = _fileFrame.firstMatch(StackTrace.current.toString());
      if (frame != null) return Uri.parse(frame[1]!).toFilePath();
    }
    return script;
  }

  /// [path]'s extension, lowercase and without the dot; `''` when its last part has none.
  static String extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot == -1 || path.indexOf('/', dot) != -1 || path.indexOf(r'\', dot) != -1
        ? ''
        : path.substring(dot + 1).toLowerCase();
  }

  /// Writes [bytes] to [path] through a temporary file renamed over it, creating parent
  /// directories. [chmod] gives the temporary file the old one's mode; without it an existing
  /// file is replaced only when a new file already gets that mode, and written in place otherwise.
  ///
  /// Up to 64 KiB is written on this isolate, as [writeSync] writes it: the hops to the I/O
  /// thread cost more than the write.
  static Future<void> write(String path, List<int> bytes, {void Function(String path, int mode)? chmod}) async {
    if (bytes.length <= 64 << 10) return writeSync(path, bytes, chmod: chmod);
    final file = File(path);
    final (:target, :mode) = _plan(path);
    final opened = target == null ? null : _openTemp(target, mode, chmod);
    if (opened == null) {
      await file.writeAsBytes(bytes);
      return;
    }
    final (tmp, out) = opened;
    try {
      try {
        await out.writeFrom(bytes);
      } finally {
        await out.close();
      }
      await rename(tmp, target!);
    } catch (_) {
      _deleteQuietly(tmp);
      rethrow;
    }
  }

  /// [write] from [source], chunk by chunk: the target changes only once [source] is done, and
  /// an error in it leaves the old file as it was.
  static Future<void> writeStream(
    String path,
    Stream<List<int>> source, {
    void Function(String path, int mode)? chmod,
  }) async {
    final file = File(path);
    final (:target, :mode) = _plan(path);
    final opened = target == null ? null : _openTemp(target, mode, chmod);
    if (opened == null) {
      final sink = file.openWrite();
      try {
        await sink.addStream(source);
      } finally {
        await sink.close();
      }
      return;
    }
    final (tmp, out) = opened;
    try {
      try {
        await for (final chunk in source) {
          await out.writeFrom(chunk);
        }
      } finally {
        await out.close();
      }
      await rename(tmp, target!);
    } catch (_) {
      _deleteQuietly(tmp);
      rethrow;
    }
  }

  /// [write], synchronously.
  static void writeSync(String path, List<int> bytes, {void Function(String path, int mode)? chmod}) {
    final (:target, :mode) = _plan(path);
    final opened = target == null ? null : _openTemp(target, mode, chmod);
    if (opened == null) {
      File(path).writeAsBytesSync(bytes);
      return;
    }
    final (tmp, out) = opened;
    try {
      try {
        out.writeFromSync(bytes);
      } finally {
        out.closeSync();
      }
      renameSync(tmp, target!);
    } catch (_) {
      _deleteQuietly(tmp);
      rethrow;
    }
  }

  /// [path] replaced by what [fill] writes to the file it is handed: a temporary file beside
  /// [path] with its mode (as [write] makes it), renamed over it when [fill] answers `true` and
  /// deleted otherwise, so a failed fill leaves the old file. Where [write] writes in place,
  /// [fill] is handed [path] itself.
  static void replaceSync(String path, bool Function(String into) fill, {void Function(String path, int mode)? chmod}) {
    final (:target, :mode) = _plan(path);
    final opened = target == null ? null : _openTemp(target, mode, chmod);
    if (opened == null) {
      fill(path);
      return;
    }
    final (tmp, out) = opened;
    out.closeSync();
    try {
      if (fill(tmp.path)) {
        renameSync(tmp, target!);
      } else {
        _deleteQuietly(tmp);
      }
    } catch (_) {
      _deleteQuietly(tmp);
      rethrow;
    }
  }

  /// Where the temporary file is renamed to (this path, or the file a link here leads to) and
  /// the existing file's mode. No target means write in place: for a device, a FIFO,
  /// `/dev/stdout` or a dangling link, which a rename would replace or could not reach.
  static ({String? target, int? mode}) _plan(String path) {
    const inPlace = (target: null, mode: null);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      // `/dev/null` is no type at all, and only `exists` sees it.
      return File(path).existsSync() ? inPlace : (target: path, mode: null);
    }
    final isLink = type == FileSystemEntityType.link;
    if (!isLink && type != FileSystemEntityType.file) return inPlace;
    if (Platform.isWindows) return isLink ? inPlace : (target: path, mode: null);
    // A link's stat is its target's: a dangling one is not a file.
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) return inPlace;
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
  /// before a byte is in it, its folders made when missing; `null` when the folder refuses a new
  /// file, or [mode] can't be given without [chmod] (write in place, then). The name has 64
  /// random bits from a secure source, so no other writer opens it.
  static (File, RandomAccessFile)? _openTemp(String target, int? mode, void Function(String, int)? chmod) {
    final cut = max(target.lastIndexOf('/'), target.lastIndexOf(Platform.pathSeparator));
    final dir = target.substring(0, cut + 1), name = target.substring(cut + 1);
    final hex = token();
    final tmp = File('$dir.$name.$hex.tmp');
    RandomAccessFile out;
    try {
      out = _open(tmp);
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      // Refused, or the name plus the temporary suffix is too long: write in place.
      final refused = Platform.isWindows
          ? const {5, 19, 123, 206}
          : (Platform.isMacOS ? const {1, 13, 30, 63} : const {1, 13, 30, 36});
      if (refused.contains(code)) return null;
      rethrow;
    }
    try {
      if (mode != null && chmod == null && tmp.statSync().mode & 0xfff != mode) {
        out.closeSync();
        _deleteQuietly(tmp);
        return null;
      }
      if (mode != null && chmod != null) chmod(tmp.path, mode);
      return (tmp, out);
    } catch (_) {
      out.closeSync();
      _deleteQuietly(tmp);
      rethrow;
    }
  }

  /// [file] opened for writing; its folders are made only when the open finds them missing.
  static RandomAccessFile _open(File file) {
    try {
      return file.openSync(mode: FileMode.writeOnly);
    } on PathNotFoundException {
      file.parent.createSync(recursive: true);
      return file.openSync(mode: FileMode.writeOnly);
    }
  }

  /// [from] renamed over [to], retrying on Windows when the target is held (error 5 or 32).
  static Future<T> rename<T extends FileSystemEntity>(T from, String to) async {
    if (!Platform.isWindows) return await from.rename(to) as T;
    var wait = 1;
    for (var i = 0; i < 10; i++) {
      try {
        return await from.rename(to) as T;
      } on FileSystemException catch (e) {
        final code = e.osError?.errorCode;
        if ((code != 5 && code != 32) || i == 9) rethrow;
        await Future<void>.delayed(Duration(milliseconds: wait));
        wait = (wait * 2).clamp(1, 1000);
      }
    }
    return await from.rename(to) as T;
  }

  /// [rename], synchronously.
  static T renameSync<T extends FileSystemEntity>(T from, String to) {
    if (!Platform.isWindows) return from.renameSync(to) as T;
    var wait = 1;
    for (var i = 0; i < 10; i++) {
      try {
        return from.renameSync(to) as T;
      } on FileSystemException catch (e) {
        final code = e.osError?.errorCode;
        if ((code != 5 && code != 32) || i == 9) rethrow;
        sleep(Duration(milliseconds: wait));
        wait = (wait * 2).clamp(1, 1000);
      }
    }
    return from.renameSync(to) as T;
  }
}

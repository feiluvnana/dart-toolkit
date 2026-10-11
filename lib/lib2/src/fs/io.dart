import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/native.dart' as l2native;
import '../core/traits.dart';

export '../core/errors.dart';

/// The native `tk_chmod`/`tk_copy_file`/`tk_file_id`/`tk_rename` calls behind
/// [File] (cutover: the engine owns them). Looked up once per isolate from
/// [l2native.Lib2Native.require], so a missing library throws
/// [UnsupportedError] before reaching them.
abstract final class _FsNative {
  static ffi.DynamicLibrary get _lib => l2native.Lib2Native.require();

  static final chmod = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr, ffi.Uint32),
        int Function(ffi.Pointer<ffi.Uint8>, int, int)
      >('tk_chmod');

  static final fileId = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr, ffi.Pointer<ffi.Uint64>),
        int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint64>)
      >('tk_file_id');

  static final copyFile = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint8>,
          ffi.IntPtr,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
        ),
        int Function(
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint8>,
        )
      >('tk_copy_file');

  static final rename = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr, ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int)
      >('tk_rename');
}

/// What the library said about [path], as the exception it means: a missing
/// path (os error 2/3) is a [io.PathNotFoundException], anything else a
/// [io.FileSystemException].
Exception _fsFileError(String message, String path, String op) {
  final m = RegExp(r'\(os error (\d+)\)').firstMatch(message);
  if (m == null) return io.FileSystemException('$op: $message', path);
  final code = int.parse(m[1]!);
  final said = message.substring(0, m.start).trim();
  final at = said.lastIndexOf(': ');
  final error = io.OSError(at < 0 ? said : said.substring(at + 2), code);
  if (code == 2 || code == 3) return io.PathNotFoundException(path, error, op);
  return io.FileSystemException(op, path, error);
}

/// Renames [src] over [dst] through `tk_rename` (atomic replace; on Windows a
/// held target waits with backoff and retries). Without the library it is an
/// [UnsupportedError] (r50: no Dart fallback).
Future<void> renameFile(String src, String dst) async {
  final rc = l2native.Lib2Native.withText(src, (sp, sn) {
    return l2native.Lib2Native.withText(dst, (dp, dn) {
      return _FsNative.rename(sp, sn, dp, dn);
    });
  });
  if (rc < 0) throw _fsFileError(l2native.Lib2Native.lastError(), src, 'Cannot rename');
}

/// A filesystem path: `operator /` to join, [name] for the last segment, [isLink] and
/// [target] for symlinks, and sandbox-safe [resolve]/[starts]/[equals].
final class Path {
  final String _str;

  Path(Object path) : _str = path is Path ? path._str : path.toString();

  /// The path as written.
  String get str => _str;

  /// The last segment.
  String get name {
    final clean = _str.replaceAll('\\', '/');
    final i = clean.lastIndexOf('/');
    return i == -1 ? clean : clean.substring(i + 1);
  }

  /// The directory holding this path.
  Path get parent => Path(io.File(_str).parent.path);

  /// The absolute form.
  Path get absolute => Path(io.File(_str).absolute.path);

  /// Whether a symlink sits at this path.
  bool get isLink => io.Link(_str).existsSync();

  /// The symlink's target; throws when this is not a link.
  Future<String> get target => io.Link(_str).target();

  /// Whether anything exists at this path.
  Future<bool> get exists => io.FileSystemEntity.isDirectory(_str).then((d) => d || io.File(_str).existsSync());

  /// Joins a segment: `root / 'a' / 'b.txt'`.
  Path operator /(Object other) {
    var base = _str;
    final sep = io.Platform.pathSeparator;
    if (base.isNotEmpty && !base.endsWith('/') && !base.endsWith(sep)) base = '$base$sep';
    return Path('$base$other');
  }

  /// The canonical path after following every symlink.
  Future<Path> resolve() async {
    final type = await io.FileSystemEntity.type(_str, followLinks: false);
    return switch (type) {
      io.FileSystemEntityType.notFound => absolute,
      _ => Path(await io.File(_str).resolveSymbolicLinks()),
    };
  }

  /// Whether this path is [root] itself or sits below it, compared on the
  /// canonical form: `.`/`..` collapsed, separators unified, case folded where
  /// the platform's filesystem is case-insensitive (Windows, macOS).
  bool starts(Path root) => _startsIn(_canonical(_str), _canonical(root._str));

  /// Whether this path names the same file as [other], compared on the
  /// canonical form (see [starts]).
  bool equals(Object other) =>
      other is Path ? _canonical(_str) == _canonical(other._str) : _canonical(_str) == _canonical(other.toString());

  @override
  String toString() => _str;

  @override
  bool operator ==(Object other) => other is Path && other._str == _str;

  @override
  int get hashCode => _str.hashCode;
}

/// Whether canonical [here] is [there] itself or below it.
bool _startsIn(String here, String there) {
  if (here == there) return true;
  if (there == '/' || there == '//') return here.startsWith('/');
  return here.startsWith('$there/');
}

/// The lexical canonical form of [path]: `\` unified to `/`, `.` dropped, `..`
/// collapsed, trailing slashes stripped, lowercased where the platform's
/// filesystem ignores case. UNC roots (`//server/share`) keep their prefix.
String _canonical(String path) {
  var p = path.replaceAll('\\', '/');
  final unc = p.startsWith('//');
  final abs = p.startsWith('/');
  final segs = <String>[];
  for (final s in p.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (segs.isNotEmpty && segs.last != '..') {
        segs.removeLast();
        continue;
      }
      if (abs) continue; // above the root is the root
    }
    segs.add(s);
  }
  var out =
      '${unc
          ? '//'
          : abs
          ? '/'
          : ''}${segs.join('/')}';
  if (out.isEmpty) out = abs ? '/' : '.';
  if (io.Platform.isWindows || io.Platform.isMacOS) out = out.toLowerCase();
  return out;
}

final _driveRoot = RegExp(r'^[A-Za-z]:([/\\]|$)');

/// Joins [member] under [root] and answers the target, throwing a
/// [SecurityException] — before anything is written — when [member] is
/// absolute, holds a NUL byte, or escapes [root] (`..` past the root).
///
/// Both the lexical join and the absolute canonical forms are checked, so the
/// target is [root] itself or sits below it on any platform.
Future<Path> sandbox(Object root, String member) async {
  final base = root is Path ? root._str : root.toString();
  if (member.contains('\x00')) throw SecurityException('Refused member with NUL byte');
  final m = member.replaceAll('\\', '/');
  if (m.isEmpty) throw SecurityException('Refused empty member');
  if (m.startsWith('/') || _driveRoot.hasMatch(m)) {
    throw SecurityException('Refused absolute member: $member');
  }
  final joined = '$base${base.endsWith('/') || base.endsWith('\\') ? '' : io.Platform.pathSeparator}$member';
  final rootAbs = _canonical(io.File(base).absolute.path);
  final targetAbs = _canonical(io.File(joined).absolute.path);
  if (!_startsIn(targetAbs, rootAbs)) throw SecurityException('Refused escape outside $base: $member');
  return Path(joined);
}

/// A file: [text], [bytes], [write], [atomic] and the streaming [read]/[write] of a [Reader]
/// and [Writer], plus [seek] as a [Seeker] for range-resume. `File.open` gives a reader
/// over an open handle.
///
/// The [Writer] contract holds everywhere: a `String` is UTF-8 encoded, a
/// `List<int>`/`Uint8List` is written verbatim, anything else is an
/// [ArgumentError]. A reading on a missing file throws [io.PathNotFoundException].
final class File implements Reader, Writer, Closer, Seeker {
  final String _path;
  io.RandomAccessFile? _raf;

  File(Object path) : _path = path is Path ? path.str : path.toString();

  /// The path as written.
  String get str => _path;

  @override
  String toString() => _path;

  /// The path as a [Path].
  Path get path => Path(_path);

  /// The last segment.
  String get name => Path(_path).name;

  /// Opens this file for reading and answers a reader over it. The reader
  /// honours [seek] for range-resume.
  static Future<File> open(Object path) async {
    final f = File(path);
    f._raf = await io.File(f._path).open(mode: io.FileMode.read);
    return f;
  }

  /// Whether anything sits at this path.
  Future<bool> get exists => io.File(_path).exists();

  /// Size in bytes.
  Future<int> get size => io.File(_path).length();

  /// The whole file decoded as UTF-8.
  Future<String> text() => io.File(_path).readAsString();

  /// The whole file as bytes.
  Future<Uint8List> bytes() => io.File(_path).readAsBytes();

  /// A stream of the file's UTF-8 lines.
  Stream<String> lines() => io.File(_path).openRead().transform(utf8.decoder).transform(const LineSplitter());

  /// Writes [data] (`String` or `List<int>`), replacing the file; answers the bytes written.
  @override
  Future<int> write(Object data) async {
    final bytes = _writeBytes(data);
    await io.File(_path).writeAsBytes(bytes, flush: false);
    return bytes.length;
  }

  /// Appends [data] (`String` or `List<int>`) to the file, creating it if needed.
  Future<int> append(Object data) async {
    final bytes = _writeBytes(data);
    await io.File(_path).writeAsBytes(bytes, mode: io.FileMode.append);
    return bytes.length;
  }

  /// Writes [data] (`String` or `List<int>`) to a temporary sibling, then renames it
  /// atomically over this file (Windows: held-target retries, see [renameFile]).
  Future<void> atomic(Object data) async {
    final bytes = _writeBytes(data);
    final tmp = io.File('$_path.tmp_${DateTime.now().microsecondsSinceEpoch}');
    await tmp.writeAsBytes(bytes);
    await renameFile(tmp.path, _path);
  }

  /// Copies this file to [dst] atomically (via a temporary sibling renamed
  /// over the target) with `tk_copy_file` (source permission bits kept,
  /// partial destination removed). Without the library it is an
  /// [UnsupportedError] (r50: no Dart fallback).
  Future<void> copy(Object dst) async {
    final target = Path(dst).str;
    final tmp = '$target.tmp_${DateTime.now().microsecondsSinceEpoch}';
    try {
      await _nativeCopy(_path, tmp);
      await renameFile(tmp, target);
    } catch (_) {
      await _gone(tmp);
      rethrow;
    }
  }

  /// Moves (renames) this file to [dst] (held-target retries on Windows);
  /// across volumes it copies and then drops the source, so the destination
  /// is complete before the source is touched.
  Future<void> move(Object dst) async {
    final target = Path(dst).str;
    try {
      await renameFile(_path, target);
      return;
    } on io.FileSystemException catch (e) {
      if (!_isCrossVolume(e)) rethrow;
    }
    await copy(target);
    await drop();
  }

  /// The identity of this file (device+inode / volume+index via `tk_file_id`):
  /// a renamed file keeps it, another file put in its place has another.
  /// Without the library it is an [UnsupportedError] (r50: no Dart fallback).
  Future<(int, int)?> id() async {
    final out = l2native.Lib2Native.alloc(16).cast<ffi.Uint64>();
    try {
      return l2native.Lib2Native.withText(_path, (ptr, len) => _FsNative.fileId(ptr, len, out)) < 0
          ? null
          : (out[0], out[1]);
    } finally {
      l2native.Lib2Native.free(out.cast(), 16);
    }
  }

  /// Deletes this file if it exists.
  Future<void> drop() async {
    final f = io.File(_path);
    if (await f.exists()) await f.delete();
  }

  /// Makes [dst] a hard link to this file.
  Future<void> hardlink(Object dst) => io.Link(Path(dst).str).create(_path);

  /// Changes the permission bits (octal [mode]) through `tk_chmod`: one
  /// system call, and on Windows the owner's write bit maps to read-only.
  /// Without the native library it is an [UnsupportedError] (r50: no Dart
  /// fallback, no process spawn).
  Future<void> chmod(int mode) async {
    final rc = l2native.Lib2Native.withText(_path, (ptr, len) => _FsNative.chmod(ptr, len, mode));
    if (rc < 0) throw _fsFileError(l2native.Lib2Native.lastError(), _path, 'Cannot chmod');
  }

  /// A [Writer] over this file, appending when [append] is set.
  FileWriter writer({bool append = false}) => FileWriter(this, append: append);

  /// A uniquely named temporary file.
  static Future<File> temp({String? ext}) async {
    final dir = await io.Directory.systemTemp.createTemp('tk_');
    return File(Path(dir.path) / 'temp${ext ?? '.tmp'}');
  }

  @override
  Future<int> read(Uint8List buf) async {
    final raf = _raf ??= await io.File(_path).open(mode: io.FileMode.read);
    return raf.readInto(buf);
  }

  /// Moves the read position to [offset] (from the start) and answers it, so a
  /// half-read file can resume: `await f.seek(saved); await f.pipe(dst);`.
  @override
  Future<int> seek(int offset) async {
    if (offset < 0) throw ArgumentError.value(offset, 'offset', 'Must be non-negative');
    final raf = _raf ??= await io.File(_path).open(mode: io.FileMode.read);
    await raf.setPosition(offset);
    return offset;
  }

  @override
  Future<void> flush() async => _raf?.flush();

  @override
  Future<void> close() async {
    await _raf?.close();
    _raf = null;
  }
}

/// [data] as bytes under the [Writer] contract.
List<int> _writeBytes(Object data) {
  if (data is String) return utf8.encode(data);
  if (data is List<int>) return data;
  throw ArgumentError.value(data, 'data', 'Must be String, List<int> or Uint8List');
}

/// Copies [src] to a new file [dst] through `tk_copy_file` (clone where the
/// filesystem makes one, else chunked; progress null, stop null): a failed
/// copy removes [dst]. [dst] must not exist.
Future<void> _nativeCopy(String src, String dst) async {
  final s = utf8.encode(src), d = utf8.encode(dst);
  final rc = l2native.Lib2Native.withBytes(s, (sp, sn) {
    return l2native.Lib2Native.withBytes(d, (dp, dn) {
      return _FsNative.copyFile(sp, sn, dp, dn, ffi.nullptr, ffi.nullptr);
    });
  });
  if (rc < 0) throw _fsFileError(l2native.Lib2Native.lastError(), src, 'Cannot copy');
}

/// Deletes the file at [path] when there is one; never throws.
Future<void> _gone(String path) async {
  try {
    await io.File(path).delete();
  } catch (_) {
    // Nothing there, or already gone: there is nothing to clean up.
  }
}

/// Whether [e] reports a cross-volume rename (POSIX EXDEV): copy+drop then.
bool _isCrossVolume(io.FileSystemException e) {
  if (e.osError?.errorCode == 18) return true;
  final m = e.message.toLowerCase();
  return m.contains('cross-device') || m.contains('different volume') || m.contains('exdev');
}

/// A [Writer] over a file, buffered through an `IOSink`.
final class FileWriter implements Writer, Closer {
  final File file;
  final bool append;
  io.IOSink? _sink;

  FileWriter(this.file, {this.append = false});

  io.IOSink get _live => _sink ??= io.File(file._path).openWrite(mode: append ? io.FileMode.append : io.FileMode.write);

  @override
  Future<int> write(Object data) async {
    final bytes = _writeBytes(data);
    _live.add(bytes);
    return bytes.length;
  }

  @override
  Future<void> flush() => _live.flush();

  @override
  Future<void> close() async {
    await _sink?.close();
    _sink = null;
  }
}

/// A directory: [make], [drop], [find] (recursive glob) and [watch].
final class Dir {
  final String _path;

  Dir(Object path) : _path = path is Path ? path.str : path.toString();

  /// The path as written.
  String get str => _path;

  @override
  String toString() => _path;

  /// The path as a [Path].
  Path get path => Path(_path);

  /// The last segment.
  String get name => Path(_path).name;

  /// Creates a unique temporary directory.
  static Future<Dir> temp() async => Dir((await io.Directory.systemTemp.createTemp('tk_dir_')).path);

  /// Whether anything sits at this path.
  Future<bool> get exists => io.Directory(_path).exists();

  /// Creates this directory (and parents).
  Future<void> make() => io.Directory(_path).create(recursive: true);

  /// Deletes this directory and everything in it.
  Future<void> drop() async {
    final d = io.Directory(_path);
    if (await d.exists()) await d.delete(recursive: true);
  }

  /// Every file below this directory matched by the glob [pattern], against the
  /// path relative to this directory with `/` between folders.
  ///
  /// The grammar is the shared mini-glob: `*` within one segment, `**` across
  /// any number of segments (`a/**…/…*.dart`), `?`, `[a-z]`/`[!abc]`, `{a,b}`,
  /// and `\` to escape one character. An empty pattern or one with an unclosed
  /// `[`/`{` is a [FormatException]; an absolute pattern or one with a `..`
  /// segment is an [ArgumentError]. A missing directory is a
  /// [io.PathNotFoundException].
  Future<List<File>> find(String pattern, {bool recursive = true}) async {
    final matcher = _checkedGlob(pattern);
    if (!await io.Directory(_path).exists()) {
      throw io.PathNotFoundException(_path, const io.OSError('No such file or directory', 2), 'Cannot list');
    }
    final out = <File>[];
    final stream = recursive
        ? io.Directory(_path).list(recursive: true, followLinks: false)
        : io.Directory(_path).list(recursive: false, followLinks: false);
    await for (final entity in stream) {
      if (entity is! io.File) continue;
      final rel = _relativeTo(_path, entity.path);
      if (matcher.hasMatch(rel)) out.add(File(entity.path));
    }
    return out;
  }

  /// Every immediate entry.
  Stream<io.FileSystemEntity> list() => io.Directory(_path).list();

  /// A stream of changes below this directory.
  Stream<WatchEvent> watch() => io.Directory(_path).watch().map(WatchEvent._);
}

/// [child] relative to [start], with forward slashes.
String _relativeTo(String start, String child) {
  final base = io.Directory(start).absolute.path;
  var rel = io.File(child).absolute.path;
  if (rel.startsWith(base)) rel = rel.substring(base.length);
  rel = rel.replaceAll('\\', '/').replaceAll(RegExp('^/+'), '');
  return rel;
}

/// A checked, compiled glob: validates [pattern], then matches relative paths.
RegExp _checkedGlob(String pattern) {
  if (pattern.isEmpty) throw FormatException('Invalid glob: it is empty', pattern);
  if (pattern.startsWith('/') ||
      pattern.startsWith('\\') ||
      _driveRoot.hasMatch(pattern) ||
      pattern.split(RegExp(r'[/\\]')).contains('..')) {
    throw ArgumentError.value(pattern, 'pattern', 'Invalid glob: give one relative to the directory, inside it');
  }
  var brackets = 0, braces = 0;
  for (var i = 0; i < pattern.length; i++) {
    switch (pattern[i]) {
      case r'\':
        i++;
      case '[' when brackets == 0:
        brackets = 1;
      case ']' when brackets == 1:
        brackets = 0;
      case '{' when brackets == 0:
        braces++;
      case '}' when brackets == 0 && braces > 0:
        braces--;
    }
  }
  if (brackets > 0) throw FormatException('Invalid glob "$pattern": a [ is not closed', pattern);
  if (braces > 0) throw FormatException('Invalid glob "$pattern": a { is not closed', pattern);
  return _glob(pattern);
}

final _globCache = <String, RegExp>{};

/// The shared mini-glob compiler: `**/` spans zero or more folders, `**` spans
/// anything, `*`/`?` stay within one segment, `[...]`/`{a,b}` group, `\` escapes.
RegExp _glob(String pattern) {
  if (_globCache.remove(pattern) case final hit?) return _globCache[pattern] = hit;
  if (_globCache.length >= 256) _globCache.remove(_globCache.keys.first);
  return _globCache[pattern] = _globToRegex(pattern);
}

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
    if (c == r'\') {
      i++;
      continue;
    }
    if (c == '{') depth++;
    if (c == ',' && depth == 1) choice = true;
    if (c == '}' && --depth == 0) return choice ? i : -1;
  }
  return -1;
}

final _classEscape = RegExp(r'[\\^\[\]]');

/// [pattern] as a regular expression, case-insensitive where the platform's paths are.
RegExp _globToRegex(String pattern) =>
    RegExp(_globSource(pattern), caseSensitive: !io.Platform.isWindows && !io.Platform.isMacOS);

String _globSource(String g) {
  final buffer = StringBuffer('^');
  // The ends of the braces open around `i`, innermost last: a `,` inside one is `|`.
  final braces = <int>[];
  var i = 0;
  while (i < g.length) {
    final c = g[i];
    // `\x` is `x` itself; a `\` at the end is one.
    if (c == r'\') {
      buffer.write(RegExp.escape(i + 1 < g.length ? g[i + 1] : c));
      i += 2;
      continue;
    }
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

/// What kind of change a [Dir.watch] event reports.
enum WatchType { create, modify, delete, move, other }

/// A filesystem change.
final class WatchEvent {
  final WatchType type;
  final String path;

  WatchEvent(this.type, this.path);

  WatchEvent._(io.FileSystemEvent e)
    : type = switch (e) {
        io.FileSystemCreateEvent() => WatchType.create,
        io.FileSystemModifyEvent() => WatchType.modify,
        io.FileSystemDeleteEvent() => WatchType.delete,
        io.FileSystemMoveEvent() => WatchType.move,
      },
      path = e.path;

  @override
  String toString() => '${type.name}: $path';
}

/// A symbolic link: [make] it, read its [target], [drop] it.
final class Link {
  final String _path;

  Link(Object path) : _path = path is Path ? path.str : path.toString();

  /// The path as written.
  String get str => _path;

  @override
  String toString() => _path;

  /// The path as a [Path].
  Path get path => Path(_path);

  /// Whether a link sits at this path.
  Future<bool> get exists => io.Link(_path).exists();

  /// Whether a link (not its target) sits here.
  bool existsSync() => io.Link(_path).existsSync();

  /// Creates this link pointing at [target].
  Future<void> make({required Object target}) => io.Link(_path).create(Path(target).str);

  /// The link's target.
  Future<String> get target => io.Link(_path).target();

  /// Deletes this link.
  Future<void> drop() async {
    final l = io.Link(_path);
    if (await l.exists()) await l.delete();
  }
}

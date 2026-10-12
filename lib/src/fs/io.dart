import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/native.dart' as l2native;
import '../core/traits.dart';

export '../core/errors.dart';
export '../core/pipe.dart';
export '../core/traits.dart';

/// The native `tk_chmod`/`tk_copy_file`/`tk_file_id`/`tk_rename` calls behind
/// [File] (cutover: the engine owns them). Looked up once per isolate from
/// [l2native.require], so a missing library throws
/// [UnsupportedError] before reaching them.
abstract final class _FsNative {
  static ffi.DynamicLibrary get _lib => l2native.require();

  static final chmod = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr, ffi.Uint32),
        int Function(ffi.Pointer<ffi.Uint8>, int, int)
      >('tk_chmod');

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
/// [UnsupportedError] (rule 42: no Dart fallback).
Future<void> renameFile(String src, String dst) async {
  final rc = l2native.withText(src, (sp, sn) {
    return l2native.withText(dst, (dp, dn) {
      return _FsNative.rename(sp, sn, dp, dn);
    });
  });
  if (rc < 0) throw _fsFileError(l2native.lastError(), src, 'Cannot rename');
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
Future<String> sandbox(Object root, String member) async {
  final base = root.toString();
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
  return joined;
}

/// Joins [b] under [a] with the platform separator (skipped when [a] already
/// ends with one).
String _join(String a, String b) {
  final sep = io.Platform.pathSeparator;
  if (a.isNotEmpty && !a.endsWith('/') && !a.endsWith(sep)) a = '$a$sep';
  return '$a$b';
}

/// A file. A [Source] and a [Target]: `pipe` opens a reader/writer inside, so
/// [text]/[bytes]/[lines] stay one-shot and [write] replaces atomically.
///
/// The one `Object` parameter is text-or-bytes: a `String` is UTF-8 encoded, a
/// `List<int>`/`Uint8List` is written verbatim, anything else is an
/// [ArgumentError]. A reading on a missing file throws [io.PathNotFoundException].
final class File implements Source, Target {
  File(this.path);

  /// The path as written.
  final String path;

  /// The last segment.
  String get name {
    final clean = path.replaceAll('\\', '/');
    final i = clean.lastIndexOf('/');
    return i == -1 ? clean : clean.substring(i + 1);
  }

  /// The directory holding this file.
  Dir get parent => Dir(io.File(path).parent.path);

  /// Whether anything sits at this path.
  Future<bool> exists() => io.File(path).exists();

  /// Size in bytes, or 0 when missing ([Target] needs 0 for resume).
  @override
  Future<int> size() async {
    try {
      return await io.File(path).length();
    } on io.PathNotFoundException {
      return 0;
    }
  }

  /// Whether a symlink sits at this path.
  Future<bool> isLink() => io.FileSystemEntity.isLink(path);

  /// The symlink's target as a [File], or null when this is not a link.
  Future<File?> target() async {
    if (!await isLink()) return null;
    return File(await io.Link(path).target());
  }

  /// The whole file decoded as UTF-8.
  Future<String> text() => io.File(path).readAsString();

  /// The whole file as bytes.
  Future<Uint8List> bytes() => io.File(path).readAsBytes();

  /// A stream of the file's UTF-8 lines.
  Stream<String> lines() => io.File(path).openRead().transform(utf8.decoder).transform(const LineSplitter());

  /// Replaces the file with [data] (`String` or `List<int>`), atomically: a
  /// temporary sibling is renamed over the target (held-target retries on
  /// Windows), so a failed write leaves the old content and no temp behind.
  Future<void> write(Object data) async {
    final bytes = _writeBytes(data);
    final tmp = '$path.tmp_${DateTime.now().microsecondsSinceEpoch}';
    try {
      await io.File(tmp).writeAsBytes(bytes);
    } catch (_) {
      await _gone(tmp);
      rethrow;
    }
    try {
      await renameFile(tmp, path);
    } catch (_) {
      await _gone(tmp);
      rethrow;
    }
  }

  /// Appends [data] (`String` or `List<int>`) to the file, creating it if needed.
  Future<void> append(Object data) async {
    final bytes = _writeBytes(data);
    await io.File(path).writeAsBytes(bytes, mode: io.FileMode.append);
  }

  /// Copies this file to [to] atomically (via a temporary sibling renamed
  /// over the target) with `tk_copy_file` (source permission bits kept,
  /// partial destination removed); answers [to]. Without the library it is an
  /// [UnsupportedError] (rule 42: no Dart fallback).
  Future<File> copy(File to) async {
    final tmp = '${to.path}.tmp_${DateTime.now().microsecondsSinceEpoch}';
    try {
      await _nativeCopy(path, tmp);
      await renameFile(tmp, to.path);
    } catch (_) {
      await _gone(tmp);
      rethrow;
    }
    return to;
  }

  /// Moves (renames) this file to [to] (held-target retries on Windows);
  /// across volumes it copies and then drops the source, so the destination
  /// is complete before the source is touched; answers [to].
  Future<File> move(File to) async {
    try {
      await renameFile(path, to.path);
      return to;
    } on io.FileSystemException catch (e) {
      if (!_isCrossVolume(e)) rethrow;
    }
    await copy(to);
    await drop();
    return to;
  }

  /// Deletes this file if it exists.
  Future<void> drop() async {
    final f = io.File(path);
    if (await f.exists()) await f.delete();
  }

  /// Changes the permission bits (octal [mode]) through `tk_chmod`: one
  /// system call, and on Windows the owner's write bit maps to read-only.
  /// Without the native library it is an [UnsupportedError] (rule 42: no Dart
  /// fallback, no process spawn).
  Future<void> chmod(int mode) async {
    final rc = l2native.withText(path, (ptr, len) => _FsNative.chmod(ptr, len, mode));
    if (rc < 0) throw _fsFileError(l2native.lastError(), path, 'Cannot chmod');
  }

  /// Makes [link] a symbolic link to this file; answers [link].
  Future<File> symlink(File link) async {
    await io.Link(link.path).create(path);
    return link;
  }

  /// A uniquely named temporary file.
  static Future<File> temp({String? ext}) async {
    final dir = await io.Directory.systemTemp.createTemp('tk_');
    return File(_join(dir.path, 'temp${ext ?? '.tmp'}'));
  }

  /// A file's unpacking goes by path, so there is no streamed length to hint.
  @override
  int? get lengthHint => null;

  /// A reader over this file starting at [from], so a half-read file resumes:
  /// `await src.pipe(dst, resume: true)`.
  @override
  Future<Reader> reader({int from = 0}) async {
    if (from < 0) throw ArgumentError.value(from, 'from', 'Must be non-negative');
    final raf = await io.File(path).open(mode: io.FileMode.read);
    try {
      await raf.setPosition(from);
    } catch (_) {
      await raf.close();
      rethrow;
    }
    return _FileReader(raf);
  }

  /// A writer for this file. It replaces atomically: chunks go to a temporary
  /// sibling that [Writer.close] renames over the target (on an error the
  /// temp is deleted and the old content stays). With [resume], it appends to
  /// the file itself, so a partial file survives a crash.
  @override
  Future<Writer> writer({bool resume = false}) async {
    if (resume) return _AppendWriter(io.File(path).openWrite(mode: io.FileMode.append));
    final tmp = '$path.tmp_${DateTime.now().microsecondsSinceEpoch}';
    return _AtomicWriter(io.File(tmp).openWrite(), tmp, path);
  }

  @override
  String toString() => path;

  @override
  bool operator ==(Object other) => other is File && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// A reader over an open file, with seeking for range-resume.
final class _FileReader implements Reader, Seeker {
  final io.RandomAccessFile _raf;
  var _closed = false;

  _FileReader(this._raf);

  @override
  Future<int> read(Uint8List buf) async {
    if (_closed) throw StateError('Cannot read: file is closed');
    return _raf.readInto(buf);
  }

  /// Moves the read position to [offset] (from the start) and answers it.
  @override
  Future<int> seek(int offset) async {
    if (offset < 0) throw ArgumentError.value(offset, 'offset', 'Must be non-negative');
    await _raf.setPosition(offset);
    return offset;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _raf.close();
  }
}

/// A [Writer] that replaces its target atomically: chunks land in a temporary
/// sibling; [close] renames it over the target, so the file is never
/// half-written. On an error the temp is deleted and the old content stays.
final class _AtomicWriter implements Writer {
  final io.IOSink _sink;
  final String _tmp;
  final String _target;
  var _closed = false;

  _AtomicWriter(this._sink, this._tmp, this._target);

  @override
  Future<int> write(Uint8List data) async {
    _sink.add(data);
    return data.length;
  }

  @override
  Future<void> flush() => _sink.flush();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _sink.close();
    } catch (_) {
      await _gone(_tmp);
      rethrow;
    }
    try {
      await renameFile(_tmp, _target);
    } catch (_) {
      await _gone(_tmp);
      rethrow;
    }
  }
}

/// A [Writer] that appends to the file itself: a partial file survives a
/// crash, so a resumed transfer can continue from [File.size].
final class _AppendWriter implements Writer {
  final io.IOSink _sink;
  var _closed = false;

  _AppendWriter(this._sink);

  @override
  Future<int> write(Uint8List data) async {
    _sink.add(data);
    return data.length;
  }

  @override
  Future<void> flush() => _sink.flush();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sink.close();
  }
}

/// [data] as bytes: a `String` is UTF-8 encoded, a `List<int>`/`Uint8List` is
/// written verbatim, anything else is an [ArgumentError].
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
  final rc = l2native.withBytes(s, (sp, sn) {
    return l2native.withBytes(d, (dp, dn) {
      return _FsNative.copyFile(sp, sn, dp, dn, ffi.nullptr, ffi.nullptr);
    });
  });
  if (rc < 0) throw _fsFileError(l2native.lastError(), src, 'Cannot copy');
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

/// A directory: [make] it, [drop] it, list [files]/[dirs], recursive [find] by
/// glob, [watch] it — and [file]/[dir] for children by name.
final class Dir {
  Dir(this.path);

  /// The path as written.
  final String path;

  /// The last segment.
  String get name {
    final clean = path.replaceAll('\\', '/');
    final i = clean.lastIndexOf('/');
    return i == -1 ? clean : clean.substring(i + 1);
  }

  /// The directory holding this directory.
  Dir get parent => Dir(io.File(path).parent.path);

  /// Creates a unique temporary directory.
  static Future<Dir> temp() async => Dir((await io.Directory.systemTemp.createTemp('tk_dir_')).path);

  /// Whether anything sits at this path.
  Future<bool> exists() => io.Directory(path).exists();

  /// Creates this directory (and parents).
  Future<void> make() => io.Directory(path).create(recursive: true);

  /// Deletes this directory and everything in it.
  Future<void> drop() async {
    final d = io.Directory(path);
    if (await d.exists()) await d.delete(recursive: true);
  }

  /// The files directly below this directory, sorted by path.
  Future<List<File>> files() async {
    final out = <File>[];
    await for (final entity in io.Directory(path).list(recursive: false, followLinks: false)) {
      if (entity is io.File) out.add(File(entity.path));
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// The folders directly below this directory, sorted by path.
  Future<List<Dir>> dirs() async {
    final out = <Dir>[];
    await for (final entity in io.Directory(path).list(recursive: false, followLinks: false)) {
      if (entity is io.Directory) out.add(Dir(entity.path));
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
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
  Future<List<File>> find(String glob) async {
    final matcher = _checkedGlob(glob);
    if (!await io.Directory(path).exists()) {
      throw io.PathNotFoundException(path, const io.OSError('No such file or directory', 2), 'Cannot list');
    }
    final out = <File>[];
    final stream = io.Directory(path).list(recursive: true, followLinks: false);
    await for (final entity in stream) {
      if (entity is! io.File) continue;
      final rel = _relativeTo(path, entity.path);
      if (matcher.hasMatch(rel)) out.add(File(entity.path));
    }
    return out;
  }

  /// A stream of changes below this directory.
  Stream<WatchEvent> watch() => io.Directory(path).watch().map(WatchEvent._);

  /// The file [name] directly below this directory.
  File file(String name) => File(_join(path, name));

  /// The folder [name] directly below this directory.
  Dir dir(String name) => Dir(_join(path, name));

  @override
  String toString() => path;

  @override
  bool operator ==(Object other) => other is Dir && other.path == path;

  @override
  int get hashCode => path.hashCode;
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

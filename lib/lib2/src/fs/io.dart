import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import '../core/traits.dart';

/// A filesystem path: `operator /` to join, [name] for the last segment, [isLink] and
/// [target] for symlinks, and sandbox-safe [resolve]/[starts].
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

  /// Whether this path is [root] itself or sits below it.
  bool starts(Path root) {
    String norm(String s) => s.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final here = norm(_str);
    final there = norm(root._str);
    return here == there || here.startsWith('$there/');
  }

  @override
  String toString() => _str;

  @override
  bool operator ==(Object other) => other is Path && other._str == _str;

  @override
  int get hashCode => _str.hashCode;
}

/// A file: [text], [bytes], [write], [atomic] and the streaming [read]/[write] of a [Reader]
/// and [Writer]. `File.open` gives a reader over an open handle.
final class File implements Reader, Writer, Closer {
  final String _path;
  io.RandomAccessFile? _raf;
  int _readPos = 0;

  File(Object path) : _path = path is Path ? path.str : path.toString();

  /// The path as written.
  String get str => _path;

  @override
  String toString() => _path;

  /// The path as a [Path].
  Path get path => Path(_path);

  /// The last segment.
  String get name => Path(_path).name;

  /// Opens this file for reading and answers a reader over it.
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
    if (data is String) {
      final bytes = utf8.encode(data);
      await io.File(_path).writeAsBytes(bytes, flush: false);
      return bytes.length;
    }
    if (data is List<int>) {
      await io.File(_path).writeAsBytes(data, flush: false);
      return data.length;
    }
    throw ArgumentError.value(data, 'data', 'Must be String or List<int>');
  }

  /// Appends [data] to the file, creating it if needed.
  Future<int> append(Object data) async {
    final bytes = data is List<int> ? data : utf8.encode(data.toString());
    await io.File(_path).writeAsBytes(bytes, mode: io.FileMode.append);
    return bytes.length;
  }

  /// Writes [data] to a temporary sibling, then renames it atomically over this file.
  Future<void> atomic(Object data) async {
    final tmp = io.File('$_path.tmp_${DateTime.now().microsecondsSinceEpoch}');
    if (data is String) {
      await tmp.writeAsString(data);
    } else if (data is List<int>) {
      await tmp.writeAsBytes(data);
    } else {
      throw ArgumentError.value(data, 'data', 'Must be String or List<int>');
    }
    await tmp.rename(_path);
  }

  /// Copies this file to [dst].
  Future<void> copy(Object dst) => io.File(_path).copy(Path(dst).str);

  /// Moves (renames) this file to [dst].
  Future<void> move(Object dst) => io.File(_path).rename(Path(dst).str);

  /// Deletes this file if it exists.
  Future<void> drop() async {
    final f = io.File(_path);
    if (await f.exists()) await f.delete();
  }

  /// Makes [dst] a hard link to this file.
  Future<void> hardlink(Object dst) => io.Link(Path(dst).str).create(_path);

  /// Changes the permission bits (octal [mode]); a no-op on Windows.
  Future<void> chmod(int mode) async {
    if (!io.Platform.isWindows) {
      await io.Process.run('chmod', [mode.toRadixString(8), _path]);
    }
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
    final n = await raf.readInto(buf, _readPos);
    if (n > 0) _readPos += n;
    return n;
  }

  @override
  Future<void> flush() async => _raf?.flush();

  @override
  Future<void> close() async {
    await _raf?.close();
    _raf = null;
  }
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
    final bytes = data is List<int> ? data : utf8.encode(data.toString());
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

  /// Every file below this directory whose name matches the glob [pattern].
  Future<List<File>> find(String pattern) async {
    final reg = _glob(pattern);
    final out = <File>[];
    await for (final entity in io.Directory(_path).list(recursive: true, followLinks: false)) {
      if (entity is io.File) {
        final name = Path(entity.path).name;
        if (reg.hasMatch(name)) out.add(File(entity.path));
      }
    }
    return out;
  }

  /// Every immediate entry.
  Stream<io.FileSystemEntity> list() => io.Directory(_path).list();

  /// A stream of changes below this directory.
  Stream<WatchEvent> watch() => io.Directory(_path).watch().map(WatchEvent._);
}

final _globCache = <String, RegExp>{};

RegExp _glob(String pattern) => _globCache.putIfAbsent(pattern, () {
  final sb = StringBuffer('^');
  for (final unit in pattern.codeUnits) {
    final c = String.fromCharCode(unit);
    switch (c) {
      case '*':
        sb.write('[^/\\\\]*');
      case '?':
        sb.write('.');
      case '.':
        sb.write(r'\.');
      default:
        sb.write(RegExp.escape(c));
    }
  }
  sb.write(r'$');
  return RegExp(sb.toString());
});

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

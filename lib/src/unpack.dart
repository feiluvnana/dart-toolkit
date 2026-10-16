/// What every in-memory and staged extraction shares: member types, the
/// name checks, link placement, and [unpackEntries]. Imported by `archive`
/// and by `decode_worker.dart` (the 7z and RAR decoders' own isolate), so
/// both write a tree the same way.
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core.dart';
import 'names.dart' as naming;

/// What a member is.
enum Kind { file, dir, symlink, hardlink }

/// One member of an in-memory archive as read: its bytes (a link's target)
/// decode on demand.
typedef Entry = ({String name, int mode, Kind kind, DateTime? mtime, Uint8List Function() data});

/// A link member, placed once every other member is in: links go in last,
/// so no member is ever written through one.
typedef Link = ({String name, String target, bool hard});

/// Every path whose mode is set after the merge: path, mode, folder.
typedef Modes = List<(String, int, bool)>;

/// The bytes an unpack may write (`unarchive(dir, max:)`; null is no
/// cap): each file and each hardlink copy takes its size from it.
final class Budget {
  Budget(this.max);

  final int? max;
  var _used = 0;

  /// Takes [n] bytes for member [name]; past [max] a [ContentException].
  void take(int n, String name) {
    final m = max;
    if (m != null && (_used += n) > m) {
      throw ContentException('archive unpacks to more than max: $m bytes (at $name)');
    }
  }
}

/// Runs one step of an in-memory reader. A [ContentException] passes; any
/// other failure (a RangeError from a damaged header, an OutOfMemoryError
/// from a hostile size) is damage too, rethrown naming [what].
T guard<T>(String what, T Function() body) {
  try {
    return body();
  } on ContentException {
    rethrow;
  } catch (e) {
    throw ContentException('corrupt archive: $what: $e', null, null, e);
  }
}

/// Unpacks [entries] (an in-memory zip, 7z or RAR) into [tmp], on a worker
/// isolate: every name and link is checked first, then each member is
/// decoded and written in turn (any damage it hits named after it), links
/// last; every byte written is taken from [budget]. Returns the modes to
/// set.
Modes unpackEntries(List<Entry> entries, String tmp, Budget budget) {
  final folded = <String, String>{};
  final links = <Link>[];
  for (final e in entries) {
    checkMember(e.name, folded);
    if (e.kind == Kind.symlink || e.kind == Kind.hardlink) {
      final target = utf8.decode(guard(e.name, e.data), allowMalformed: true);
      links.add((name: e.name, target: target, hard: e.kind == Kind.hardlink));
    }
  }
  final Modes modes = [];
  final written = <String>{};
  final made = <String>{tmp};
  for (final e in entries) {
    if (e.kind == Kind.symlink || e.kind == Kind.hardlink) continue;
    final dest = destIn(tmp, e.name);
    if (dest == null) continue;
    final parent = p.dirname(dest);
    if (made.add(parent)) io.Directory(parent).createSync(recursive: true);
    if (e.kind == Kind.dir) {
      if (made.add(dest)) io.Directory(dest).createSync(recursive: true);
      modes.add((dest, e.mode, true));
      continue;
    }
    if (written.add(dest) && io.File(dest).existsSync()) {
      throw ContentException('archive members collide on this filesystem: ${e.name}');
    }
    final data = guard(e.name, e.data);
    budget.take(data.length, e.name);
    io.File(dest).writeAsBytesSync(data);
    final t = e.mtime;
    if (t != null) io.File(dest).setLastModifiedSync(t);
    modes.add((dest, e.mode, false));
  }
  modes.addAll(placeLinks(tmp, links, modes, budget));
  return modes;
}

/// [name]'s path inside [tmp]; null for a bare root entry. Split on both
/// separators so member names work on every platform; '.' segments name
/// nothing (a '.' member is the target itself, whose mode an archive never
/// sets).
String? destIn(String tmp, String name) {
  final parts = segments(name);
  return parts.isEmpty ? null : p.joinAll([tmp, ...parts]);
}

/// A member path's segments, without empty and '.' ones.
List<String> segments(String path) => [
  for (final s in path.replaceAll('\\', '/').split('/'))
    if (s.isNotEmpty && s != '.') s,
];

/// An absolute path on any OS: `/x`, `\x`, `C:`.
bool absolute(String path) => path.startsWith('/') || path.startsWith('\\') || _drive.hasMatch(path);

final _drive = RegExp(r'^[A-Za-z]:');

/// The member path [parts] lead to from the root, following every symlink
/// of the archive ([symlinks], case-folded name to target) on the way, as
/// a case-folding filesystem would once they exist; null when the walk
/// leaves the root or loops.
List<String>? _resolve(List<String> parts, Map<String, String> symlinks, [int depth = 0]) {
  final at = <String>[];
  for (final s in parts) {
    if (s == '..') {
      if (at.isEmpty) return null;
      at.removeLast();
      continue;
    }
    at.add(s);
    final target = symlinks[at.join('/').toLowerCase()];
    if (target == null) continue;
    if (depth >= 32 || absolute(target)) return null;
    at.removeLast();
    final to = _resolve([...at, ...segments(target)], symlinks, depth + 1);
    if (to == null) return null;
    at
      ..clear()
      ..addAll(to);
  }
  return at;
}

/// Puts [links] into [tmp], where every other member already is. A
/// symlink must resolve inside the root through the archive's own links
/// (its target is kept as written); a hardlink must name a file of the
/// archive and lands as a copy of it, with its mode ([modes]) and mtime,
/// its size taken from [budget].
/// Anything else fails by name before the first link is made, and a placed
/// symlink the OS resolves outside [tmp] (a filesystem folding case or
/// Unicode normalisation) fails once they are in. A link never
/// replaces a member, and nothing is placed through a link. Returns the
/// modes of the copies. Shared by every format, and by any extractor that
/// fills [tmp] itself.
Modes placeLinks(String tmp, List<Link> links, Modes modes, Budget budget) {
  if (links.isEmpty) return const [];
  final symlinks = {
    for (final l in links)
      if (!l.hard) segments(l.name).join('/').toLowerCase(): l.target,
  };
  final Modes out = [];
  final planned = <(Link, String, List<String>)>[];
  for (final l in links) {
    final at = segments(l.name);
    if (at.isEmpty) throw ContentException('archive link has no name: ${l.name}');
    final to = absolute(l.target)
        ? null
        : _resolve(l.hard ? segments(l.target) : [...at.sublist(0, at.length - 1), ...segments(l.target)], symlinks);
    if (to == null) throw ContentException('archive link points outside the folder: ${l.name} -> ${l.target}');
    planned.add((l, p.joinAll([tmp, ...at]), to));
  }
  final modeOf = {
    for (final (path, mode, isDir) in modes)
      if (!isDir) path: mode,
  };
  bool throughLink(String dest) {
    for (var d = p.dirname(dest); d.length > tmp.length; d = p.dirname(d)) {
      if (io.FileSystemEntity.typeSync(d, followLinks: false) == io.FileSystemEntityType.link) return true;
    }
    return false;
  }

  // Copies first (their sources are plain files), then the symlinks.
  for (final hard in [true, false]) {
    for (final (l, dest, to) in planned) {
      if (l.hard != hard) continue;
      final type = io.FileSystemEntity.typeSync(dest, followLinks: false);
      if (type == io.FileSystemEntityType.link && !hard) {
        io.Link(dest).deleteSync(); // a repeated link member: the last one wins
      } else if (type != io.FileSystemEntityType.notFound || throughLink(dest)) {
        throw ContentException('archive link collides with a member: ${l.name}');
      }
      io.Directory(p.dirname(dest)).createSync(recursive: true);
      if (!hard) {
        io.Link(dest).createSync(l.target);
        continue;
      }
      final src = p.joinAll([tmp, ...to]);
      if (io.FileSystemEntity.typeSync(src, followLinks: false) != io.FileSystemEntityType.file) {
        throw ContentException('archive hardlink target is not a file of the archive: ${l.name} -> ${l.target}');
      }
      budget.take(io.File(src).lengthSync(), l.name);
      io.File(src).copySync(dest);
      io.File(dest).setLastModifiedSync(io.File(src).lastModifiedSync());
      out.add((dest, modeOf[src] ?? 0, false));
    }
  }
  // The OS has the last word: a filesystem that folds Unicode
  // normalisation (or case, past the walk above) can resolve a link
  // elsewhere than its spelling says.
  final root = io.Directory(tmp).resolveSymbolicLinksSync();
  for (final (l, dest, _) in planned) {
    if (l.hard) continue;
    final real = _real(p.join(p.dirname(dest), l.target));
    if (real != root && !p.isWithin(root, real)) {
      throw ContentException('archive link points outside the folder: ${l.name} -> ${l.target}');
    }
  }
  return out;
}

/// [path] as the OS resolves it: its longest existing prefix through
/// every link, the rest (not there yet) normalised as written.
String _real(String path) {
  final tail = <String>[];
  for (var head = path;; head = p.dirname(head)) {
    try {
      return p.normalize(p.joinAll([io.File(head).resolveSymbolicLinksSync(), ...tail.reversed]));
    } on io.FileSystemException {
      if (p.dirname(head) == head) rethrow;
      tail.add(p.basename(head));
    }
  }
}

final _badPart = RegExp(r'[<>:"|?*\x00-\x1f]');

/// Rejects, on every OS, any name that would not extract the same way on
/// Linux, macOS and Windows: escapes, device names, characters and
/// trailing dots/spaces Windows rewrites, and members (or folders) that
/// differ only in case. [folded] remembers each path seen, case-folded.
void checkMember(String name, Map<String, String> folded) {
  if (name.isEmpty) {
    throw const ContentException('archive member has an empty name');
  }
  if (absolute(name)) {
    throw ContentException('archive member escapes: $name');
  }
  var path = '';
  for (final part in name.replaceAll('\\', '/').split('/')) {
    if (part == '..' ||
        part.endsWith('.') && part != '.' ||
        part.endsWith(' ') ||
        _badPart.hasMatch(part) ||
        naming.isReserved(part)) {
      throw ContentException('archive member escapes: $name');
    }
    if (part.isEmpty || part == '.') continue;
    path = path.isEmpty ? part : '$path/$part';
    if ((folded[path.toLowerCase()] ??= path) != path) {
      throw ContentException('archive members differ only in case: $name');
    }
  }
}

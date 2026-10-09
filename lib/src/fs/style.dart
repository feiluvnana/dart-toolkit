part of '../path.dart';

// The path grammar, in house: what `package:path` did for POSIX and Windows, at a fraction of
// the compile. `test/path_diff_test.dart` checks every function against the package in both
// styles.

/// Whether paths are read the Windows way: `\` and `/` separate, `C:\` and `\\server\share`
/// are roots. A test swaps it with [PathInternals.styled].
bool _windows = Platform.isWindows;

/// The working directory [_absolute] resolves against; a test sets it with [PathInternals.styled].
String? _cwdOverride;

String get _separator => _windows ? r'\' : '/';

bool _isSeparator(int c) => c == 0x2f || (_windows && c == 0x5c);

/// How long the root at [path]'s start is: `/`, and on Windows `\` (root-relative), `C:\`
/// (`C:/`) and `\\server\share`; 0 when it is relative.
int _rootLength(String path) {
  if (path.isEmpty) return 0;
  final c = path.codeUnitAt(0);
  if (c == 0x2f) return 1;
  if (!_windows) return 0;
  if (c == 0x5c) {
    if (path.length < 2 || path.codeUnitAt(1) != 0x5c) return 1;
    var i = path.indexOf(r'\', 2);
    if (i > 0) {
      i = path.indexOf(r'\', i + 1);
      if (i > 0) return i;
    }
    return path.length;
  }
  if (path.length < 3 || path.codeUnitAt(1) != 0x3a || !_isSeparator(path.codeUnitAt(2))) return 0;
  final letter = c | 0x20;
  return letter >= 0x61 && letter <= 0x7a ? 3 : 0;
}

bool _isAbsolute(String path) => _rootLength(path) > 0;

/// A Windows `\x`: absolute on the current drive.
bool _isRootRelative(String path) => _windows && _rootLength(path) == 1;

bool _endsWithSeparator(String path) => path.isNotEmpty && _isSeparator(path.codeUnitAt(path.length - 1));

/// [base] and [part] joined by one separator, not normalized; an absolute [part] replaces
/// [base], and a Windows root-relative one keeps [base]'s drive.
String _join(String base, String part) {
  if (part.isEmpty) return base;
  if (base.isEmpty) return part;
  final root = _rootLength(part);
  if (root > 0) {
    if (root == 1 && _windows && _isAbsolute(base) && !_isRootRelative(base)) {
      final drive = base.substring(0, _rootLength(base));
      return _endsWithSeparator(drive) ? '$drive${part.substring(1)}' : '$drive$_separator${part.substring(1)}';
    }
    return part;
  }
  return _endsWithSeparator(base) || _isSeparator(part.codeUnitAt(0)) ? '$base$part' : '$base$_separator$part';
}

/// [path] without `.`, empty and resolvable `..` segments, with this platform's separator and
/// no trailing one; `.` when nothing is left of a relative path.
String _normalize(String path) {
  if (!_needsNormalizing(path)) return path;
  final rootLength = _rootLength(path);
  var root = path.substring(0, rootLength);
  if (_windows) root = root.replaceAll('/', r'\');
  final parts = <String>[];
  var leadingUps = 0;
  var start = rootLength;
  for (var i = rootLength; i <= path.length; i++) {
    if (i < path.length && !_isSeparator(path.codeUnitAt(i))) continue;
    final part = path.substring(start, i);
    start = i + 1;
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) {
        parts.removeLast();
      } else {
        leadingUps++;
      }
    } else {
      parts.add(part);
    }
  }
  if (rootLength == 0) {
    if (leadingUps > 0) parts.insertAll(0, List.filled(leadingUps, '..'));
    if (parts.isEmpty) return '.';
    return parts.join(_separator);
  }
  if (parts.isEmpty) return root;
  return _endsWithSeparator(root) ? '$root${parts.join(_separator)}' : '$root$_separator${parts.join(_separator)}';
}

/// Whether [_normalize] changes [path]: a `.`, `..` or empty segment, a trailing separator,
/// and on Windows a `/`. `false` means [path] is already normal.
bool _needsNormalizing(String path) {
  if (path.isEmpty) return true;
  final root = _rootLength(path);
  if (_windows && path.substring(0, root).contains('/')) return true;
  if (root == path.length) return false;
  var start = root;
  for (var i = root; i <= path.length; i++) {
    if (i < path.length) {
      final c = path.codeUnitAt(i);
      if (!_isSeparator(c)) continue;
      if (_windows && c == 0x2f) return true;
    }
    final length = i - start;
    if (length == 0) return true;
    if (length <= 2 && path.codeUnitAt(start) == 0x2e && path.codeUnitAt(i - 1) == 0x2e) return true;
    start = i + 1;
  }
  return false;
}

/// Where the segment ending at [end] starts.
int _segmentStart(String path, int end) {
  var i = end;
  while (i > 0 && !_isSeparator(path.codeUnitAt(i - 1))) {
    i--;
  }
  return i;
}

/// [path] against the working directory, not normalized.
String _absolute(String path) =>
    _isAbsolute(path) && !_isRootRelative(path) ? path : _join(_cwdOverride ?? Directory.current.path, path);

/// Where [path]'s last segment ends, past its trailing separators but not into its root.
int _trimmedEnd(String path, int rootLength) {
  var end = path.length;
  while (end > rootLength && _isSeparator(path.codeUnitAt(end - 1))) {
    end--;
  }
  return end;
}

/// The last segment, trailing separators ignored; the root when there is only a root.
String _basename(String path) {
  final rootLength = _rootLength(path);
  final end = _trimmedEnd(path, rootLength);
  if (end == rootLength) return path.substring(0, rootLength);
  final start = _segmentStart(path, end);
  return path.substring(start < rootLength ? rootLength : start, end);
}

/// Everything before the last segment; the root, or `.` for a relative path of one segment.
String _dirname(String path) {
  final rootLength = _rootLength(path);
  final end = _trimmedEnd(path, rootLength);
  var start = _segmentStart(path, end);
  if (start <= rootLength) return rootLength == 0 ? '.' : path.substring(0, rootLength);
  while (start > rootLength && _isSeparator(path.codeUnitAt(start - 1))) {
    start--;
  }
  return start == rootLength ? (rootLength == 0 ? '.' : path.substring(0, rootLength)) : path.substring(0, start);
}

/// The last extension with its dot (`.gz` of `a.tar.gz`), or `''`: a leading dot is a name.
String _extension(String path) {
  final rootLength = _rootLength(path);
  final end = _trimmedEnd(path, rootLength);
  if (end == rootLength) return '';
  final start = _segmentStart(path, end) < rootLength ? rootLength : _segmentStart(path, end);
  final dot = path.lastIndexOf('.', end - 1);
  if (dot <= start || path.substring(start, end) == '..') return '';
  return path.substring(dot, end);
}

/// [path] with its last extension replaced by [ext], dot included (`''` removes it).
String _setExtension(String path, String ext) {
  final rootLength = _rootLength(path);
  final end = _trimmedEnd(path, rootLength);
  return '${path.substring(0, end - _extension(path).length)}$ext';
}

final _eitherSlash = RegExp(r'[/\\]');

/// The segments, the root first when there is one; empty segments left out.
List<String> _split(String path) {
  final rootLength = _rootLength(path);
  return [
    if (rootLength > 0) path.substring(0, rootLength),
    for (final part in path.substring(rootLength).split(_windows ? _eitherSlash : '/'))
      if (part.isNotEmpty) part,
  ];
}

/// Whether two normalized segments (or roots) name the same thing: on Windows, ignoring case
/// and the kind of slash.
bool _same(String a, String b) =>
    _windows ? a.replaceAll('/', r'\').toLowerCase() == b.replaceAll('/', r'\').toLowerCase() : a == b;

/// [path] relative to [from] (the working directory when `null`), both made absolute first; a
/// path on another root comes back absolute.
String _relativePath(String path, {String? from}) {
  final base = _normalize(_absolute(from ?? '.'));
  final target = _normalize(_absolute(path));
  final (baseRoot, targetRoot) = (_rootLength(base), _rootLength(target));
  if (!_same(base.substring(0, baseRoot), target.substring(0, targetRoot))) return target;
  final b = _split(base)..removeAt(0);
  final t = _split(target)..removeAt(0);
  var common = 0;
  while (common < b.length && common < t.length && _same(b[common], t[common])) {
    common++;
  }
  final parts = [for (var i = common; i < b.length; i++) '..', ...t.skip(common)];
  return parts.isEmpty ? '.' : parts.join(_separator);
}

/// [a] and [b] as one comparable form: absolute, normalized, and on Windows lower case.
String _canonical(String path) {
  final normalized = _normalize(_absolute(path));
  return _windows ? normalized.toLowerCase() : normalized;
}

/// Whether [a] and [b] are the same place, however each is spelled.
bool _equals(String a, String b) => _canonical(a) == _canonical(b);

/// Whether [child] is strictly under [parent], however each is spelled.
bool _isWithin(String parent, String child) {
  final (p, c) = (_canonical(parent), _canonical(child));
  if (c.length <= p.length || !c.startsWith(p)) return false;
  return _endsWithSeparator(p) || _isSeparator(c.codeUnitAt(p.length));
}

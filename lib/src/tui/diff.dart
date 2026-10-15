// Diff: Myers unified hunks.
part of '../tui.dart';

extension RegionDiff on Region {
  /// A line diff: unified hunks with 3 context lines, gutter line numbers,
  /// `-`/`+` rows on red/green backgrounds, changed words of paired lines
  /// brighter.
  /// [removed] and [added] replace red and green; [color], [background]
  /// and [style] are the base of the context lines and [on] binds events,
  /// as in `write`.
  Region diff(
    String before,
    String after, {
    Color? removed,
    Color? added,
    Color? color,
    Color? background,
    Set<Style> style = const {},
    Map<String, Binding>? on,
  }) {
    final top = _cursor;
    final paint = (removed: removed, added: added, color: color, background: background, style: style);
    final key = (before, after);
    final rows = _diffMemo.remove(key) ?? _diffHunks(before.split('\n'), after.split('\n'));
    _diffMemo[key] = rows; // most recent last
    if (_diffMemo.length > 8) _diffMemo.remove(_diffMemo.keys.first);
    for (final line in rows) {
      if (_cursor >= _h) {
        _cursor++;
        continue;
      }
      var col = _gx;
      for (final seg in line) {
        col = _writeLine(_gy + _cursor, col, _gx + _w, seg.text, _s._diffStyle(seg, paint), null);
      }
      _cursor++;
    }
    _bindRows(on, top);
    return this;
  }
}

/// The last few diffs drawn: several `diff()` panes on one screen each
/// keep theirs (one shared slot recomputed both every frame).
final _diffMemo = <(String, String), List<List<_DiffSeg>>>{};

final class _DiffSeg {
  _DiffSeg(this.text, this.fg, this.bg, this.style);

  final String text;
  final Color? fg;
  final Color? bg;
  final Set<Style> style;
}

/// Myers O(ND) line diff, rendered as unified hunks: 3 context lines,
/// gutter line numbers, `-`/`+` rows on red/green, changed words of paired
/// lines brighter.
List<List<_DiffSeg>> _diffHunks(List<String> a, List<String> b) {
  // Strip one trailing empty from a trailing newline, like write().
  if (a.isNotEmpty && a.last.isEmpty) a = a.sublist(0, a.length - 1);
  if (b.isNotEmpty && b.last.isEmpty) b = b.sublist(0, b.length - 1);
  final script = _myers(a, b);
  // Group into hunks with 3 context lines.
  final hunks = <List<List<_DiffSeg>>>[];
  var hunk = <List<_DiffSeg>>[];
  var ai = 0, bi = 0; // line numbers consumed
  void flush() {
    if (hunk.isNotEmpty) {
      if (hunks.isNotEmpty) {
        hunks.add([
          [_DiffSeg('…', null, null, {})],
        ]);
      }
      hunks.add(hunk);
      hunk = [];
    }
  }

  // First pass: collect change blocks with context.
  final blocks = <(int, int, int, int)>[]; // (aStart, aEnd, bStart, bEnd)
  var k = 0;
  while (k < script.length) {
    if (script[k] == 0) {
      ai++;
      bi++;
      k++;
      continue;
    }
    final a0 = ai, b0 = bi;
    while (k < script.length && script[k] != 0) {
      if (script[k] < 0) {
        ai++;
      } else {
        bi++;
      }
      k++;
    }
    blocks.add((a0, ai, b0, bi));
  }
  // Group blocks separated by <= 6 context lines (3+3); equal lines between
  // blocks of a group render as context.
  final groups = <List<(int, int, int, int)>>[];
  for (final blk in blocks) {
    if (groups.isNotEmpty && blk.$1 - groups.last.last.$2 <= 6) {
      groups.last.add(blk);
    } else {
      groups.add([blk]);
    }
  }
  for (final group in groups) {
    hunk = [];
    final a0 = group.first.$1, b0 = group.first.$3;
    final ca0 = math.max(0, a0 - 3);
    final cb0 = math.max(0, b0 - 3);
    for (var t = 0; t < a0 - ca0; t++) {
      hunk.add(_diffRow(' ', ca0 + t + 1, cb0 + t + 1, a[ca0 + t], const {}));
    }
    for (var g = 0; g < group.length; g++) {
      final (ba0, a1, bb0, b1) = group[g];
      var da = ba0, db = bb0;
      while (da < a1 || db < b1) {
        if (da < a1 && db < b1) {
          hunk.addAll(_diffPair(a[da], da + 1, b[db], db + 1));
          da++;
          db++;
        } else if (da < a1) {
          hunk.add(_diffRow('-', da + 1, null, a[da], const {Style.bold}, del: true));
          da++;
        } else {
          hunk.add(_diffRow('+', null, db + 1, b[db], const {Style.bold}, del: false));
          db++;
        }
      }
      final next = g + 1 < group.length ? group[g + 1].$1 : null;
      final end = next ?? math.min(a1 + 3, math.min(a.length, a1 + b.length - b1));
      for (var t = 0; a1 + t < end; t++) {
        hunk.add(_diffRow(' ', a1 + t + 1, b1 + t + 1, a[a1 + t], const {}));
      }
    }
    flush();
  }
  return hunks.expand((h) => h).toList();
}

/// Myers diff as opcodes per consumed line: 0 same, -1 delete, +1 insert.
/// Common prefix and suffix are trimmed first; past [_maxEdits] edits the
/// middle becomes one replace.
List<int> _myers(List<String> a, List<String> b) {
  var p = 0, s = 0;
  while (p < a.length && p < b.length && a[p] == b[p]) {
    p++;
  }
  while (s < a.length - p && s < b.length - p && a[a.length - 1 - s] == b[b.length - 1 - s]) {
    s++;
  }
  return [
    ...List.filled(p, 0),
    ..._myersCore(a.sublist(p, a.length - s), b.sublist(p, b.length - s)),
    ...List.filled(s, 0),
  ];
}

const _maxEdits = 1500;

List<int> _myersCore(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  if (n == 0) return List.filled(m, 1);
  if (m == 0) return List.filled(n, -1);
  final max = math.min(n + m, _maxEdits), off = max + 1;
  final v = Int32List(2 * max + 3);
  final trace = <Int32List>[]; // v before step d, index k + d + 1
  var found = -1;
  outer:
  for (var d = 0; d <= max; d++) {
    trace.add(Int32List.sublistView(v, off - d - 1, off + d + 2).sublist(0));
    for (var k = -d; k <= d; k += 2) {
      var x = (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) ? v[off + k + 1] : v[off + k - 1] + 1;
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[off + k] = x;
      if (x >= n && y >= m) {
        found = d;
        break outer;
      }
    }
  }
  if (found < 0) return [...List.filled(n, -1), ...List.filled(m, 1)];
  final ops = <int>[];
  var x = n, y = m;
  for (var d = found; d > 0; d--) {
    final prev = trace[d];
    int at(int k) => prev[k + d + 1];
    final k = x - y;
    final down = k == -d || (k != d && at(k - 1) < at(k + 1));
    final kPrev = down ? k + 1 : k - 1;
    final xPrev = at(kPrev);
    final yPrev = xPrev - kPrev;
    while (x > xPrev && y > yPrev) {
      ops.add(0);
      x--;
      y--;
    }
    ops.add(down ? 1 : -1);
    x = xPrev;
    y = yPrev;
  }
  while (x > 0 && y > 0) {
    ops.add(0);
    x--;
    y--;
  }
  return ops.reversed.toList();
}

final _delBg = Color.index(52), _addBg = Color.index(22);

List<_DiffSeg> _diffRow(String mark, int? aNo, int? bNo, String text, Set<Style> extra, {bool? del}) {
  final gutter = '${(aNo?.toString() ?? '').padLeft(4)} ${(bNo?.toString() ?? '').padLeft(4)} $mark ';
  final fg = del == null
      ? null
      : del
      ? Color.red
      : Color.green;
  final bg = del == null
      ? null
      : del
      ? _delBg
      : _addBg;
  return [
    _DiffSeg(gutter, fg, null, {...extra}),
    _DiffSeg(text, fg, bg, extra),
  ];
}

/// A `-`/`+` pair with changed words brighter.
List<List<_DiffSeg>> _diffPair(String aText, int aNo, String bText, int bNo) {
  final aw = aText.split(' ');
  final bw = bText.split(' ');
  final ops = _myers(aw, bw);
  var ai = 0, bi = 0;
  final aSegs = <_DiffSeg>[];
  final bSegs = <_DiffSeg>[];
  for (final op in ops) {
    if (op == 0) {
      aSegs.add(_DiffSeg('${aw[ai]} ', Color.red, _delBg, const {Style.bold}));
      bSegs.add(_DiffSeg('${bw[bi]} ', Color.green, _addBg, const {Style.bold}));
      ai++;
      bi++;
    } else if (op < 0) {
      aSegs.add(_DiffSeg('${aw[ai]} ', Color.red, _delBg, const {Style.bold, Style.reverse}));
      ai++;
    } else {
      bSegs.add(_DiffSeg('${bw[bi]} ', Color.green, _addBg, const {Style.bold, Style.reverse}));
      bi++;
    }
  }
  List<_DiffSeg> row(String mark, int? aN, int? bN, List<_DiffSeg> segs, Color fg) {
    final gutter = '${(aN?.toString() ?? '').padLeft(4)} ${(bN?.toString() ?? '').padLeft(4)} $mark ';
    return [
      _DiffSeg(gutter, fg, null, const {Style.bold}),
      ...segs,
    ];
  }

  return [row('-', aNo, null, aSegs, Color.red), row('+', null, bNo, bSegs, Color.green)];
}

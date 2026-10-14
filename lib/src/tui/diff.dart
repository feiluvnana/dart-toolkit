// Diff: Myers unified hunks.
part of '../tui.dart';

extension RegionDiff on Region {
    /// A line diff: unified hunks with 3 context lines, gutter line numbers,
    /// `-`/`+` rows on red/green backgrounds, changed words of paired lines
    /// brighter.
    Region diff(String before, String after) {
      for (final line in _diffHunks(before.split('\n'), after.split('\n'))) {
        if (_cursor >= _h) {
          _cursor++;
          continue;
        }
        var col = _gx;
        for (final seg in line) {
          col = _writeLine(_gy + _cursor, col, _gx + _w, seg.text,
              _s._pack(seg.fg, seg.bg, seg.style), null);
        }
        _cursor++;
      }
      return this;
    }
}
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
      if (hunks.isNotEmpty) hunks.add([[_DiffSeg('…', null, null, {})]]);
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
  // Merge blocks separated by <= 6 context lines (3+3).
  final merged = <(int, int, int, int)>[];
  for (final blk in blocks) {
    if (merged.isNotEmpty &&
        blk.$1 - merged.last.$2 <= 6 &&
        blk.$3 - merged.last.$4 <= 6) {
      final last = merged.removeLast();
      merged.add((last.$1, blk.$2, last.$3, blk.$4));
    } else {
      merged.add(blk);
    }
  }
  for (final (a0, a1, b0, b1) in merged) {
    hunk = [];
    final ca0 = math.max(0, a0 - 3);
    final cb0 = math.max(0, b0 - 3);
    // Leading context (show `a` numbering; both sides agree here).
    for (var t = 0; t < a0 - ca0; t++) {
      hunk.add(
          _diffRow(' ', ca0 + t + 1, cb0 + t + 1, a[ca0 + t], const {}));
    }
    // Paired -/+ lines get word-bright pairs.
    var da = a0, db = b0;
    while (da < a1 || db < b1) {
      if (da < a1 && db < b1) {
        hunk.addAll(_diffPair(a[da], da + 1, b[db], db + 1));
        da++;
        db++;
      } else if (da < a1) {
        hunk.add(_diffRow('-', da + 1, null, a[da],
            const {Style.bold}, del: true));
        da++;
      } else {
        hunk.add(_diffRow('+', null, db + 1, b[db],
            const {Style.bold}, del: false));
        db++;
      }
    }
    // Trailing context.
    var t = 0;
    while (t < 3 && a1 + t < a.length && b1 + t < b.length) {
      hunk.add(
          _diffRow(' ', a1 + t + 1, b1 + t + 1, a[a1 + t], const {}));
      t++;
    }
    flush();
  }
  return hunks.expand((h) => h).toList();
}

/// Myers diff as opcodes per consumed line: 0 same, -1 delete, +1 insert.
/// (Compares `a` and `b` line by line.)
List<int> _myers(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  if (n == 0) return List.filled(m, 1);
  if (m == 0) return List.filled(n, -1);
  final max = n + m;
  final v = <int, int>{1: 0};
  final trace = <Map<int, int>>[];
  outer:
  for (var d = 0; d <= max; d++) {
    final cur = <int, int>{};
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && (v[k - 1] ?? -1) < (v[k + 1] ?? -1))) {
        x = v[k + 1] ?? 0;
      } else {
        x = (v[k - 1] ?? 0) + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      cur[k] = x;
      if (x >= n && y >= m) {
        trace.add(cur);
        break outer;
      }
    }
    trace.add(Map.of(cur));
    v
      ..clear()
      ..addAll(cur);
  }
  // Backtrack to opcodes.
  final ops = <int>[];
  var x = n, y = m;
  for (var d = trace.length - 1; d > 0; d--) {
    final prev = trace[d - 1];
    final k = x - y;
    final down =
        (k == -d || (k != d && (prev[k - 1] ?? -1) < (prev[k + 1] ?? -1)));
    final kPrev = down ? k + 1 : k - 1;
    final xPrev = prev[kPrev] ?? (down ? 0 : -1);
    final yPrev = xPrev - kPrev;
    while (x > xPrev && y > yPrev) {
      ops.add(0);
      x--;
      y--;
    }
    if (down) {
      ops.add(1);
      y--;
    } else {
      ops.add(-1);
      x--;
    }
    x = xPrev;
    y = yPrev;
  }
  while (x > 0 && y > 0) {
    ops.add(0);
    x--;
    y--;
  }
  while (x > 0) {
    ops.add(-1);
    x--;
  }
  while (y > 0) {
    ops.add(1);
    y--;
  }
  return ops.reversed.toList();
}

List<_DiffSeg> _diffRow(String mark, int? aNo, int? bNo, String text,
    Set<Style> extra, {bool? del}) {
  final gutter =
      '${(aNo?.toString() ?? '').padLeft(4)} ${(bNo?.toString() ?? '').padLeft(4)} $mark ';
  final fg = del == null
      ? null
      : del
          ? Color.red
          : Color.green;
  final bg = del == null
      ? null
      : del
          ? const Color._(52, null)
          : const Color._(22, null);
  return [
    _DiffSeg(gutter, fg, null, {...extra}),
    _DiffSeg(text, fg, bg, extra),
  ];
}

/// A `-`/`+` pair with changed words brighter.
List<List<_DiffSeg>> _diffPair(
    String aText, int aNo, String bText, int bNo) {
  final aw = aText.split(' ');
  final bw = bText.split(' ');
  final ops = _myers(aw, bw);
  var ai = 0, bi = 0;
  final aSegs = <_DiffSeg>[];
  final bSegs = <_DiffSeg>[];
  for (final op in ops) {
    if (op == 0) {
      aSegs.add(_DiffSeg('${aw[ai]} ', Color.red, const Color._(52, null),
          const {Style.bold}));
      bSegs.add(_DiffSeg('${bw[bi]} ', Color.green, const Color._(22, null),
          const {Style.bold}));
      ai++;
      bi++;
    } else if (op < 0) {
      aSegs.add(_DiffSeg('${aw[ai]} ', Color.red, const Color._(52, null),
          const {Style.bold, Style.reverse}));
      ai++;
    } else {
      bSegs.add(_DiffSeg('${bw[bi]} ', Color.green, const Color._(22, null),
          const {Style.bold, Style.reverse}));
      bi++;
    }
  }
  List<_DiffSeg> row(
      String mark, int? aN, int? bN, List<_DiffSeg> segs, Color fg) {
    final gutter =
        '${(aN?.toString() ?? '').padLeft(4)} ${(bN?.toString() ?? '').padLeft(4)} $mark ';
    return [_DiffSeg(gutter, fg, null, const {Style.bold}), ...segs];
  }

  return [
    row('-', aNo, null, aSegs, Color.red),
    row('+', null, bNo, bSegs, Color.green),
  ];
}

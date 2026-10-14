// Suggest: completion popup for a Field.
part of '../tui.dart';

/// Open suggest-completion state for one [Field].
final class _Suggest {
  _Suggest(this.field);

  final Field field;
  String word = '';
  int wordStart = 0;
  List<String> matches = const [];
  var index = 0;
  var gen = 0;
  var open = false;
}

bool _isWordSuggestChar(int r) =>
    (r >= 0x30 && r <= 0x39) ||
    (r >= 0x41 && r <= 0x5A) ||
    r == 0x5F ||
    (r >= 0x61 && r <= 0x7A) ||
    r == 0x40 ||
    r == 0x2F ||
    r == 0x3A ||
    r == 0x2E ||
    r == 0x2B ||
    r == 0x2D;

extension on _Session<dynamic> {
  /// Refresh the suggest popup for [field] from the word at its cursor.
  void _refreshSuggest(Field field, FutureOr<List<String>> Function(String word)? fn) {
    if (fn == null) return;
    final sg = _suggests.putIfAbsent(field, () => _Suggest(field));
    final runes = field._text.runes.toList();
    final at = field._cursor.clamp(0, runes.length);
    var start = at;
    while (start > 0 && _isWordSuggestChar(runes[start - 1])) {
      start = _prevCluster(runes, start);
    }
    var end = at;
    while (end < runes.length && _isWordSuggestChar(runes[end])) {
      end = _nextCluster(runes, end);
    }
    final word = String.fromCharCodes(runes.sublist(start, end));
    if (word.isEmpty) {
      sg.open = false;
      if (identical(_activeSg, sg)) _activeSg = null;
      _dirtyAndWake();
      return;
    }
    // Same word: nothing new to ask (and an escaped popup stays closed).
    if (word == sg.word && start == sg.wordStart) return;
    sg.word = word;
    sg.wordStart = start;
    final gen = ++sg.gen;
    FutureOr<List<String>> result;
    try {
      result = fn(word);
    } catch (_) {
      if (sg.gen == gen) sg.open = false;
      if (identical(_activeSg, sg) && !sg.open) _activeSg = null;
      _dirtyAndWake();
      return;
    }
    if (result is Future<List<String>>) {
      result.then(
        (matches) {
          if (sg.gen != gen) return; // stale async answer: drop
          sg.matches = matches.length > 10 ? matches.sublist(0, 10) : matches;
          sg.index = 0;
          sg.open = sg.matches.isNotEmpty;
          if (!sg.open && identical(_activeSg, sg)) _activeSg = null;
          _dirtyAndWake();
        },
        onError: (_) {
          if (sg.gen == gen) {
            sg.open = false;
            if (identical(_activeSg, sg)) _activeSg = null;
            _dirtyAndWake();
          }
        },
      );
    } else {
      sg.matches = result.length > 10 ? result.sublist(0, 10) : result;
      sg.index = 0;
      sg.open = sg.matches.isNotEmpty;
      if (!sg.open && identical(_activeSg, sg)) _activeSg = null;
      _dirtyAndWake();
    }
  }

  void _acceptSuggest(_Suggest sg) {
    if (sg.matches.isEmpty) {
      sg.open = false;
      if (identical(_activeSg, sg)) _activeSg = null;
      _dirtyAndWake();
      return;
    }
    final field = sg.field;
    final runes = field._text.runes.toList();
    // Replace [wordStart, cursor) with the match.
    final at = field._cursor.clamp(0, runes.length);
    runes.removeRange(sg.wordStart.clamp(0, at), at);
    final match = sg.matches[sg.index.clamp(0, sg.matches.length - 1)];
    runes.insertAll(sg.wordStart.clamp(0, runes.length), match.runes);
    field._text = String.fromCharCodes(runes);
    field._cursor = sg.wordStart + match.runes.length;
    field._wantCol = -1;
    sg.word = match;
    sg.open = false;
    if (identical(_activeSg, sg)) _activeSg = null;
    _dirtyAndWake();
  }

  /// Route a key to the open suggest popup, if any drawn field has one.
  /// Returns true when consumed.
  bool _routeSuggest(String name) {
    final sg = _activeSg;
    if (sg == null || !sg.open || sg.matches.isEmpty) return false;
    switch (name) {
      case 'up':
        sg.index = (sg.index - 1 + sg.matches.length) % sg.matches.length;
        _dirtyAndWake();
        return true;
      case 'down':
        sg.index = (sg.index + 1) % sg.matches.length;
        _dirtyAndWake();
        return true;
      case 'tab':
      case 'enter':
        _acceptSuggest(sg);
        return true;
      case 'escape':
        sg.open = false;
        _activeSg = null;
        _dirtyAndWake();
        return true;
    }
    return false;
  }

  /// Draw the suggest popup for [field] near its cursor (buffer coords
  /// [cpos] in [region]), if its matches are open.
  void _drawSuggestPopup(Field field, Region region, (int, int)? cpos) {
    final sg = _suggests[field];
    if (sg == null || !sg.open || sg.matches.isEmpty || cpos == null) {
      if (sg != null && identical(_activeSg, sg)) _activeSg = null;
      return;
    }
    final sp = region._toScreen(cpos.$1, cpos.$2);
    if (sp == null) {
      if (identical(_activeSg, sg)) _activeSg = null;
      return;
    }
    _activeSg = sg;
    var mw = 0;
    for (final m in sg.matches) {
      mw = math.max(mw, term.displayWidth(m));
    }
    final w = (mw + 4).clamp(8, math.min<int>(40, _w));
    final h = math.min<int>(sg.matches.length + 2, math.max<int>(3, _h));
    var y = sp.$2 + 1;
    if (y + h > _h) y = sp.$2 - h;
    y = y.clamp(0, math.max<int>(0, _h - h));
    var x = sp.$1.clamp(0, math.max<int>(0, _w - w));
    final buf = <List<_Cell>>[for (var k = 0; k < h; k++) List.filled(w, _Cell.blank)];
    _frame(_caps.ascii, 0, 0, h - 1, w - 1, (r, c, ch) {
      if (r >= 0 && r < h && c >= 0 && c < w) buf[r][c] = _Cell(ch, 0, 1);
    });
    final rows = h - 2;
    var start = sg.index - rows + 1;
    if (start < 0) start = 0;
    for (var r = 0; r < rows && start + r < sg.matches.length; r++) {
      final idx = start + r;
      final sel = idx == sg.index;
      final st = _pack(null, sel ? accent : null, sel ? {Style.bold, if (accent == null) Style.reverse} : {});
      final label = term.truncateWidth(sg.matches[idx], math.max(1, w - 4));
      var col = 2;
      if (sel) {
        for (var c = 1; c < w - 1; c++) {
          buf[r + 1][c] = _Cell(' ', st, 1);
        }
      }
      for (final rune in label.runes) {
        if (col >= w - 1) break;
        if (rune < 0x20 || rune == 0x7f) continue;
        final cw = term.isZeroWidth(rune) ? 0 : term.cellWidth(rune);
        if (cw == 0 || col + cw > w - 1) continue;
        buf[r + 1][col] = _Cell(String.fromCharCode(rune), st, cw);
        if (cw == 2 && col + 1 < w - 1) {
          buf[r + 1][col + 1] = _Cell('', st, 0);
        }
        col += cw;
      }
    }
    _popups.add(_Popup(x, y, w, h, buf, anchored: true));
  }
}

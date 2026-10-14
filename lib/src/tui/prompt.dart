// Prompts: Console ask/confirm/choose shown as modal popups.
part of '../tui.dart';

/// A Console prompt shown as a modal popup.
sealed class _Prompt {
  _Prompt(this.question);

  final String question;

  Completer<Object?> get _done;

  /// Escape or ctrl+c: the caller sees null.
  void cancel() {
    if (!_done.isCompleted) _done.complete(null);
  }
}

/// A prompt with a text field: [_Ask] and [_Confirm].
sealed class _Typed extends _Prompt {
  _Typed(super.question, {this.secret = false});

  final bool secret;
  final Field field = Field();
  String? error;

  String get shown => secret ? '•' * field._text.runes.length : field._text;
}

final class _Ask extends _Typed {
  _Ask(super.question, {super.secret});

  final done = Completer<String?>();
  @override
  Completer<Object?> get _done => done;
}

final class _Confirm extends _Typed {
  _Confirm(super.question, this.or);

  final bool or;
  final done = Completer<bool?>();
  @override
  Completer<Object?> get _done => done;
}

final class _Choose extends _Prompt {
  _Choose(super.question, this.choices, int initial)
    : pick = Pick<int>()
        ..set(List<int>.generate(choices.length, (k) => k))
        ..select(initial);

  final List<String> choices;
  final Pick<int> pick;
  final done = Completer<String?>();
  @override
  Completer<Object?> get _done => done;

  /// First visible choice, rows shown, screen row of the first.
  int start = 0, shown = 0, top = 0;
}

extension on _Session<dynamic> {
  /// Route a key to the topmost Console prompt. Returns true when consumed
  /// (prompts are modal: everything is consumed while one is open).
  bool _promptKey(_Prompt p, String name) {
    switch (p) {
      case _Choose():
        final n = p.choices.length;
        switch (name) {
          case 'up':
          case 'wheelup':
            if (n > 0) p.pick.select(p.pick.index() - 1);
          case 'down':
          case 'wheeldown':
            if (n > 0) p.pick.select(p.pick.index() + 1);
          case 'home':
            p.pick.select(0);
          case 'end':
            p.pick.select(n - 1);
          case 'enter':
            _prompts.remove(p);
            if (!p.done.isCompleted) {
              p.done.complete(n == 0 ? '' : p.choices[p.pick.index().clamp(0, n - 1)]);
            }
          case 'escape' || 'ctrl+c':
            _prompts.remove(p);
            p.cancel();
        }
      case _Typed():
        switch (name) {
          case 'backspace':
            _promptDrop(p, -1);
          case 'delete':
            _promptDrop(p, 1);
          case 'left':
            p.field._cursor = _prevCluster(p.field._text.runes.toList(), p.field._cursor);
          case 'right':
            p.field._cursor = _nextCluster(p.field._text.runes.toList(), p.field._cursor);
          case 'home' || 'ctrl+a':
            p.field._cursor = 0;
          case 'end' || 'ctrl+e':
            p.field._cursor = p.field._text.runes.length;
          case 'ctrl+u' || 'ctrl+k' || 'ctrl+w' || 'alt+backspace':
            p.field.set('');
          case 'enter':
            _submitPrompt(p);
          case 'escape' || 'ctrl+c':
            _prompts.remove(p);
            p.cancel();
        }
    }
    _dirtyAndWake();
    return true; // modal: swallow the rest
  }

  void _promptDrop(_Typed p, int dir) {
    final runes = p.field._text.runes.toList();
    final at = p.field._cursor.clamp(0, runes.length);
    if (dir < 0) {
      final start = _prevCluster(runes, at);
      runes.removeRange(start, at);
      p.field._cursor = start;
    } else {
      final end = _nextCluster(runes, at);
      runes.removeRange(at, end);
    }
    p.field._text = String.fromCharCodes(runes);
  }

  void _promptText(_Typed p, String text, bool paste) {
    final clean = paste
        ? text.replaceAll('\r\n', ' ').replaceAll(RegExp('[\r\n\t]'), ' ').replaceAll(RegExp('[\x00-\x1f\x7f]'), '')
        : text;
    final runes = p.field._text.runes.toList();
    final at = p.field._cursor.clamp(0, runes.length);
    runes.insertAll(at, clean.runes);
    p.field._text = String.fromCharCodes(runes);
    p.field._cursor = at + clean.runes.length;
    _dirtyAndWake();
  }

  void _submitPrompt(_Typed p) {
    switch (p) {
      case _Confirm():
        final answer = p.field.text().trim().toLowerCase();
        if (answer == 'y' || answer == 'yes') {
          _prompts.remove(p);
          if (!p.done.isCompleted) p.done.complete(true);
        } else if (answer == 'n' || answer == 'no') {
          _prompts.remove(p);
          if (!p.done.isCompleted) p.done.complete(false);
        } else if (answer.isEmpty) {
          _prompts.remove(p);
          if (!p.done.isCompleted) p.done.complete(p.or);
        } else {
          p.error = 'please answer y or n';
        }
      case _Ask():
        _prompts.remove(p);
        if (!p.done.isCompleted) p.done.complete(p.field.text());
    }
  }

  /// Route typed text to the topmost prompt (ask/confirm only).
  void _promptRouteText(String text, bool paste) {
    if (_prompts.isEmpty) return;
    final p = _prompts.last;
    if (p is _Typed) _promptText(p, text, paste);
  }

  /// Route a mouse event to the topmost prompt. Always consumes (modal).
  bool _promptMouse(String kind, int x, int y) {
    if (_prompts.isEmpty) return false;
    final p = _prompts.last;
    if (p is _Choose && (kind == 'click' || kind == 'doubleclick')) {
      // Click a row to select it.
      final row = y - p.top;
      if (row >= 0 && row < p.shown) {
        p.pick.select(p.start + row);
        if (kind == 'doubleclick') {
          _prompts.remove(p);
          if (!p.done.isCompleted) p.done.complete(p.choices[p.pick.index()]);
        }
        _dirtyAndWake();
      }
    }
    return true;
  }

  void _drawPrompt() {
    if (_prompts.isEmpty) return;
    final p = _prompts.last;
    final lines = <(String, int)>[]; // (text, style)
    void wrapped(String text, int style, {int indent = 0}) {
      final maxW = math.max(8, _w - 8);
      var rest = text;
      var first = true;
      while (rest.isNotEmpty) {
        final lead = first ? indent : indent + 2;
        var used = lead;
        var k = 0;
        for (final r in rest.runes) {
          final w = term.isZeroWidth(r) ? 0 : term.cellWidth(r);
          if (used + w > maxW) break;
          used += w;
          k++;
        }
        if (k == 0) break;
        final runes = rest.runes.toList();
        lines.add(('${first ? '' : '  '}${String.fromCharCodes(runes.sublist(0, k))}', style));
        rest = String.fromCharCodes(runes.sublist(k)).trimLeft();
        first = false;
      }
    }

    var fieldRow = -1;
    if (p is _Choose) {
      wrapped(p.question, _pack(null, null, {Style.bold}));
      lines.add(('', 0));
      // Window the choices to the popup height, keeping the selection in view.
      final head = lines.length;
      final n = p.choices.length;
      p.shown = math.min(n, math.max(1, math.max(5, _h - 2) - 4 - head));
      final sel = p.pick.index();
      if (sel < p.start) p.start = sel;
      if (sel >= p.start + p.shown) p.start = sel - p.shown + 1;
      p.start = p.start.clamp(0, n - p.shown);
      for (var k = p.start; k < p.start + p.shown; k++) {
        lines.add(('${k == sel ? '❯ ' : '  '}${p.choices[k]}', 0));
      }
      p.top = head; // made absolute once the popup is placed
    } else if (p is _Typed) {
      wrapped(p.question, _pack(null, null, {Style.bold}));
      lines.add(('', 0));
      fieldRow = lines.length;
      lines.add(('❯ ${p.shown}', 0));
      if (p.error != null) {
        lines.add(('  ${p.error}', _pack(accent == null ? null : Color.red, null,
            accent == null ? {Style.bold} : {})));
      }
    }
    final contentW = lines.fold<int>(0, (m, l) => math.max(m, term.displayWidth(l.$1)));
    final w = (contentW + 6).clamp(20, math.max<int>(20, _w - 2));
    final h = (lines.length + 4).clamp(5, math.max<int>(5, _h - 2));
    final x = ((_w - w) ~/ 2).clamp(0, math.max<int>(0, _w - w));
    final y = ((_h - h) ~/ 2).clamp(0, math.max<int>(0, _h - h));
    final buf = <List<_Cell>>[for (var k = 0; k < h; k++) List.filled(w, _Cell.blank)];
    _frame(_caps.ascii, 0, 0, h - 1, w - 1, (r, c, ch) {
      if (r >= 0 && r < h && c >= 0 && c < w) buf[r][c] = _Cell(ch, 0, 1);
    });
    for (var r = 0; r < lines.length && r + 2 < h - 1; r++) {
      final (text, st) = lines[r];
      var col = 3;
      for (final rune in text.runes) {
        if (col >= w - 2) break;
        if (rune < 0x20 || rune == 0x7f) continue;
        final cw = term.isZeroWidth(rune) ? 0 : term.cellWidth(rune);
        if (cw == 0 || col + cw > w - 2) continue;
        buf[r + 2][col] = _Cell(String.fromCharCode(rune), st, cw);
        if (cw == 2 && col + 1 < w - 2) {
          buf[r + 2][col + 1] = _Cell('', st, 0);
        }
        col += cw;
      }
    }
    _popups.add(_Popup(x, y, w, h, buf));
    if (p is _Choose) p.top += y + 2;
    if (p is _Typed && fieldRow >= 0) {
      // Hardware cursor at the end of the field text.
      var col = x + 3 + 2 + term.displayWidth(p.shown);
      col = math.min(col, x + w - 2);
      _cursorPos = (y + 2 + fieldRow, col);
    }
  }
}

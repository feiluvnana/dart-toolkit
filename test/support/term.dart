import 'package:dart_toolkit/src/terminal.dart' as term;
import 'package:test/test.dart';

/// A tiny VT100 for assertions: CUP, SGR, `?` modes, chars with widths
/// from the same table as the engine unless [wide] says otherwise.
final class Term {
  Term(this.w, this.h, {this.wide = const {}}) : _cells = _blank(w, h);

  int w;
  int h;
  final Set<String> wide;
  List<List<(String, Set<String>)>> _cells;
  var _x = 0;
  var _y = 0;
  var _style = <String>{};

  static List<List<(String, Set<String>)>> _blank(int w, int h) =>
      List.generate(h, (_) => List.filled(w, (' ', const <String>{})));

  void resize(int nw, int nh) {
    w = nw;
    h = nh;
    _cells = _blank(w, h);
    _x = _y = 0;
  }

  String row(int y) => _cells[y].map((c) => c.$1).join();
  List<String> cells(int y) => _cells[y].map((c) => c.$1).toList();
  Set<String> styleAt(int x, int y) => _cells[y][x].$2;

  void feed(String s) {
    final runes = s.runes.toList();
    var i = 0;
    while (i < runes.length) {
      final r = runes[i];
      if (r == 0x1b && i + 1 < runes.length && runes[i + 1] == 0x5b) {
        var j = i + 2;
        while (j < runes.length && (runes[j] < 0x40 || runes[j] > 0x7e)) {
          j++;
        }
        final params = String.fromCharCodes(runes.sublist(i + 2, j));
        final fin = String.fromCharCode(runes[j]);
        if (fin == 'H' && !params.startsWith('?')) {
          final p = params.isEmpty ? ['1', '1'] : params.split(';');
          _y = int.parse(p[0]) - 1;
          _x = int.parse(p[1]) - 1;
        } else if (fin == 'm') {
          final codes = params.split(';').map(int.tryParse).toList();
          for (var k = 0; k < codes.length; k++) {
            final code = codes[k];
            if (code == null || code == 0) _style = {};
            if (code == 1) _style = {..._style, 'bold'};
            if (code == 7) _style = {..._style, 'inverse'};
            if (code == 38 && k + 2 < codes.length) {
              _style = {..._style, 'fg${codes[k + 2]}'};
              k += 2;
            }
          }
        } else if (fin == 'J') {
          _cells = _blank(w, h);
        }
        i = j + 1;
        continue;
      }
      i++;
      if (r < 0x20) {
        fail('raw control ${r.toRadixString(16)} reached the terminal');
      }
      final ch = String.fromCharCode(r);
      if (term.isZeroWidth(r)) {
        final px = (_x - 1).clamp(0, w - 1);
        _cells[_y][px] = ('${_cells[_y][px].$1}$ch', _cells[_y][px].$2);
        continue;
      }
      final cw = wide.contains(ch) ? 2 : term.cellWidth(r);
      if (_y < 0 || _y >= h) continue;
      final x = _x.clamp(0, w - 1);
      _cells[_y][x] = (ch, _style);
      if (cw == 2 && x + 1 < w) _cells[_y][x + 1] = ('', _style);
      // Autowrap is off: the cursor sticks at the last column.
      _x = x + cw >= w ? w - 1 : x + cw;
    }
  }
}

/// An in-house YAML 1.2 reader: the first document of a text as plain Dart
/// values (string-keyed maps, lists, scalars by the core schema). Block and
/// flow collections, plain/quoted/block scalars, anchors and aliases (shared,
/// not copied), tags on scalars (`!!str`, `!!int`, …), directives and
/// multi-document streams. Read only. Private to the toolkit.
library;

/// A YAML syntax error at [offset] (into the text as given).
final class YamlError implements Exception {
  YamlError(this.message, this.offset);

  final String message;
  final int offset;

  @override
  String toString() => 'YamlError: $message (offset $offset)';
}

/// The first document of [text] (null when it holds none).
Object? parseYaml(String text) => _Parser(text).document();

const _maxDepth = 1000;

final class _Parser {
  _Parser(String text)
    : _crlf = text.contains('\r'),
      s = text.contains('\r') ? text.replaceAll('\r\n', '\n').replaceAll('\r', '\n') : text,
      _original = text;

  final String s;
  final String _original;
  final bool _crlf;
  var i = 0;
  var _depth = 0;
  final _anchors = <String, Object?>{};

  int get n => s.length;

  YamlError _error(String message, [int? at]) {
    var offset = at ?? i;
    if (_crlf) {
      // Map back through the CRLF normalization: count lines, find the
      // same line and column in the original.
      final line = '\n'.allMatches(s.substring(0, offset.clamp(0, n))).length;
      final col = offset <= 0 ? 0 : offset - (s.lastIndexOf('\n', offset - 1) + 1);
      var start = 0;
      for (var k = 0; k < line; k++) {
        final nl = _original.indexOf(RegExp('\r\n|\r|\n'), start);
        if (nl < 0) break;
        start = nl + (_original.startsWith('\r\n', nl) ? 2 : 1);
      }
      offset = start + col;
    }
    return YamlError(message, offset);
  }

  int _c(int at) => at < n ? s.codeUnitAt(at) : -1;

  static bool _ws(int c) => c == 0x20 || c == 0x09;

  /// Whitespace, a line end or the end of input.
  bool _blankAt(int at) => at >= n || _ws(s.codeUnitAt(at)) || s.codeUnitAt(at) == 0x0A;

  int _col(int at) => at == 0 ? 0 : at - (s.lastIndexOf('\n', at - 1) + 1);

  void _enter() {
    if (++_depth > _maxDepth) throw _error('nested too deep');
  }

  void _skipSpaces() {
    while (i < n && _ws(s.codeUnitAt(i))) {
      i++;
    }
  }

  /// A `---` or `...` marker at [at] (which must start a line).
  bool _marker(int at) {
    if (at + 3 > n || _col(at) != 0) return false;
    final m = s.substring(at, at + 3);
    return (m == '---' || m == '...') && _blankAt(at + 3);
  }

  /// Rest of the line after a node: spaces, then a comment or the line end.
  void _lineEnd() {
    _skipSpaces();
    if (i < n && s.codeUnitAt(i) == 0x23) {
      while (i < n && s.codeUnitAt(i) != 0x0A) {
        i++;
      }
    }
    if (i < n && s.codeUnitAt(i) != 0x0A) throw _error('unexpected "${s[i]}"');
  }

  /// The next content character from [i] (at a line end): blank and comment
  /// lines skipped. Does not move [i]. A tab in the indentation is an error.
  int _peek() {
    var p = i;
    while (p < n) {
      final lineStart = p == 0 || s.codeUnitAt(p - 1) == 0x0A;
      var tab = -1;
      while (p < n && _ws(s.codeUnitAt(p))) {
        if (s.codeUnitAt(p) == 0x09 && lineStart && tab < 0) tab = p;
        p++;
      }
      if (p < n && s.codeUnitAt(p) == 0x23) {
        while (p < n && s.codeUnitAt(p) != 0x0A) {
          p++;
        }
      }
      if (p < n && s.codeUnitAt(p) == 0x0A) {
        p++;
        continue;
      }
      if (p < n && tab >= 0 && lineStart) throw _error('a tab is not allowed as indentation', tab);
      return p;
    }
    return p;
  }

  // -- documents ------------------------------------------------------------

  Object? document() {
    if (s.startsWith('﻿')) i = 1;
    while (true) {
      final p = _peek();
      if (p < n && s.codeUnitAt(p) == 0x25 && _col(p) == 0) {
        // %YAML / %TAG directive: skip the line.
        i = s.indexOf('\n', p);
        if (i < 0) i = n;
        continue;
      }
      i = p;
      break;
    }
    if (i >= n) return null;
    if (_marker(i) && s.startsWith('...', i)) return null;
    if (_marker(i)) i += 3;
    final value = _value(-1, seqAtParent: false, mapOk: true);
    _lineEnd();
    final p = _peek();
    if (p < n && !_marker(p)) throw _error('unexpected content after the document', p);
    return value;
  }

  // -- block structure --------------------------------------------------------

  /// A node owned by a parent at [indent]: inline after the current
  /// position, or on the following lines when the line holds nothing more.
  /// [seqAtParent]: a block sequence may sit at [indent] itself (a mapping
  /// value); [mapOk]: an inline implicit mapping may start here.
  Object? _value(int indent, {required bool seqAtParent, required bool mapOk}) {
    _skipSpaces();
    if (i >= n || s.codeUnitAt(i) == 0x0A || s.codeUnitAt(i) == 0x23) {
      final p = _peek();
      if (p >= n || _marker(p)) return null;
      final c = _col(p);
      if (c > indent || (seqAtParent && c == indent && _dash(p))) {
        i = p;
        return _node(indent, seqAtParent: seqAtParent, mapOk: true);
      }
      return null;
    }
    return _node(indent, seqAtParent: seqAtParent, mapOk: mapOk);
  }

  bool _dash(int at) => _c(at) == 0x2D && _blankAt(at + 1);

  /// The node starting at [i] (a content character).
  Object? _node(int indent, {required bool seqAtParent, required bool mapOk}) {
    final col = _col(i);
    final (anchor, tag) = _props();
    if (anchor != null || tag != null) {
      _skipSpaces();
      if (i >= n || s.codeUnitAt(i) == 0x0A || s.codeUnitAt(i) == 0x23) {
        final v = _value(indent, seqAtParent: seqAtParent, mapOk: true);
        return _register(anchor, v ?? _empty(tag));
      }
    }
    final c = s.codeUnitAt(i);
    if (c == 0x2D && _blankAt(i + 1)) {
      if (!mapOk) throw _error('a sequence entry is not allowed here');
      return _register(anchor, _sequence(_col(i)));
    }
    if (c == 0x3F && _blankAt(i + 1)) {
      if (!mapOk) throw _error('a mapping is not allowed here');
      return _register(anchor, _mapping(_col(i), null));
    }
    if (c == 0x7C || c == 0x3E) return _register(anchor, _scalar(_blockScalar(indent), plain: false, tag: tag));
    final key = _candidate(flow: false);
    _skipSpaces();
    if (_isValueColon(key)) {
      if (!mapOk) throw _error('a mapping value is not allowed here');
      if (key.multiline) throw _error('an implicit key must be on one line', key.start);
      return _mapping(col, (key: _register(anchor, _finish(key, tag)), start: key.start));
    }
    return _register(anchor, _finish(key, tag, key.plain ? _continuePlain(key.text!, indent) : null));
  }

  Object? _register(String? anchor, Object? v) {
    if (anchor != null) _anchors[anchor] = v;
    return v;
  }

  /// Whether [i] is the `:` after an implicit key.
  bool _isValueColon(_Candidate key) {
    if (_c(i) != 0x3A) return false;
    // A JSON-like key (quoted, flow) may be followed directly by its value.
    return _blankAt(i + 1) || key.quoted || key.flow;
  }

  /// A block sequence whose dashes sit at column [indent].
  List<Object?> _sequence(int indent) {
    _enter();
    final out = <Object?>[];
    while (true) {
      i++; // the dash
      out.add(_value(indent, seqAtParent: false, mapOk: true));
      _lineEnd();
      final p = _peek();
      if (p >= n || _marker(p)) break;
      final c = _col(p);
      if (c < indent) break;
      if (c > indent) throw _error('bad indentation of a sequence entry', p);
      if (!_dash(p)) break;
      i = p;
    }
    _depth--;
    return out;
  }

  /// A block mapping whose keys sit at column [indent]; [first] is a key
  /// already read (with [i] at its `:`), or null at a `?` explicit key.
  Map<String, Object?> _mapping(int indent, ({Object? key, int start})? first) {
    _enter();
    final out = <String, Object?>{};
    var pending = first;
    while (true) {
      final Object? key;
      final int keyStart;
      Object? value;
      if (pending == null) {
        keyStart = i;
        if (_c(i) == 0x3F && _blankAt(i + 1)) {
          // `? key` then an optional `: value` at the same indentation.
          i++;
          key = _value(indent, seqAtParent: false, mapOk: true);
          _lineEnd();
          final p = _peek();
          if (p < n && !_marker(p) && _col(p) == indent && _c(p) == 0x3A && _blankAt(p + 1)) {
            i = p + 1;
            value = _value(indent, seqAtParent: true, mapOk: true);
            _lineEnd();
          }
          _put(out, key, value, keyStart);
          if (!_nextEntry(indent)) break;
          continue;
        }
        final (anchor, tag) = _props();
        _skipSpaces();
        final k = _candidate(flow: false);
        _skipSpaces();
        if (!_isValueColon(k)) throw _error('expected ":" after a mapping key', i);
        if (k.multiline) throw _error('an implicit key must be on one line', k.start);
        key = _register(anchor, _finish(k, tag));
      } else {
        key = pending.key;
        keyStart = pending.start;
        pending = null;
      }
      i++; // the colon
      value = _value(indent, seqAtParent: true, mapOk: false);
      _lineEnd();
      _put(out, key, value, keyStart);
      if (!_nextEntry(indent)) break;
    }
    _depth--;
    return out;
  }

  /// Move to the next entry at [indent]; false when the collection ends.
  bool _nextEntry(int indent) {
    final p = _peek();
    if (p >= n || _marker(p)) return false;
    final c = _col(p);
    if (c < indent) return false;
    if (c > indent) throw _error('bad indentation of a mapping entry', p);
    i = p;
    return true;
  }

  void _put(Map<String, Object?> map, Object? key, Object? value, int at) {
    final k = _keyText(key);
    if (map.containsKey(k)) throw _error('duplicate mapping key "$k"', at);
    map[k] = value;
  }

  /// A key as text: strings as they are, scalars as Dart prints them,
  /// collections as JSON-like text.
  static String _keyText(Object? key) => switch (key) {
    final String k => k,
    null => 'null',
    final Map<Object?, Object?> m => '{${m.entries.map((e) => '${_keyText(e.key)}: ${_keyText(e.value)}').join(', ')}}',
    final List<Object?> l => '[${l.map(_keyText).join(', ')}]',
    _ => '$key',
  };

  // -- properties -------------------------------------------------------------

  /// `&anchor` and `!tag` in either order, each at most once.
  (String?, String?) _props() {
    String? anchor, tag;
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (c == 0x26 && anchor == null) {
        anchor = _name(i + 1, 'anchor');
      } else if (c == 0x21 && tag == null) {
        final start = i;
        if (_c(i + 1) == 0x3C) {
          final end = s.indexOf('>', i);
          if (end < 0) throw _error('unterminated verbatim tag');
          tag = s.substring(i + 2, end);
          i = end + 1;
        } else {
          while (i < n && !_blankAt(i) && !_flowIndicator(s.codeUnitAt(i))) {
            i++;
          }
          tag = s.substring(start, i);
        }
      } else {
        break;
      }
      _skipSpaces();
    }
    return (anchor, tag);
  }

  /// An anchor or alias name from [from]; moves [i] past it.
  String _name(int from, String what) {
    var p = from;
    while (p < n && !_blankAt(p) && !_flowIndicator(s.codeUnitAt(p))) {
      p++;
    }
    if (p == from) throw _error('expected an $what name', from);
    i = p;
    return s.substring(from, p);
  }

  static bool _flowIndicator(int c) => c == 0x2C || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D;

  /// A scalar's [text] under [tag]: core tags convert it (`!!str 123` is
  /// `'123'`, `!!int "7"` is 7), `!` and quotes keep it a string, a plain
  /// scalar otherwise resolves by the core schema.
  Object? _scalar(String text, {required bool plain, String? tag}) {
    switch (tag) {
      case null:
        return plain ? _resolve(text) : text;
      case '!' || '!!str' || 'tag:yaml.org,2002:str':
        return text;
      case '!!null' || 'tag:yaml.org,2002:null':
        return null;
      case '!!int' || 'tag:yaml.org,2002:int':
        final r = _resolve(text);
        if (r is int) return r;
        throw _error('"$text" is not an !!int');
      case '!!float' || 'tag:yaml.org,2002:float':
        final r = _resolve(text);
        if (r is num) return r.toDouble();
        throw _error('"$text" is not a !!float');
      case '!!bool' || 'tag:yaml.org,2002:bool':
        final r = _resolve(text);
        if (r is bool) return r;
        throw _error('"$text" is not a !!bool');
      default:
        return plain ? _resolve(text) : text;
    }
  }

  /// What [c] stands for under [tag]; [text] is a plain scalar's full text
  /// when it continued past its first line.
  Object? _finish(_Candidate c, String? tag, [String? text]) {
    if (c.plain) return _scalar(text ?? c.text!, plain: true, tag: tag);
    if (c.quoted) return _scalar(c.value! as String, plain: false, tag: tag);
    return c.value;
  }

  /// An empty node: null, or `''` under `!!str`/`!`.
  Object? _empty(String? tag) => tag == null ? null : _scalar('', plain: true, tag: tag);

  // -- scalars and flow nodes on one line --------------------------------------

  /// An alias, quoted scalar, flow collection or the first line of a plain
  /// scalar at [i]: the shapes an implicit key can take.
  _Candidate _candidate({required bool flow}) {
    final start = i;
    final c = _c(i);
    if (c == 0x2A) {
      final name = _name(i + 1, 'alias');
      if (!_anchors.containsKey(name)) throw _error('undefined alias "*$name"', start);
      return _Candidate(start, _anchors[name], flow: true);
    }
    if (c == 0x22 || c == 0x27) {
      final line = _lineOf(i);
      final v = c == 0x22 ? _double() : _single();
      return _Candidate(start, v, quoted: true, multiline: _lineOf(i) != line);
    }
    if (c == 0x5B || c == 0x7B) {
      final line = _lineOf(i);
      final v = _flowCollection();
      return _Candidate(start, v, flow: true, multiline: _lineOf(i) != line);
    }
    if (!_plainStart(i, flow: flow)) {
      throw _error(c < 0 ? 'unexpected end of input' : 'unexpected "${s[i]}"');
    }
    return _Candidate(start, null, plain: true, text: _plainLine(flow: flow));
  }

  int _lineOf(int at) => at == 0 ? -1 : s.lastIndexOf('\n', at - 1);

  bool _plainStart(int at, {required bool flow}) {
    final c = _c(at);
    if (c < 0 || c == 0x0A || _ws(c)) return false;
    switch (c) {
      case 0x2D || 0x3F || 0x3A: // - ? :
        final next = _c(at + 1);
        return !_blankAt(at + 1) && !(flow && _flowIndicator(next));
      case 0x2C || 0x5B || 0x5D || 0x7B || 0x7D || 0x23 || 0x26 || 0x2A || 0x21 || 0x7C || 0x3E || 0x27 || 0x22:
      case 0x25 || 0x40 || 0x60:
        return false;
    }
    return true;
  }

  /// One line of a plain scalar; [i] ends after its last non-space.
  String _plainLine({required bool flow}) {
    final start = i;
    var end = i;
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (c == 0x0A) break;
      if (c == 0x3A) {
        final next = _c(i + 1);
        if (_blankAt(i + 1) || (flow && _flowIndicator(next))) break;
      }
      if (c == 0x23 && i > start && _ws(s.codeUnitAt(i - 1))) break;
      if (flow && _flowIndicator(c)) break;
      i++;
      if (!_ws(c)) end = i;
    }
    i = end;
    return s.substring(start, end);
  }

  /// The rest of a multi-line plain scalar after its first line [first]:
  /// continuation lines indented past [indent], folded (a line break is a
  /// space, each blank line a newline).
  String _continuePlain(String first, int indent) {
    final text = StringBuffer(first);
    while (true) {
      final save = i;
      _skipSpaces();
      if (i >= n || s.codeUnitAt(i) != 0x0A) {
        i = save;
        break;
      }
      var breaks = 0;
      var p = i;
      while (p < n && s.codeUnitAt(p) == 0x0A) {
        breaks++;
        p++;
        while (p < n && _ws(s.codeUnitAt(p))) {
          p++;
        }
      }
      if (p >= n || s.codeUnitAt(p) == 0x23 || _col(p) <= indent || _marker(p)) {
        i = save;
        break;
      }
      i = p;
      if (!_plainContinues(p)) {
        i = save;
        break;
      }
      final line = _plainLine(flow: false);
      if (line.isEmpty) {
        i = save;
        break;
      }
      text
        ..write(breaks == 1 ? ' ' : '\n' * (breaks - 1))
        ..write(line);
    }
    return text.toString();
  }

  /// A continuation line may start with anything but a `: ` or a comment.
  bool _plainContinues(int at) => !(_c(at) == 0x3A && _blankAt(at + 1));

  /// A `"…"` scalar with escapes and line folding; [i] ends after it.
  String _double() {
    final start = i;
    i++;
    final out = StringBuffer();
    var ws = StringBuffer();
    while (true) {
      if (i >= n) throw _error('unterminated double-quoted string', start);
      final c = s.codeUnitAt(i);
      if (c == 0x22) {
        out.write(ws);
        i++;
        return out.toString();
      }
      if (c == 0x5C) {
        out.write(ws);
        ws = StringBuffer();
        i++;
        if (i >= n) throw _error('unterminated double-quoted string', start);
        final e = s.codeUnitAt(i);
        if (e == 0x0A) {
          // An escaped line break joins the lines without a space.
          i++;
          _skipSpacesAndBreaks();
          continue;
        }
        out.write(_escape(e));
        continue;
      }
      if (_ws(c)) {
        ws.writeCharCode(c);
        i++;
        continue;
      }
      if (c == 0x0A) {
        ws = StringBuffer();
        _fold(out);
        continue;
      }
      out
        ..write(ws)
        ..writeCharCode(c);
      ws = StringBuffer();
      i++;
    }
  }

  /// A `'…'` scalar (`''` is a quote) with line folding.
  String _single() {
    final start = i;
    i++;
    final out = StringBuffer();
    var ws = StringBuffer();
    while (true) {
      if (i >= n) throw _error('unterminated single-quoted string', start);
      final c = s.codeUnitAt(i);
      if (c == 0x27) {
        if (_c(i + 1) == 0x27) {
          out
            ..write(ws)
            ..write("'");
          ws = StringBuffer();
          i += 2;
          continue;
        }
        out.write(ws);
        i++;
        return out.toString();
      }
      if (_ws(c)) {
        ws.writeCharCode(c);
        i++;
        continue;
      }
      if (c == 0x0A) {
        ws = StringBuffer();
        _fold(out);
        continue;
      }
      out
        ..write(ws)
        ..writeCharCode(c);
      ws = StringBuffer();
      i++;
    }
  }

  /// At a line break inside a quoted scalar: one break folds to a space,
  /// each further (blank) line is a newline; leading spaces go.
  void _fold(StringBuffer out) {
    var breaks = 0;
    while (i < n && s.codeUnitAt(i) == 0x0A) {
      breaks++;
      i++;
      _skipSpaces();
    }
    if (i < n && _marker(i)) throw _error('a document marker inside a quoted string');
    out.write(breaks == 1 ? ' ' : '\n' * (breaks - 1));
  }

  void _skipSpacesAndBreaks() {
    while (i < n && (_ws(s.codeUnitAt(i)) || s.codeUnitAt(i) == 0x0A)) {
      i++;
    }
  }

  /// The character after a `\` (at [i]); moves past the escape.
  String _escape(int e) {
    i++;
    switch (e) {
      case 0x30:
        return '\x00';
      case 0x61:
        return '\x07';
      case 0x62:
        return '\b';
      case 0x74 || 0x09:
        return '\t';
      case 0x6E:
        return '\n';
      case 0x76:
        return '\v';
      case 0x66:
        return '\f';
      case 0x72:
        return '\r';
      case 0x65:
        return '\x1B';
      case 0x20:
        return ' ';
      case 0x22:
        return '"';
      case 0x2F:
        return '/';
      case 0x5C:
        return r'\';
      case 0x4E:
        return '\u0085';
      case 0x5F:
        return ' ';
      case 0x4C:
        return ' ';
      case 0x50:
        return ' ';
      case 0x78:
        return _hex(2);
      case 0x75:
        return _hex(4);
      case 0x55:
        return _hex(8);
    }
    throw _error('unknown escape "\\${String.fromCharCode(e)}"', i - 2);
  }

  String _hex(int digits) {
    final code = _digits(digits);
    if (code >= 0xDC00 && code <= 0xDFFF) throw _error('an unpaired surrogate escape', i - digits);
    if (code >= 0xD800 && code <= 0xDBFF) {
      // A JSON-style pair: `\\ud83d\\ude00`.
      if (!s.startsWith(r'\u', i)) throw _error('an unpaired surrogate escape', i - digits);
      i += 2;
      final low = _digits(4);
      if (low < 0xDC00 || low > 0xDFFF) throw _error('an unpaired surrogate escape', i - 4);
      return String.fromCharCode(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00));
    }
    return String.fromCharCode(code);
  }

  /// [digits] hex digits at [i] (exactly: no sign, no space), as a code point.
  int _digits(int digits) {
    if (i + digits > n) throw _error('a short \\x/\\u escape');
    var code = 0;
    for (var k = 0; k < digits; k++) {
      final c = s.codeUnitAt(i + k), lower = c | 0x20;
      final v = c >= 0x30 && c <= 0x39 ? c - 0x30 : (lower >= 0x61 && lower <= 0x66 ? lower - 0x57 : -1);
      if (v < 0) throw _error('a bad \\x/\\u escape', i);
      code = code << 4 | v;
    }
    if (code > 0x10FFFF) throw _error('a bad \\x/\\u escape', i);
    i += digits;
    return code;
  }

  // -- block scalars ------------------------------------------------------------

  /// A `|` (literal) or `>` (folded) scalar under a parent at [indent];
  /// [i] ends at the line break after its last line.
  String _blockScalar(int indent) {
    final folded = s.codeUnitAt(i) == 0x3E;
    i++;
    int? explicit;
    var chomp = 0; // -1 strip, 0 clip, 1 keep
    for (var k = 0; k < 2 && i < n; k++) {
      final c = s.codeUnitAt(i);
      if (c == 0x2D || c == 0x2B) {
        chomp = c == 0x2D ? -1 : 1;
        i++;
      } else if (c >= 0x31 && c <= 0x39) {
        explicit = c - 0x30;
        i++;
      }
    }
    _lineEnd();
    // Lines: the content indentation is the explicit one or the first
    // non-blank line's.
    final base = indent < 0 ? 0 : indent;
    var contentIndent = explicit == null ? -1 : base + explicit;
    // Content lines with the indentation removed; a blank line is `''`
    // (spaces past the indentation are content).
    final lines = <String>[];
    var last = i; // the line break ending the last line taken
    var p = i < n ? i + 1 : n;
    while (p < n && !_marker(p)) {
      final eol = s.indexOf('\n', p);
      final end = eol < 0 ? n : eol;
      final line = s.substring(p, end);
      var spaces = 0;
      while (spaces < line.length && line.codeUnitAt(spaces) == 0x20) {
        spaces++;
      }
      final blank = line.trim().isEmpty;
      if (!blank) {
        if (contentIndent < 0) {
          if (spaces <= indent) break;
          contentIndent = spaces;
        }
        if (spaces < contentIndent) break;
      }
      lines.add(
        contentIndent >= 0 && line.length > contentIndent ? line.substring(contentIndent) : (blank ? '' : line),
      );
      last = end;
      if (eol < 0) break;
      p = eol + 1;
    }
    i = last;
    // Trailing blank lines belong to the chomping, not the content.
    var keep = lines.length;
    while (keep > 0 && lines[keep - 1].isEmpty) {
      keep--;
    }
    final trailing = lines.length - keep;
    final body = lines.sublist(0, keep);
    final out = StringBuffer();
    if (folded) {
      var first = true, prevMore = false, empties = 0;
      for (final line in body) {
        if (line.isEmpty) {
          empties++;
          continue;
        }
        final more = line.startsWith(' ') || line.startsWith('\t');
        if (first) {
          out.write('\n' * empties);
        } else if (more || prevMore) {
          out.write('\n' * (empties + 1));
        } else {
          out.write(empties == 0 ? ' ' : '\n' * empties);
        }
        out.write(line);
        first = false;
        prevMore = more;
        empties = 0;
      }
    } else {
      out.writeAll(body, '\n');
    }
    final hasContent = body.isNotEmpty;
    switch (chomp) {
      case -1:
        break;
      case 0:
        if (hasContent) out.write('\n');
      default:
        if (hasContent) out.write('\n');
        out.write('\n' * trailing);
    }
    return out.toString();
  }

  // -- flow collections -------------------------------------------------------

  /// Spaces, line breaks and comments inside a flow collection.
  void _flowSpace() {
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (_ws(c) || c == 0x0A) {
        i++;
      } else if (c == 0x23 && (i == 0 || _blankAt(i - 1))) {
        while (i < n && s.codeUnitAt(i) != 0x0A) {
          i++;
        }
      } else {
        return;
      }
    }
  }

  Object? _flowCollection() {
    _enter();
    final start = i;
    final seq = s.codeUnitAt(i) == 0x5B;
    final close = seq ? 0x5D : 0x7D;
    i++;
    final list = <Object?>[];
    final map = <String, Object?>{};
    while (true) {
      _flowSpace();
      if (i >= n) throw _error('unterminated flow ${seq ? 'sequence' : 'mapping'}', start);
      if (s.codeUnitAt(i) == close) {
        i++;
        break;
      }
      final entryStart = i;
      // An entry: `? key : value`, `key: value`, `key` or (in a mapping)
      // `: value` with an empty key.
      var explicit = false;
      if (s.codeUnitAt(i) == 0x3F && _blankAt(i + 1)) {
        explicit = true;
        i++;
        _flowSpace();
      }
      final (Object? key, _Candidate? cand) = _flowNode();
      _flowSpace();
      Object? value;
      var pair = !seq || explicit;
      if (_c(i) == 0x3A &&
          (_blankAt(i + 1) || _flowIndicator(_c(i + 1)) || (cand != null && (cand.quoted || cand.flow)))) {
        pair = true;
        i++;
        _flowSpace();
        final c = _c(i);
        if (c != 0x2C && c != close) value = _flowNode().$1;
        _flowSpace();
      }
      if (seq) {
        if (pair) {
          final m = <String, Object?>{};
          _put(m, key, value, entryStart);
          list.add(m);
        } else {
          list.add(key);
        }
      } else {
        _put(map, key, value, entryStart);
      }
      final c = _c(i);
      if (c == 0x2C) {
        i++;
      } else if (c != close) {
        throw _error(c < 0 ? 'unterminated flow collection' : 'expected "," or "${String.fromCharCode(close)}"');
      }
    }
    _depth--;
    return seq ? list : map;
  }

  /// One node inside a flow collection, and how it was written (null for an
  /// empty node).
  (Object?, _Candidate?) _flowNode() {
    final (anchor, tag) = _props();
    final c = _c(i);
    if (c < 0 || c == 0x2C || c == 0x5D || c == 0x7D || (c == 0x3A && (_blankAt(i + 1) || _flowIndicator(_c(i + 1))))) {
      return (_register(anchor, _empty(tag)), null);
    }
    final cand = _candidate(flow: true);
    return (_register(anchor, _finish(cand, tag, cand.plain ? _continueFlowPlain(cand.text!) : null)), cand);
  }

  /// A plain scalar in a flow collection continues over line breaks.
  String _continueFlowPlain(String first) {
    final text = StringBuffer(first);
    while (true) {
      final save = i;
      _skipSpaces();
      if (i >= n || s.codeUnitAt(i) != 0x0A) {
        i = save;
        return text.toString();
      }
      var breaks = 0;
      while (i < n && s.codeUnitAt(i) == 0x0A) {
        breaks++;
        i++;
        _skipSpaces();
      }
      if (!_plainStart(i, flow: true)) {
        i = save;
        return text.toString();
      }
      final line = _plainLine(flow: true);
      if (line.isEmpty) {
        i = save;
        return text.toString();
      }
      text
        ..write(breaks == 1 ? ' ' : '\n' * (breaks - 1))
        ..write(line);
    }
  }
}

/// What [_Parser._candidate] read.
final class _Candidate {
  _Candidate(
    this.start,
    this.value, {
    this.plain = false,
    this.quoted = false,
    this.flow = false,
    this.multiline = false,
    this.text,
  });

  final int start;
  final Object? value;
  final bool plain, quoted, flow, multiline;

  /// The source text of a plain scalar.
  final String? text;
}

/// A plain scalar by the YAML 1.2 core schema: null, bool, int (decimal,
/// `0o` octal, `0x` hex), float (`.inf`, `.nan`), else the string.
Object? _resolve(String v) {
  if (v.isEmpty) return null;
  final c = v.codeUnitAt(0);
  switch (c) {
    case 0x7E: // ~
      return v.length == 1 ? null : v;
    case 0x6E || 0x4E: // n N
      return v == 'null' || v == 'Null' || v == 'NULL' ? null : v;
    case 0x74 || 0x54: // t T
      return v == 'true' || v == 'True' || v == 'TRUE' ? true : v;
    case 0x66 || 0x46: // f F
      return v == 'false' || v == 'False' || v == 'FALSE' ? false : v;
  }
  if (!(c == 0x2B || c == 0x2D || c == 0x2E || (c >= 0x30 && c <= 0x39))) return v;
  if (_int.hasMatch(v)) return int.tryParse(v) ?? double.parse(v);
  if (v.length > 2 && v.startsWith('0o') && _octal.hasMatch(v)) return int.tryParse(v.substring(2), radix: 8) ?? v;
  if (v.length > 2 && v.startsWith('0x') && _hexInt.hasMatch(v)) return int.tryParse(v.substring(2), radix: 16) ?? v;
  if (_float.hasMatch(v)) {
    var t = v.startsWith('+') ? v.substring(1) : v;
    if (t.endsWith('.')) t = '${t}0';
    if (t.startsWith('.') || t.startsWith('-.')) t = t.replaceFirst('.', '0.');
    return double.parse(t);
  }
  if (_inf.hasMatch(v)) return v.startsWith('-') ? double.negativeInfinity : double.infinity;
  if (v == '.nan' || v == '.NaN' || v == '.NAN') return double.nan;
  return v;
}

final _int = RegExp(r'^[-+]?[0-9]+$');
final _octal = RegExp(r'^0o[0-7]+$');
final _hexInt = RegExp(r'^0x[0-9a-fA-F]+$');
final _float = RegExp(r'^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$');
final _inf = RegExp(r'^[-+]?\.(inf|Inf|INF)$');

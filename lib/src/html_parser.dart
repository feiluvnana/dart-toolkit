/// An HTML5 tokenizer and tree builder after the WHATWG parsing algorithm:
/// implied `html`/`head`/`body`, auto-closed `p`/`li`/cells, tables with
/// implied `tbody`/`tr` and foster parenting, the active formatting list
/// with reconstruction and the adoption agency, raw text (`script`,
/// `style`, `title`, `textarea`), character references, SVG/MathML.
///
/// Comments and doctypes are dropped; scripting is on, as in a browser
/// with JavaScript: `noscript` content is raw text. Private to the toolkit: `html` is the facade.
library;

import 'dart:collection';

import 'dom.dart';
import 'entities.dart';

/// Parse a whole document: the top-level nodes (one `html` element).
List<Node> parseDocument(String input) {
  final b = _Builder(fragment: false);
  _Tokenizer(_normalize(input), b).run();
  return b.top();
}

/// Parse a fragment as the content of a `<div>` in a no-quirks document.
List<Node> parseFragment(String input) {
  final b = _Builder(fragment: true);
  _Tokenizer(_normalize(input), b).run();
  return b.top();
}

String _normalize(String s) => s.contains('\r') ? s.replaceAll('\r\n', '\n').replaceAll('\r', '\n') : s;

enum _Raw { data, rcdata, rawtext, plaintext }

bool _isSpace(int c) => c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0C || c == 0x0D;

bool _isAlpha(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

bool _isAlnum(int c) => _isAlpha(c) || (c >= 0x30 && c <= 0x39);

final class _Tokenizer {
  _Tokenizer(this.s, this.b) {
    b.tok = this;
  }

  final String s;
  final _Builder b;
  var i = 0;
  var raw = _Raw.data;

  /// The end tag that leaves [raw] mode.
  var rawEnd = '';
  final _text = StringBuffer();

  void run() {
    final n = s.length;
    while (i < n) {
      switch (raw) {
        case _Raw.data:
          _data();
        case _Raw.rcdata:
          _rawText(decode: true);
        case _Raw.rawtext:
          _rawText(decode: false);
        case _Raw.plaintext:
          b.rawText(s.substring(i));
          i = n;
      }
    }
    _flush();
    b.eof();
  }

  void _flush() {
    if (_text.isEmpty) return;
    final t = _text.toString();
    _text.clear();
    b.chars(t);
  }

  void _data() {
    final n = s.length;
    final start = i;
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (c == 0x3C || c == 0x26 || c == 0) break;
      i++;
    }
    if (i > start) _text.write(s.substring(start, i));
    if (i >= n) return;
    final c = s.codeUnitAt(i);
    if (c == 0) {
      i++;
    } else if (c == 0x26) {
      _text.write(_charRef(attr: false));
    } else {
      _tagOpen();
    }
  }

  void _tagOpen() {
    final n = s.length;
    if (i + 1 >= n) {
      _text.write('<');
      i++;
      return;
    }
    final c = s.codeUnitAt(i + 1);
    if (c == 0x21) {
      _markup();
    } else if (c == 0x2F) {
      if (i + 2 >= n) {
        _text.write('</');
        i = n;
      } else if (_isAlpha(s.codeUnitAt(i + 2))) {
        i += 2;
        _tag(end: true);
      } else if (s.codeUnitAt(i + 2) == 0x3E) {
        i += 3;
      } else {
        i += 2;
        _bogus();
      }
    } else if (_isAlpha(c)) {
      i++;
      _tag(end: false);
    } else if (c == 0x3F) {
      i++;
      _bogus();
    } else {
      _text.write('<');
      i++;
    }
  }

  /// Skip a bogus comment: up to and including the next `>`.
  void _bogus() {
    final end = s.indexOf('>', i);
    i = end < 0 ? s.length : end + 1;
  }

  void _markup() {
    if (s.startsWith('<!--', i)) {
      final j = i + 4;
      if (s.startsWith('>', j)) {
        i = j + 1;
      } else if (s.startsWith('->', j)) {
        i = j + 2;
      } else {
        var end = s.indexOf('--', j);
        while (end >= 0 && !s.startsWith('-->', end) && !s.startsWith('--!>', end)) {
          end = s.indexOf('--', end + 1);
        }
        i = end < 0 ? s.length : end + (s.startsWith('-->', end) ? 3 : 4);
      }
      return;
    }
    if (s.length >= i + 9 && s.substring(i + 2, i + 9).toLowerCase() == 'doctype') {
      final end = s.indexOf('>', i);
      final body = s.substring(i + 9, end < 0 ? s.length : end);
      i = end < 0 ? s.length : end + 1;
      b.doctype(body);
      return;
    }
    if (s.startsWith('<![CDATA[', i) && b.inForeign) {
      final end = s.indexOf(']]>', i + 9);
      _text.write(s.substring(i + 9, end < 0 ? s.length : end));
      i = end < 0 ? s.length : end + 3;
      return;
    }
    i += 2;
    _bogus();
  }

  void _tag({required bool end}) {
    final n = s.length;
    final start = i;
    var lower = true;
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (_isSpace(c) || c == 0x2F || c == 0x3E) break;
      if (c >= 0x41 && c <= 0x5A || c == 0) lower = false;
      i++;
    }
    var name = s.substring(start, i);
    if (!lower) name = name.toLowerCase().replaceAll('\u0000', '�');
    Map<String, String>? attrs;
    var selfClosing = false;
    while (true) {
      while (i < n && _isSpace(s.codeUnitAt(i))) {
        i++;
      }
      if (i >= n) return; // a tag cut off by the end of the input is dropped
      final c = s.codeUnitAt(i);
      if (c == 0x3E) {
        i++;
        break;
      }
      if (c == 0x2F) {
        i++;
        if (i < n && s.codeUnitAt(i) == 0x3E) {
          selfClosing = true;
          i++;
          break;
        }
        continue;
      }
      final nameStart = i++;
      while (i < n) {
        final d = s.codeUnitAt(i);
        if (_isSpace(d) || d == 0x2F || d == 0x3E || d == 0x3D) break;
        i++;
      }
      final attr = s.substring(nameStart, i).toLowerCase();
      while (i < n && _isSpace(s.codeUnitAt(i))) {
        i++;
      }
      var value = '';
      if (i < n && s.codeUnitAt(i) == 0x3D) {
        i++;
        while (i < n && _isSpace(s.codeUnitAt(i))) {
          i++;
        }
        if (i >= n) return;
        final q = s.codeUnitAt(i);
        if (q == 0x22 || q == 0x27) {
          i++;
          value = _value(q);
          if (i >= n) return;
          i++; // the closing quote
        } else if (q != 0x3E) {
          value = _value(0);
        }
      }
      if (!end) (attrs ??= <String, String>{}).putIfAbsent(attr, () => value);
    }
    _flush();
    if (end) {
      b.endTag(name);
    } else {
      b.startTag(name, attrs ?? <String, String>{}, selfClosing);
    }
  }

  /// An attribute value up to [quote] (0: unquoted, up to a space or `>`),
  /// character references decoded.
  String _value(int quote) {
    final n = s.length;
    final out = StringBuffer();
    var start = i;
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (quote == 0 ? (_isSpace(c) || c == 0x3E) : c == quote) break;
      if (c == 0x26) {
        out.write(s.substring(start, i));
        out.write(_charRef(attr: true));
        start = i;
        continue;
      }
      if (c == 0) {
        out.write(s.substring(start, i));
        out.write('�');
        start = ++i;
        continue;
      }
      i++;
    }
    out.write(s.substring(start, i));
    return out.toString();
  }

  /// The text of a `script`, `style`, `title`, `textarea`… up to its end tag.
  void _rawText({required bool decode}) {
    final n = s.length;
    var j = i;
    var end = rawEnd == 'script' ? _scriptEnd() : -1;
    final len = rawEnd.length;
    while (rawEnd != 'script') {
      j = s.indexOf('</', j);
      if (j < 0 || j + 2 + len > n) break;
      if (s.substring(j + 2, j + 2 + len).toLowerCase() == rawEnd) {
        final k = j + 2 + len;
        if (k >= n || _isSpace(s.codeUnitAt(k)) || s.codeUnitAt(k) == 0x2F || s.codeUnitAt(k) == 0x3E) {
          end = j;
          break;
        }
      }
      j += 2;
    }
    final stop = end < 0 ? n : end;
    var chunk = s.substring(i, stop);
    if (chunk.contains('\u0000')) chunk = chunk.replaceAll('\u0000', '�');
    if (chunk.isNotEmpty) b.rawText(decode && chunk.contains('&') ? decodeText(chunk) : chunk);
    i = stop;
    raw = _Raw.data;
    if (end >= 0) {
      i += 2;
      _tag(end: true);
    }
  }

  /// Where script data ends: the `</script` that closes it, after the
  /// spec's escaped states (inside `<!-- … -->` a `<script>` opens a
  /// double-escaped run whose `</script>` does not end the element), or -1.
  int _scriptEnd() {
    final n = s.length;
    var escaped = false, double = false;
    bool tagAt(int at, String prefix) {
      final k = at + prefix.length + 6;
      if (k > n || s.substring(at, k).toLowerCase() != '${prefix}script') return false;
      return k == n || _isSpace(s.codeUnitAt(k)) || s.codeUnitAt(k) == 0x2F || s.codeUnitAt(k) == 0x3E;
    }

    for (var j = i; j < n; j++) {
      final c = s.codeUnitAt(j);
      if (c == 0x3C) {
        if (!escaped && s.startsWith('<!--', j)) {
          escaped = true;
          j += 3;
        } else if (tagAt(j, '</')) {
          if (!double) return j;
          double = false;
        } else if (escaped && !double && tagAt(j, '<')) {
          double = true;
        }
      } else if (c == 0x2D && escaped && s.startsWith('-->', j)) {
        escaped = double = false;
        j += 2;
      }
    }
    return -1;
  }

  /// A character reference at `&` (or a literal `&`).
  String _charRef({required bool attr}) {
    final (text, next) = charRef(s, i, attr: attr);
    i = next;
    return text;
  }
}

/// [s] with its character references decoded (RCDATA text).
String decodeText(String s) {
  final out = StringBuffer();
  var start = 0, i = 0;
  while (true) {
    final amp = s.indexOf('&', i);
    if (amp < 0) break;
    out.write(s.substring(start, amp));
    final (text, next) = charRef(s, amp, attr: false);
    out.write(text);
    start = i = next;
  }
  out.write(s.substring(start));
  return out.toString();
}

/// The reference at [s]`[at]` (an `&`): its text and where reading resumes.
(String, int) charRef(String s, int at, {required bool attr}) {
  final n = s.length;
  final j = at + 1;
  if (j >= n) return ('&', j);
  final c = s.codeUnitAt(j);
  if (c == 0x23) {
    var k = j + 1;
    final hex = k < n && (s.codeUnitAt(k) | 0x20) == 0x78;
    if (hex) k++;
    final start = k;
    var code = 0;
    while (k < n) {
      final d = s.codeUnitAt(k);
      int v;
      if (d >= 0x30 && d <= 0x39) {
        v = d - 0x30;
      } else if (hex && (d | 0x20) >= 0x61 && (d | 0x20) <= 0x66) {
        v = (d | 0x20) - 0x61 + 10;
      } else {
        break;
      }
      if (code <= 0x10FFFF) code = code * (hex ? 16 : 10) + v;
      k++;
    }
    if (k == start) return ('&', j);
    if (k < n && s.codeUnitAt(k) == 0x3B) k++;
    return (_codePoint(code), k);
  }
  if (!_isAlnum(c)) return ('&', j);
  var k = j;
  while (k < n && k - j < longestEntity && _isAlnum(s.codeUnitAt(k))) {
    k++;
  }
  final table = entities;
  var end = k < n && s.codeUnitAt(k) == 0x3B ? k + 1 : k;
  for (; end > j; end--) {
    final value = table[s.substring(j, end)];
    if (value == null) continue;
    if (attr && s.codeUnitAt(end - 1) != 0x3B && end < n) {
      final next = s.codeUnitAt(end);
      if (next == 0x3D || _isAlnum(next)) return ('&', j);
    }
    return (value, end);
  }
  return ('&', j);
}

String _codePoint(int code) {
  if (code == 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return '�';
  final mapped = replacements[code];
  return String.fromCharCode(mapped ?? code);
}

enum _Phase { initial, beforeHead, inHead, afterHead, body }

final _doctypeName = RegExp(r'^\S+');
final _publicId = RegExp(r"""public\s*["']([^"']*)""");
final _withSystem = RegExp(r"""public\s*["'][^"']*["']\s*["']""");
final _systemId = RegExp(r"""system\s*["']""");

const _voidHead = {'base', 'basefont', 'bgsound', 'link', 'meta'};
const _headish = {'base', 'basefont', 'bgsound', 'link', 'meta', 'noframes', 'script', 'style', 'template', 'title'};
/// The controls `form()` reads, owned by the open form when parsed.
const _controls = {'input', 'select', 'textarea'};

const _formattingNames = {
  'a', 'b', 'big', 'code', 'em', 'font', 'i', 'nobr', 's', 'small', 'strike', 'strong', 'tt', 'u', //
};
const _closesP = {
  'address', 'article', 'aside', 'blockquote', 'center', 'details', 'dialog', 'dir', 'div', 'dl', 'fieldset', //
  'figcaption', 'figure', 'footer', 'header', 'hgroup', 'main', 'menu', 'nav', 'ol', 'p', 'search', 'section', //
  'summary', 'ul',
};
const _headings = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};
const _impliedEnd = {'dd', 'dt', 'li', 'optgroup', 'option', 'p', 'rb', 'rp', 'rt', 'rtc'};
const _blockEnds = {
  'address', 'article', 'aside', 'blockquote', 'button', 'center', 'details', 'dialog', 'dir', 'div', 'dl', //
  'fieldset', 'figcaption', 'figure', 'footer', 'header', 'hgroup', 'listing', 'main', 'menu', 'nav', 'ol', //
  'pre', 'search', 'section', 'summary', 'ul',
};
const _special = {
  'address', 'applet', 'area', 'article', 'aside', 'base', 'basefont', 'bgsound', 'blockquote', 'body', 'br', //
  'button', 'caption', 'center', 'col', 'colgroup', 'dd', 'details', 'dir', 'div', 'dl', 'dt', 'embed', //
  'fieldset', 'figcaption', 'figure', 'footer', 'form', 'frame', 'frameset', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', //
  'head', 'header', 'hgroup', 'hr', 'html', 'iframe', 'img', 'input', 'keygen', 'li', 'link', 'listing', 'main', //
  'marquee', 'menu', 'meta', 'nav', 'noembed', 'noframes', 'noscript', 'object', 'ol', 'p', 'param', 'plaintext', //
  'pre', 'script', 'search', 'section', 'select', 'source', 'style', 'summary', 'table', 'tbody', 'td', //
  'template', 'textarea', 'tfoot', 'th', 'thead', 'title', 'tr', 'track', 'ul', 'wbr', 'xmp',
};
const _scopeHtml = {'applet', 'caption', 'html', 'table', 'td', 'th', 'marquee', 'object', 'template'};
const _tableContext = {'table', 'tbody', 'thead', 'tfoot', 'tr'};
const _tableSections = {'tbody', 'thead', 'tfoot'};
const _cellClosers = {'caption', 'col', 'colgroup', 'tbody', 'td', 'tfoot', 'th', 'thead', 'tr'};
const _rawNames = {
  'title', 'textarea', 'style', 'script', 'xmp', 'iframe', 'noembed', 'noframes', 'noscript', 'plaintext', //
};
const _foreignBreakout = {
  'b', 'big', 'blockquote', 'body', 'br', 'center', 'code', 'dd', 'div', 'dl', 'dt', 'em', 'embed', 'h1', 'h2', //
  'h3', 'h4', 'h5', 'h6', 'head', 'hr', 'i', 'img', 'li', 'listing', 'menu', 'meta', 'nobr', 'ol', 'p', 'pre', //
  'ruby', 's', 'small', 'span', 'strong', 'strike', 'sub', 'sup', 'table', 'tt', 'u', 'ul', 'var',
};

/// SVG element names the spec writes in camel case.
const _svgTags = {
  'altglyph': 'altGlyph', 'altglyphdef': 'altGlyphDef', 'altglyphitem': 'altGlyphItem', //
  'animatecolor': 'animateColor', 'animatemotion': 'animateMotion', 'animatetransform': 'animateTransform', //
  'clippath': 'clipPath', 'feblend': 'feBlend', 'fecolormatrix': 'feColorMatrix', //
  'fecomponenttransfer': 'feComponentTransfer', 'fecomposite': 'feComposite', //
  'feconvolvematrix': 'feConvolveMatrix', 'fediffuselighting': 'feDiffuseLighting', //
  'fedisplacementmap': 'feDisplacementMap', 'fedistantlight': 'feDistantLight', 'fedropshadow': 'feDropShadow', //
  'feflood': 'feFlood', 'fefunca': 'feFuncA', 'fefuncb': 'feFuncB', 'fefuncg': 'feFuncG', 'fefuncr': 'feFuncR', //
  'fegaussianblur': 'feGaussianBlur', 'feimage': 'feImage', 'femerge': 'feMerge', 'femergenode': 'feMergeNode', //
  'femorphology': 'feMorphology', 'feoffset': 'feOffset', 'fepointlight': 'fePointLight', //
  'fespecularlighting': 'feSpecularLighting', 'fespotlight': 'feSpotLight', 'fetile': 'feTile', //
  'feturbulence': 'feTurbulence', 'foreignobject': 'foreignObject', 'glyphref': 'glyphRef', //
  'lineargradient': 'linearGradient', 'radialgradient': 'radialGradient', 'textpath': 'textPath',
};

/// SVG attribute names the spec writes in camel case.
const _svgAttrs = {
  'attributename': 'attributeName', 'attributetype': 'attributeType', 'basefrequency': 'baseFrequency', //
  'baseprofile': 'baseProfile', 'calcmode': 'calcMode', 'clippathunits': 'clipPathUnits', //
  'diffuseconstant': 'diffuseConstant', 'edgemode': 'edgeMode', 'filterunits': 'filterUnits', //
  'glyphref': 'glyphRef', 'gradienttransform': 'gradientTransform', 'gradientunits': 'gradientUnits', //
  'kernelmatrix': 'kernelMatrix', 'kernelunitlength': 'kernelUnitLength', 'keypoints': 'keyPoints', //
  'keysplines': 'keySplines', 'keytimes': 'keyTimes', 'lengthadjust': 'lengthAdjust', //
  'limitingconeangle': 'limitingConeAngle', 'markerheight': 'markerHeight', 'markerunits': 'markerUnits', //
  'markerwidth': 'markerWidth', 'maskcontentunits': 'maskContentUnits', 'maskunits': 'maskUnits', //
  'numoctaves': 'numOctaves', 'pathlength': 'pathLength', 'patterncontentunits': 'patternContentUnits', //
  'patterntransform': 'patternTransform', 'patternunits': 'patternUnits', 'pointsatx': 'pointsAtX', //
  'pointsaty': 'pointsAtY', 'pointsatz': 'pointsAtZ', 'preservealpha': 'preserveAlpha', //
  'preserveaspectratio': 'preserveAspectRatio', 'primitiveunits': 'primitiveUnits', 'refx': 'refX', //
  'refy': 'refY', 'repeatcount': 'repeatCount', 'repeatdur': 'repeatDur', //
  'requiredextensions': 'requiredExtensions', 'requiredfeatures': 'requiredFeatures', //
  'specularconstant': 'specularConstant', 'specularexponent': 'specularExponent', 'spreadmethod': 'spreadMethod', //
  'startoffset': 'startOffset', 'stddeviation': 'stdDeviation', 'stitchtiles': 'stitchTiles', //
  'surfacescale': 'surfaceScale', 'systemlanguage': 'systemLanguage', 'tablevalues': 'tableValues', //
  'targetx': 'targetX', 'targety': 'targetY', 'textlength': 'textLength', 'viewbox': 'viewBox', //
  'viewtarget': 'viewTarget', 'xchannelselector': 'xChannelSelector', 'ychannelselector': 'yChannelSelector', //
  'zoomandpan': 'zoomAndPan',
};

/// Public identifiers whose doctype puts the document in quirks mode.
const _quirkyIds = [
  '+//silmaril//dtd html pro v0r11 19970101//', '-//as//dtd html 3.0 aswedit + extensions//', //
  '-//advasoft ltd//dtd html 3.0 aswedit + extensions//', '-//ietf//dtd html 2.0 level 1//', //
  '-//ietf//dtd html 2.0 level 2//', '-//ietf//dtd html 2.0 strict level 1//', //
  '-//ietf//dtd html 2.0 strict level 2//', '-//ietf//dtd html 2.0 strict//', '-//ietf//dtd html 2.0//', //
  '-//ietf//dtd html 2.1e//', '-//ietf//dtd html 3.0//', '-//ietf//dtd html 3.2 final//', //
  '-//ietf//dtd html 3.2//', '-//ietf//dtd html 3//', '-//ietf//dtd html level 0//', //
  '-//ietf//dtd html level 1//', '-//ietf//dtd html level 2//', '-//ietf//dtd html level 3//', //
  '-//ietf//dtd html strict level 0//', '-//ietf//dtd html strict level 1//', //
  '-//ietf//dtd html strict level 2//', '-//ietf//dtd html strict level 3//', '-//ietf//dtd html strict//', //
  '-//ietf//dtd html//', '-//metrius//dtd metrius presentational//', //
  '-//microsoft//dtd internet explorer 2.0 html strict//', '-//microsoft//dtd internet explorer 2.0 html//', //
  '-//microsoft//dtd internet explorer 2.0 tables//', '-//microsoft//dtd internet explorer 3.0 html strict//', //
  '-//microsoft//dtd internet explorer 3.0 html//', '-//microsoft//dtd internet explorer 3.0 tables//', //
  '-//netscape comm. corp.//dtd html//', '-//netscape comm. corp.//dtd strict html//', //
  "-//o'reilly and associates//dtd html 2.0//", "-//o'reilly and associates//dtd html extended 1.0//", //
  "-//o'reilly and associates//dtd html extended relaxed 1.0//", //
  '-//sq//dtd html 2.0 hotmetal + extensions//',
  '-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//', //
  '-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//', '-//spyglass//dtd html 2.0 extended//', //
  '-//sun microsystems corp.//dtd hotjava html//', '-//sun microsystems corp.//dtd hotjava strict html//', //
  '-//w3c//dtd html 3 1995-03-24//', '-//w3c//dtd html 3.2 draft//', '-//w3c//dtd html 3.2 final//', //
  '-//w3c//dtd html 3.2//', '-//w3c//dtd html 3.2s draft//', '-//w3c//dtd html 4.0 frameset//', //
  '-//w3c//dtd html 4.0 transitional//', '-//w3c//dtd html experimental 19960712//', //
  '-//w3c//dtd html experimental 970421//', '-//w3c//dtd w3 html//', '-//w3o//dtd w3 html 3.0//', //
  '-//webtechs//dtd mozilla html 2.0//', '-//webtechs//dtd mozilla html//',
];

final class _Builder {
  _Builder({required this.fragment}) {
    if (fragment) {
      final root = Element('html');
      html = body = root;
      open.add(root);
      phase = _Phase.body;
      quirks = false;
    }
  }

  final bool fragment;
  late _Tokenizer tok;

  final open = _Open();

  /// The active formatting elements; null is a marker.
  final formatting = <Element?>[];
  Element? html, head, body, form;
  var phase = _Phase.initial;
  var quirks = true;
  var _skipLf = false;
  var _foster = false;

  List<Node> top() {
    final root = html;
    if (root == null) return const [];
    if (!fragment) return [root];
    final nodes = [...root.nodes];
    for (final n in nodes) {
      n.parent = null;
    }
    return nodes;
  }

  Element get current => open.last;

  bool get inForeign => open.isNotEmpty && current.space != Space.html;

  // ---- tokens ----

  void doctype(String body) {
    if (phase != _Phase.initial) return;
    final t = body.trim().toLowerCase();
    final name = _doctypeName.stringMatch(t) ?? '';
    final pub = _publicId.firstMatch(t)?[1];
    final hasSystem = _withSystem.hasMatch(t) || _systemId.hasMatch(t);
    quirks =
        name != 'html' ||
        pub != null &&
            (pub == '-//w3o//dtd w3 html strict 3.0//en//' ||
                pub == '-/w3c/dtd html 4.0 transitional/en' ||
                pub == 'html' ||
                _quirkyIds.any(pub.startsWith) ||
                !hasSystem &&
                    (pub.startsWith('-//w3c//dtd html 4.01 frameset//') ||
                        pub.startsWith('-//w3c//dtd html 4.01 transitional//')));
  }

  /// The text of a raw element (`script`, `title`, `textarea`…): always
  /// into that element.
  void rawText(String t) {
    if (_skipLf) {
      _skipLf = false;
      if (t.startsWith('\n')) t = t.substring(1);
    }
    if (t.isNotEmpty) current.append(Text(t));
  }

  void chars(String t) {
    if (_skipLf) {
      _skipLf = false;
      if (t.startsWith('\n')) t = t.substring(1);
      if (t.isEmpty) return;
    }
    while (t.isNotEmpty) {
      switch (phase) {
        case _Phase.initial:
          t = _trimSpace(t);
          if (t.isEmpty) return;
          _implicitHtml();
        case _Phase.beforeHead:
          t = _trimSpace(t);
          if (t.isEmpty) return;
          _insertHead({});
        case _Phase.inHead when _inHeadTemplate:
          _insertText(t);
          return;
        case _Phase.inHead || _Phase.afterHead:
          final rest = _trimSpace(t);
          if (rest.length < t.length) _insertText(t.substring(0, t.length - rest.length));
          t = rest;
          if (t.isEmpty) return;
          if (phase == _Phase.inHead) {
            _popHead();
          } else {
            _insertBody({});
          }
        case _Phase.body:
          _bodyText(t);
          return;
      }
    }
  }

  String _trimSpace(String t) {
    var k = 0;
    while (k < t.length && _isSpace(t.codeUnitAt(k))) {
      k++;
    }
    return k == 0 ? t : t.substring(k);
  }

  void _bodyText(String t) {
    if (inForeign && !_htmlPoint(current)) {
      _insertText(t);
      return;
    }
    if (_openSelect() != null) {
      _insertText(t);
      return;
    }
    final mode = _tableMode();
    if (mode != null && mode != 'colgroup') {
      if (_trimSpace(t).isEmpty && _tableContext.contains(current.localName)) {
        _insertText(t);
      } else {
        _foster = true;
        _reconstruct();
        _insertText(t);
        _foster = false;
      }
      return;
    }
    if (mode == 'colgroup') {
      final rest = _trimSpace(t);
      if (rest.length < t.length) _insertText(t.substring(0, t.length - rest.length));
      if (rest.isEmpty) return;
      open.removeLast();
      return _bodyText(rest);
    }
    _reconstruct();
    _insertText(t);
  }

  void startTag(String name, Map<String, String> attrs, bool selfClosing) {
    _skipLf = false;
    while (true) {
      switch (phase) {
        case _Phase.initial:
          if (name == 'html') {
            _implicitHtml(attrs);
            return;
          }
          _implicitHtml();
          continue;
        case _Phase.beforeHead:
          if (name == 'html') return _mergeAttrs(html, attrs);
          if (name == 'head') {
            _insertHead(attrs);
            return;
          }
          _insertHead({});
          continue;
        case _Phase.inHead:
          if (_inHeadTemplate) return _bodyStart(name, attrs, selfClosing);
          if (name == 'html') return _mergeAttrs(html, attrs);
          if (name == 'head') return;
          if (_headish.contains(name) || name == 'noscript') return _headTag(name, attrs);
          _popHead();
          continue;
        case _Phase.afterHead:
          if (name == 'html') return _mergeAttrs(html, attrs);
          if (name == 'body' || name == 'frameset') {
            _insertBody(attrs);
            return;
          }
          if (name == 'head') return;
          if (_headish.contains(name)) {
            final h = head!;
            open.add(h);
            _headTag(name, attrs);
            open.remove(h);
            return;
          }
          _insertBody({});
          continue;
        case _Phase.body:
          return _bodyStart(name, attrs, selfClosing);
      }
    }
  }

  void _headTag(String name, Map<String, String> attrs) {
    final el = _insert(name, attrs);
    if (_voidHead.contains(name)) {
      open.removeLast();
    } else if (name == 'title') {
      _rawMode(_Raw.rcdata, name);
    } else if (name == 'style' || name == 'noframes' || name == 'script' || name == 'noscript') {
      _rawMode(_Raw.rawtext, name);
    }
    assert(el.localName == name);
  }

  void _rawMode(_Raw mode, String name) {
    tok
      ..raw = mode
      ..rawEnd = name;
  }

  void _bodyStart(String name, Map<String, String> attrs, bool selfClosing) {
    // Foreign content: SVG and MathML keep their own rules until an HTML
    // tag breaks out or an integration point admits HTML.
    if (inForeign && !_htmlPoint(current) && !(_mathTextPoint(current) && name != 'mglyph' && name != 'malignmark')) {
      final breaks =
          _foreignBreakout.contains(name) ||
          name == 'font' && (attrs.containsKey('color') || attrs.containsKey('face') || attrs.containsKey('size'));
      if (!breaks && !(current.localName == 'annotation-xml' && name == 'svg')) {
        _insertForeign(name, attrs, current.space, selfClosing);
        return;
      }
      if (breaks) {
        while (open.length > 1 && current.space != Space.html && !_htmlPoint(current) && !_mathTextPoint(current)) {
          open.removeLast();
        }
      }
    }
    // In select: only options, groups and scripts.
    final select = _openSelect();
    if (select != null) {
      switch (name) {
        case 'option':
          if (current.localName == 'option') open.removeLast();
          _insert(name, attrs);
        case 'optgroup':
          if (current.localName == 'option') open.removeLast();
          if (current.localName == 'optgroup') open.removeLast();
          _insert(name, attrs);
        case 'select':
          _popUntil(select);
        case 'input' || 'keygen' || 'textarea':
          _popUntil(select);
          return _bodyStart(name, attrs, selfClosing);
        case 'script' || 'template' || 'style':
          _headTag(name, attrs);
        case 'caption' || 'table' || 'tbody' || 'tfoot' || 'thead' || 'tr' || 'td' || 'th' when _inTable(select):
          _popUntil(select);
          return _bodyStart(name, attrs, selfClosing);
        case 'html':
          _mergeAttrs(html, attrs);
      }
      return;
    }
    final mode = _tableMode();
    if (mode == 'colgroup') {
      if (name == 'col') {
        _insert(name, attrs);
        open.removeLast();
        return;
      }
      if (name == 'template') return _headTag(name, attrs);
      _popUntil(open.lastWhere((e) => e.localName == 'colgroup'));
      return _bodyStart(name, attrs, selfClosing);
    }
    if (mode != null) {
      if (_tableStart(mode, name, attrs, selfClosing)) return;
      _foster = true;
      _inBody(name, attrs, selfClosing);
      _foster = false;
      return;
    }
    // A template's content takes table parts as they come (the spec's
    // template insertion modes): a row, a cell, a section or a caption.
    if (current.localName == 'template' && current.space == Space.html && _templateParts.contains(name)) {
      _insert(name, attrs);
      if (name == 'col') {
        open.removeLast();
      } else if (name == 'td' || name == 'th' || name == 'caption') {
        formatting.add(null);
      }
      return;
    }
    if (_cellClosers.contains(name)) {
      final cell = _inScope(const {'td', 'th'}, _tableScope);
      if (cell != null) {
        _closeCell();
        return _bodyStart(name, attrs, selfClosing);
      }
      final caption = _inScope(const {'caption'}, _tableScope);
      if (caption != null) {
        _generateImplied();
        _popUntil(caption);
        _clearToMarker();
        return _bodyStart(name, attrs, selfClosing);
      }
    }
    _inBody(name, attrs, selfClosing);
  }

  /// Start tags in a table, a section or a row. True when handled.
  bool _tableStart(String cur, String name, Map<String, String> attrs, bool selfClosing) {
    switch (name) {
      case 'style' || 'script' || 'template':
        _headTag(name, attrs);
        return true;
      case 'input' when (attrs['type'] ?? '').toLowerCase() == 'hidden':
        _insert(name, attrs);
        open.removeLast();
        return true;
      case 'form':
        if (form == null) {
          form = _insert(name, attrs);
          open.removeLast();
        }
        return true;
    }
    if (cur == 'table') {
      switch (name) {
        case 'caption':
          _clearTo(const {'table', 'template', 'html'});
          formatting.add(null);
          _insert(name, attrs);
          return true;
        case 'colgroup':
          _clearTo(const {'table', 'template', 'html'});
          _insert(name, attrs);
          return true;
        case 'col':
          _clearTo(const {'table', 'template', 'html'});
          _insert('colgroup', {});
          _bodyStart(name, attrs, selfClosing);
          return true;
        case 'tbody' || 'tfoot' || 'thead':
          _clearTo(const {'table', 'template', 'html'});
          _insert(name, attrs);
          return true;
        case 'td' || 'th' || 'tr':
          _clearTo(const {'table', 'template', 'html'});
          _insert('tbody', {});
          _bodyStart(name, attrs, selfClosing);
          return true;
        case 'table':
          final t = _inScope(const {'table'}, _tableScope);
          if (t != null) {
            _popUntil(t);
            _bodyStart(name, attrs, selfClosing);
          }
          return true;
      }
      return false;
    }
    if (_tableSections.contains(cur)) {
      switch (name) {
        case 'tr':
          _clearTo(const {'tbody', 'tfoot', 'thead', 'template', 'html'});
          _insert(name, attrs);
          return true;
        case 'th' || 'td':
          _clearTo(const {'tbody', 'tfoot', 'thead', 'template', 'html'});
          _insert('tr', {});
          _bodyStart(name, attrs, selfClosing);
          return true;
        case 'caption' || 'col' || 'colgroup' || 'tbody' || 'tfoot' || 'thead' || 'table':
          _clearTo(const {'tbody', 'tfoot', 'thead', 'template', 'html'});
          open.removeLast();
          _bodyStart(name, attrs, selfClosing);
          return true;
      }
      return false;
    }
    // cur == 'tr'
    switch (name) {
      case 'th' || 'td':
        _clearTo(const {'tr', 'template', 'html'});
        _insert(name, attrs);
        formatting.add(null);
        return true;
      case 'caption' || 'col' || 'colgroup' || 'tbody' || 'tfoot' || 'thead' || 'tr' || 'table':
        _clearTo(const {'tr', 'template', 'html'});
        open.removeLast();
        _bodyStart(name, attrs, selfClosing);
        return true;
    }
    return false;
  }

  void _inBody(String name, Map<String, String> attrs, bool selfClosing) {
    switch (name) {
      case 'html':
        if (!fragment) _mergeAttrs(html, attrs);
      case 'base' ||
          'basefont' ||
          'bgsound' ||
          'link' ||
          'meta' ||
          'noframes' ||
          'script' ||
          'style' ||
          'template' ||
          'title':
        _headTag(name, attrs);
      case 'body':
        if (!fragment && open.length > 1 && open[1].localName == 'body') _mergeAttrs(open[1], attrs);
      case 'frameset' ||
          'caption' ||
          'col' ||
          'colgroup' ||
          'frame' ||
          'head' ||
          'tbody' ||
          'td' ||
          'tfoot' ||
          'th' ||
          'thead' ||
          'tr':
        break;
      case _ when _closesP.contains(name):
        _closeP();
        _insert(name, attrs);
      case _ when _headings.contains(name):
        _closeP();
        if (_headings.contains(current.localName)) open.removeLast();
        _insert(name, attrs);
      case 'pre' || 'listing':
        _closeP();
        _insert(name, attrs);
        _skipLf = true;
      case 'form':
        if (form != null) return;
        _closeP();
        form = _insert(name, attrs);
      case 'li' || 'dd' || 'dt':
        final same = name == 'li' ? const {'li'} : const {'dd', 'dt'};
        for (var k = open.length - 1; k >= 0; k--) {
          final node = open[k];
          if (same.contains(node.localName)) {
            _generateImplied(except: node.localName);
            _popUntil(node);
            break;
          }
          if (_isSpecial(node) && !const {'address', 'div', 'p'}.contains(node.localName)) break;
        }
        _closeP();
        _insert(name, attrs);
      case 'plaintext':
        _closeP();
        _insert(name, attrs);
        tok.raw = _Raw.plaintext;
      case 'button':
        final b = _inScope(const {'button'}, _scopeHtml);
        if (b != null) {
          _generateImplied();
          _popUntil(b);
        }
        _reconstruct();
        _insert(name, attrs);
      case 'a':
        final a = _formattingAfterMarker('a');
        if (a != null) {
          _adoption('a');
          formatting.remove(a);
          open.remove(a);
        }
        _reconstruct();
        _pushFormatting(_insert(name, attrs));
      case 'nobr':
        _reconstruct();
        if (_inScope(const {'nobr'}, _scopeHtml) != null) {
          _adoption('nobr');
          _reconstruct();
        }
        _pushFormatting(_insert(name, attrs));
      case _ when _formattingNames.contains(name):
        _reconstruct();
        _pushFormatting(_insert(name, attrs));
      case 'applet' || 'marquee' || 'object':
        _reconstruct();
        _insert(name, attrs);
        formatting.add(null);
      case 'table':
        if (!quirks) _closeP();
        _insert(name, attrs);
      case 'area' || 'br' || 'embed' || 'img' || 'keygen' || 'wbr' || 'input':
        _reconstruct();
        _insert(name, attrs);
        open.removeLast();
      case 'image':
        _inBody('img', attrs, selfClosing);
      case 'param' || 'source' || 'track':
        _insert(name, attrs);
        open.removeLast();
      case 'hr':
        _closeP();
        _insert(name, attrs);
        open.removeLast();
      case 'textarea':
        _insert(name, attrs);
        _rawMode(_Raw.rcdata, name);
        _skipLf = true;
      case 'xmp':
        _closeP();
        _reconstruct();
        _insert(name, attrs);
        _rawMode(_Raw.rawtext, name);
      case 'iframe' || 'noembed' || 'noscript':
        _insert(name, attrs);
        _rawMode(_Raw.rawtext, name);
      case 'optgroup' || 'option':
        if (current.localName == 'option') open.removeLast();
        _reconstruct();
        _insert(name, attrs);
      case 'rb' || 'rtc':
        if (_inScope(const {'ruby'}, _scopeHtml) != null) _generateImplied();
        _insert(name, attrs);
      case 'rp' || 'rt':
        if (_inScope(const {'ruby'}, _scopeHtml) != null) _generateImplied(except: 'rtc');
        _insert(name, attrs);
      case 'math':
        _reconstruct();
        _insertForeign(name, attrs, Space.math, selfClosing);
      case 'svg':
        _reconstruct();
        _insertForeign(name, attrs, Space.svg, selfClosing);
      default:
        _reconstruct();
        _insert(name, attrs);
    }
  }

  void endTag(String name) {
    _skipLf = false;
    if (open.isNotEmpty && current.localName == name && _rawNames.contains(name) && current.space == Space.html) {
      open.removeLast();
      return;
    }
    while (true) {
      switch (phase) {
        case _Phase.initial:
          if (!const {'head', 'body', 'html', 'br'}.contains(name)) return;
          _implicitHtml();
          continue;
        case _Phase.beforeHead:
          if (!const {'head', 'body', 'html', 'br'}.contains(name)) return;
          _insertHead({});
          continue;
        case _Phase.inHead:
          if (name == 'head') {
            _popHead();
            return;
          }
          if (name == 'template') {
            final t = _inScope(const {'template'}, const {'html'});
            if (t != null) _popUntil(t);
            return;
          }
          if (_inHeadTemplate) return _bodyEnd(name);
          if (!const {'body', 'html', 'br'}.contains(name)) return;
          _popHead();
          continue;
        case _Phase.afterHead:
          if (!const {'body', 'html', 'br'}.contains(name)) return;
          _insertBody({});
          continue;
        case _Phase.body:
          return _bodyEnd(name);
      }
    }
  }

  void _bodyEnd(String name) {
    if (inForeign) {
      for (var k = open.length - 1; k > 0; k--) {
        final node = open[k];
        if (node.space == Space.html) break;
        if (node.localName.toLowerCase() == name) {
          _popUntil(node);
          return;
        }
      }
    }
    final select = _openSelect();
    if (select != null) {
      switch (name) {
        case 'optgroup':
          if (current.localName == 'option' && open.length > 1 && open[open.length - 2].localName == 'optgroup') {
            open.removeLast();
          }
          if (current.localName == 'optgroup') open.removeLast();
        case 'option':
          if (current.localName == 'option') open.removeLast();
        case 'select':
          _popUntil(select);
        case 'caption' || 'table' || 'tbody' || 'tfoot' || 'thead' || 'tr' || 'td' || 'th' when _inTable(select):
          if (_inScope({name}, _tableScope) != null) {
            _popUntil(select);
            _bodyEnd(name);
          }
      }
      return;
    }
    switch (name) {
      case 'table':
        final t = _inScope(const {'table'}, _tableScope);
        if (t != null) _popUntil(t);
        return;
      case 'tbody' || 'tfoot' || 'thead':
        final s = _inScope({name}, _tableScope);
        if (s == null) return;
        _clearTo(const {'tbody', 'tfoot', 'thead', 'template', 'html'});
        open.removeLast();
        return;
      case 'tr':
        final r = _inScope(const {'tr'}, _tableScope);
        if (r != null) _popUntil(r);
        return;
      case 'td' || 'th':
        final c = _inScope({name}, _tableScope);
        if (c == null) return;
        _generateImplied();
        _popUntil(c);
        _clearToMarker();
        return;
      case 'caption':
        final c = _inScope(const {'caption'}, _tableScope);
        if (c == null) return;
        _generateImplied();
        _popUntil(c);
        _clearToMarker();
        return;
      case 'colgroup':
        if (current.localName == 'colgroup') open.removeLast();
        return;
      case 'col':
        return;
      case 'body' || 'html':
        // The body stays the insertion point: later text and tags land in it.
        return;
      case _ when _blockEnds.contains(name):
        final el = _inScope({name}, _scopeHtml);
        if (el == null) return;
        _generateImplied();
        _popUntil(el);
      case 'form':
        final node = form;
        form = null;
        if (node == null || !_onScope(node, _scopeHtml)) return;
        _generateImplied();
        open.remove(node);
      case 'p':
        if (_inScope(const {'p'}, _buttonScope) == null) _insert('p', {});
        _closeP();
      case 'li':
        final el = _inScope(const {'li'}, _listScope);
        if (el == null) return;
        _generateImplied(except: 'li');
        _popUntil(el);
      case 'dd' || 'dt':
        final el = _inScope({name}, _scopeHtml);
        if (el == null) return;
        _generateImplied(except: name);
        _popUntil(el);
      case _ when _headings.contains(name):
        final el = _inScope(_headings, _scopeHtml);
        if (el == null) return;
        _generateImplied();
        _popUntil(el);
      case _ when _formattingNames.contains(name):
        _adoption(name);
      case 'applet' || 'marquee' || 'object':
        final el = _inScope({name}, _scopeHtml);
        if (el == null) return;
        _generateImplied();
        _popUntil(el);
        _clearToMarker();
      case 'br':
        _inBody('br', {}, false);
      default:
        _anyOtherEnd(name);
    }
  }

  void _anyOtherEnd(String name) {
    for (var k = open.length - 1; k > 0; k--) {
      final node = open[k];
      if (node.localName == name && node.space == Space.html) {
        _generateImplied(except: name);
        _popUntil(node);
        return;
      }
      if (_isSpecial(node)) return;
    }
  }

  void eof() {
    if (fragment) return;
    if (phase == _Phase.initial) _implicitHtml();
    if (phase == _Phase.beforeHead) _insertHead({});
    if (phase == _Phase.inHead) _popHead();
    if (phase == _Phase.afterHead) _insertBody({});
  }

  // ---- structure ----

  void _implicitHtml([Map<String, String>? attrs]) {
    final el = Element('html', attrs);
    html = el;
    open.add(el);
    phase = _Phase.beforeHead;
  }

  void _insertHead(Map<String, String> attrs) {
    head = _insert('head', attrs);
    phase = _Phase.inHead;
  }

  void _popHead() {
    if (current.localName == 'head') open.removeLast();
    phase = _Phase.afterHead;
  }

  void _insertBody(Map<String, String> attrs) {
    body = _insert('body', attrs);
    phase = _Phase.body;
  }

  void _mergeAttrs(Element? el, Map<String, String> attrs) {
    if (el == null) return;
    attrs.forEach((k, v) => el.attributes.putIfAbsent(k, () => v));
  }

  Element _insert(String name, Map<String, String> attrs, [Space space = Space.html]) {
    final el = Element(name, attrs, space);
    final owner = form;
    if (owner != null &&
        space == Space.html &&
        _controls.contains(name) &&
        !attrs.containsKey('form') &&
        !open.any((e) => e.localName == 'template')) {
      formOwner[el] = owner;
    }
    _place(el);
    open.add(el);
    return el;
  }

  void _insertForeign(String name, Map<String, String> attrs, Space space, bool selfClosing) {
    if (space == Space.svg) {
      name = _svgTags[name] ?? name;
      attrs = {for (final e in attrs.entries) _svgAttrs[e.key] ?? e.key: e.value};
    } else if (attrs.containsKey('definitionurl')) {
      attrs = {for (final e in attrs.entries) e.key == 'definitionurl' ? 'definitionURL' : e.key: e.value};
    }
    _insert(name, attrs, space);
    if (selfClosing) open.removeLast();
  }

  /// Append [node] at the current insertion point (fostered before the
  /// table when a table holds content it may not).
  void _place(Node node, [Element? target]) {
    final parent = target ?? current;
    if ((_foster || target != null) && _tableContext.contains(parent.localName) && parent.space == Space.html) {
      final table = open.lastWhere((e) => e.localName == 'table', orElse: () => open.first);
      final holder = table.parent;
      if (table.localName == 'table' && holder != null) {
        final at = holder.nodes.lastIndexOf(table); // the table is usually the last child
        if (node is Text && at > 0 && holder.nodes[at - 1] is Text) {
          (holder.nodes[at - 1] as Text).add(node.data);
          return;
        }
        holder.insertBefore(node, table);
        return;
      }
      final k = open.indexOf(table);
      (k > 0 ? open[k - 1] : open.first).append(node);
      return;
    }
    if (node is Text && parent.nodes.isNotEmpty && parent.nodes.last is Text) {
      (parent.nodes.last as Text).add(node.data);
      return;
    }
    parent.append(node);
  }

  void _insertText(String t) => _place(Text(t));

  // ---- scope ----

  static const _buttonScope = {..._scopeHtml, 'button'};
  static const _listScope = {..._scopeHtml, 'ol', 'ul'};
  static const _tableScope = {'html', 'table', 'template'};
  static const _tableish = ['table', 'tbody', 'thead', 'tfoot', 'tr', 'colgroup'];
  static const _templateParts = {'caption', 'colgroup', 'col', 'tbody', 'tfoot', 'thead', 'tr', 'td', 'th'};

  /// The nearest open element named in [names] before a [boundary]; null
  /// when it is not in scope.
  Element? _inScope(Set<String> names, Set<String> boundary) {
    if (!names.any(open.has)) return null;
    for (var k = open.length - 1; k >= 0; k--) {
      final node = open[k];
      if (node.space == Space.html) {
        if (names.contains(node.localName)) return node;
        if (boundary.contains(node.localName)) return null;
      } else if (_htmlPoint(node) || _mathTextPoint(node)) {
        return null;
      }
    }
    return null;
  }

  bool _onScope(Element target, Set<String> boundary) {
    for (var k = open.length - 1; k >= 0; k--) {
      final node = open[k];
      if (identical(node, target)) return true;
      if (node.space == Space.html && boundary.contains(node.localName)) return false;
    }
    return false;
  }

  bool _isSpecial(Element e) =>
      e.space == Space.html ? _special.contains(e.localName) : _htmlPoint(e) || _mathTextPoint(e);

  static bool _htmlPoint(Element e) => switch (e.space) {
    Space.svg => e.localName == 'foreignObject' || e.localName == 'desc' || e.localName == 'title',
    Space.math =>
      e.localName == 'annotation-xml' &&
          const {'text/html', 'application/xhtml+xml'}.contains((e.attributes['encoding'] ?? '').toLowerCase()),
    Space.html => false,
  };

  static bool _mathTextPoint(Element e) =>
      e.space == Space.math && const {'mi', 'mo', 'mn', 'ms', 'mtext'}.contains(e.localName);

  /// A `<template>` open inside `<head>`: its content stays in it.
  bool get _inHeadTemplate => phase == _Phase.inHead && current != head && open.any((e) => e.localName == 'template');

  /// The table insertion mode the open elements imply, as the spec resets
  /// it: the nearest `tr`, section (`tbody`…), `colgroup` or `table`; null
  /// when a cell, a caption or the body comes first (body rules).
  String? _tableMode() {
    // Nothing table-like open (a template may hold rows without a table).
    if (!_tableish.any(open.has)) return null;
    for (var k = open.length - 1; k >= 0; k--) {
      final e = open[k];
      if (e.space != Space.html) continue;
      switch (e.localName) {
        case 'td' || 'th' || 'caption' || 'body' || 'html' || 'template':
          return null;
        case 'tr' || 'tbody' || 'thead' || 'tfoot' || 'colgroup' || 'table':
          return e.localName;
      }
    }
    return null;
  }

  Element? _openSelect() {
    for (var k = open.length - 1; k >= 0; k--) {
      final node = open[k];
      if (node.space != Space.html) return null;
      if (node.localName == 'select') return node;
      if (node.localName != 'option' && node.localName != 'optgroup') return null;
    }
    return null;
  }

  /// Whether [select] sits in a table (so table tags close it).
  bool _inTable(Element select) {
    for (var k = open.indexOf(select) - 1; k >= 0; k--) {
      final n = open[k].localName;
      if (n == 'table' || n == 'td' || n == 'th' || n == 'tr' || n == 'caption' || _tableSections.contains(n)) {
        return true;
      }
    }
    return false;
  }

  void _popUntil(Element el) {
    while (open.isNotEmpty) {
      if (identical(open.removeLast(), el)) return;
    }
  }

  void _clearTo(Set<String> names) {
    while (open.length > 1 && !(names.contains(current.localName) && current.space == Space.html)) {
      open.removeLast();
    }
  }

  void _generateImplied({String? except}) {
    while (open.length > 1 &&
        current.space == Space.html &&
        _impliedEnd.contains(current.localName) &&
        current.localName != except) {
      open.removeLast();
    }
  }

  void _closeP() {
    final p = _inScope(const {'p'}, _buttonScope);
    if (p == null) return;
    _generateImplied(except: 'p');
    _popUntil(p);
  }

  void _closeCell() {
    _generateImplied();
    while (open.length > 1) {
      final e = open.removeLast();
      if (e.space == Space.html && (e.localName == 'td' || e.localName == 'th')) break;
    }
    _clearToMarker();
  }

  // ---- formatting ----

  Element? _formattingAfterMarker(String name) {
    for (var k = formatting.length - 1; k >= 0; k--) {
      final e = formatting[k];
      if (e == null) return null;
      if (e.localName == name) return e;
    }
    return null;
  }

  void _pushFormatting(Element el) {
    var same = 0, earliest = -1;
    for (var k = formatting.length - 1; k >= 0; k--) {
      final e = formatting[k];
      if (e == null) break;
      if (e.localName == el.localName && _sameAttrs(e, el)) {
        same++;
        earliest = k;
      }
    }
    if (same >= 3) formatting.removeAt(earliest);
    formatting.add(el);
  }

  static bool _sameAttrs(Element a, Element b) {
    if (a.attributes.length != b.attributes.length) return false;
    for (final e in a.attributes.entries) {
      if (b.attributes[e.key] != e.value) return false;
    }
    return true;
  }

  void _clearToMarker() {
    while (formatting.isNotEmpty) {
      if (formatting.removeLast() == null) return;
    }
  }

  void _reconstruct() {
    if (formatting.isEmpty) return;
    final last = formatting.last;
    if (last == null || open.contains(last)) return;
    var k = formatting.length - 1;
    while (k > 0) {
      final e = formatting[k - 1];
      if (e == null || open.contains(e)) break;
      k--;
    }
    for (; k < formatting.length; k++) {
      final e = formatting[k]!;
      formatting[k] = _insert(e.localName, Map.of(e.attributes));
    }
  }

  /// The adoption agency: close misnested formatting such as
  /// `<b>1<p>2</b>3</p>` the way browsers do.
  void _adoption(String subject) {
    if (current.localName == subject && current.space == Space.html && !formatting.contains(current)) {
      open.removeLast();
      return;
    }
    for (var outer = 0; outer < 8; outer++) {
      final fe = _formattingAfterMarker(subject);
      if (fe == null) return _anyOtherEnd(subject);
      final feAt = open.indexOf(fe);
      if (feAt < 0) {
        formatting.remove(fe);
        return;
      }
      if (!_onScope(fe, _scopeHtml)) return;
      Element? furthest;
      for (var k = feAt + 1; k < open.length; k++) {
        if (_isSpecial(open[k])) {
          furthest = open[k];
          break;
        }
      }
      if (furthest == null) {
        _popUntil(fe);
        formatting.remove(fe);
        return;
      }
      final common = open[feAt - 1];
      var bookmark = formatting.indexOf(fe);
      var node = furthest, last = furthest;
      var nodeAt = open.indexOf(furthest);
      for (var inner = 1; ; inner++) {
        nodeAt--;
        node = open[nodeAt];
        if (identical(node, fe)) break;
        if (inner > 3 && formatting.contains(node)) {
          final at = formatting.indexOf(node);
          if (at < bookmark) bookmark--;
          formatting.removeAt(at);
        }
        if (!formatting.contains(node)) {
          open.removeAt(nodeAt);
          continue;
        }
        final copy = Element(node.localName, Map.of(node.attributes), node.space);
        formatting[formatting.indexOf(node)] = copy;
        open[nodeAt] = copy;
        node = copy;
        if (identical(last, furthest)) bookmark = formatting.indexOf(copy) + 1;
        last.remove();
        node.append(last);
        last = node;
      }
      last.remove();
      if (_tableContext.contains(common.localName) && common.space == Space.html) {
        _place(last, common);
      } else {
        common.append(last);
      }
      final copy = Element(fe.localName, Map.of(fe.attributes), fe.space);
      // Move every child at once: one remove() each was O(n²) (a <b><div>
      // holding 100,000 <br> took 15 s).
      for (final child in furthest.nodes) {
        child.parent = copy;
      }
      copy.nodes.addAll(furthest.nodes);
      furthest.nodes.clear();
      copy.edits++;
      furthest.edits++;
      furthest.append(copy);
      final feIndex = formatting.indexOf(fe);
      if (feIndex < bookmark) bookmark--;
      formatting.removeAt(feIndex);
      formatting.insert(bookmark.clamp(0, formatting.length), copy);
      open.remove(fe);
      open.insert(open.indexOf(furthest) + 1, copy);
    }
  }
}

/// The stack of open elements, counting the HTML ones by name, so asking
/// whether an element that is not open is in scope costs O(1) instead of a
/// walk to the root (every `<div>` asks for a `<p>`).
final class _Open extends ListBase<Element> {
  final _items = <Element>[];
  final _count = <String, int>{};

  /// The same elements, for an O(1) [contains]: formatting reconstruction
  /// asks per token, and a hostile page nests 100,000 deep.
  final _set = HashSet<Element>.identity();

  bool has(String name) => (_count[name] ?? 0) > 0;

  void _in(Element e) {
    _set.add(e);
    if (e.space == Space.html) _count[e.localName] = (_count[e.localName] ?? 0) + 1;
  }

  void _out(Element e) {
    _set.remove(e);
    if (e.space == Space.html) _count[e.localName] = _count[e.localName]! - 1;
  }

  @override
  int get length => _items.length;

  @override
  set length(int n) => throw UnsupportedError('length');

  @override
  Element operator [](int i) => _items[i];

  @override
  void operator []=(int i, Element e) {
    _out(_items[i]);
    _items[i] = e;
    _in(e);
  }

  @override
  void add(Element e) {
    _items.add(e);
    _in(e);
  }

  @override
  void insert(int i, Element e) {
    _items.insert(i, e);
    _in(e);
  }

  @override
  Element removeAt(int i) {
    final e = _items.removeAt(i);
    _out(e);
    return e;
  }

  @override
  Element removeLast() {
    final e = _items.removeLast();
    _out(e);
    return e;
  }

  @override
  bool remove(Object? e) {
    final i = _items.indexOf(e as Element);
    if (i < 0) return false;
    removeAt(i);
    return true;
  }

  @override
  int indexOf(Object? e, [int start = 0]) => _items.indexOf(e as Element, start);

  @override
  bool contains(Object? e) => _set.contains(e);
}

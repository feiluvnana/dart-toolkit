part of '../../markup.dart';

// What the HTML and the XML parser share: how names, attributes and text runs are read, the
// elements the serializer treats specially, and numeric and XML references. The HTML parser,
// in `html.dart`, reaches it through [MarkupInternals].

/// Elements with no content and no end tag.
const _voidElements = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr', //
  'basefont', 'bgsound', 'frame', 'keygen', 'command',
};

/// Elements whose content is raw text up to their end tag, entities left alone.
const _rawTextElements = {'script', 'style', 'xmp', 'iframe', 'noembed', 'noframes'};

/// SVG's mixed-case names by their lowercase, restored inside `<svg>` as a browser does.
final _svgTags = {
  for (final n in const [
    'altGlyph', 'altGlyphDef', 'altGlyphItem', 'animateColor', 'animateMotion', 'animateTransform', 'clipPath', //
    'feBlend', 'feColorMatrix', 'feComponentTransfer', 'feComposite', 'feConvolveMatrix', 'feDiffuseLighting',
    'feDisplacementMap', 'feDistantLight', 'feDropShadow', 'feFlood', 'feFuncA', 'feFuncB', 'feFuncG', 'feFuncR',
    'feGaussianBlur', 'feImage', 'feMerge', 'feMergeNode', 'feMorphology', 'feOffset', 'fePointLight',
    'feSpecularLighting', 'feSpotLight', 'feTile', 'feTurbulence', 'foreignObject', 'glyphRef', 'linearGradient',
    'radialGradient', 'textPath',
  ])
    n.toLowerCase(): n,
};

final _svgAttributes = {
  for (final n in const [
    'attributeName', 'attributeType', 'baseFrequency', 'baseProfile', 'calcMode', 'clipPathUnits', //
    'diffuseConstant', 'edgeMode', 'filterUnits', 'glyphRef', 'gradientTransform', 'gradientUnits', 'kernelMatrix',
    'kernelUnitLength', 'keyPoints', 'keySplines', 'keyTimes', 'lengthAdjust', 'limitingConeAngle', 'markerHeight',
    'markerUnits', 'markerWidth', 'maskContentUnits', 'maskUnits', 'numOctaves', 'pathLength',
    'patternContentUnits', 'patternTransform', 'patternUnits', 'pointsAtX', 'pointsAtY', 'pointsAtZ',
    'preserveAlpha', 'preserveAspectRatio', 'primitiveUnits', 'refX', 'refY', 'repeatCount', 'repeatDur',
    'requiredExtensions', 'requiredFeatures', 'specularConstant', 'specularExponent', 'spreadMethod',
    'startOffset', 'stdDeviation', 'stitchTiles', 'surfaceScale', 'systemLanguage', 'tableValues', 'targetX',
    'targetY', 'textLength', 'viewBox', 'viewTarget', 'xChannelSelector', 'yChannelSelector', 'zoomAndPan',
  ])
    n.toLowerCase(): n,
};

/// Gathers adjacent text runs (`a < b` is three) into one [Text] when something else arrives,
/// rather than appending run by run, which is quadratic. Not API: the parsers' own.
final class TextRun {
  Element? _target;

  /// The first run on its own: most text is one run, and needs no buffer.
  String? _first;
  final StringBuffer _buffer = StringBuffer();

  void add(Element target, String data) {
    if (!identical(target, _target)) {
      flush();
      _target = target;
    }
    if (_first == null) {
      _first = data;
    } else {
      if (_buffer.isEmpty) _buffer.write(_first);
      _buffer.write(data);
    }
  }

  void flush() {
    final target = _target;
    var data = _first;
    _target = _first = null;
    if (target == null || data == null) return;
    if (_buffer.isNotEmpty) {
      data = _buffer.toString();
      _buffer.clear();
    }
    if (data.isEmpty) return;
    final nodes = target._nodes;
    if (nodes.lastOrNull case final Text last) {
      nodes.last = Text(last.data + data)
        .._parent = target
        .._slot = nodes.length - 1;
    } else {
      nodes.add(
        Text(data)
          .._parent = target
          .._slot = nodes.length,
      );
    }
  }
}

/// The names one parse has seen, each kept once. Not API: the parsers' own.
final class Names {
  final Map<String, String> _seen = {};

  /// [raw] as it is.
  String of(String raw) => _seen[raw] ??= raw;

  /// [raw] lowercased; a spelling seen before costs no new string.
  String lower(String raw) => _seen[raw] ??= of(raw.toLowerCase());
}

/// Where a tag name starting at [i] ends: at whitespace, `>` or `/`.
int _nameEnd(String src, int i) {
  for (int c; i < src.length && !_isSpace(c = src.codeUnitAt(i)) && c != 0x3e && c != 0x2f; i++) {}
  return i;
}

/// Reads a start tag's attributes from [i] into [into] as names and values alternating (first
/// of a name wins, values decoded, names from [names]) and returns where the tag ends, negated
/// after `/>` — an int, as a record cost 8% of the parse. HTML lowercases names; [decode] reads
/// the references in a value.
int _scanAttributes(
  String src,
  int i,
  List<String> into,
  Names names, {
  required bool html,
  required String Function(String value) decode,
}) {
  while (true) {
    while (i < src.length && _isSpace(src.codeUnitAt(i))) {
      i++;
    }
    if (i >= src.length) return i;
    final c = src.codeUnitAt(i);
    if (c == 0x3e) return i + 1;
    if (c == 0x2f) {
      // `/` — the self-closing marker, or noise.
      if (++i < src.length && src.codeUnitAt(i) == 0x3e) return -(i + 1);
      continue;
    }
    final nameStart = i++;
    while (i < src.length) {
      final d = src.codeUnitAt(i);
      if (_isSpace(d) || d == 0x3d || d == 0x3e || d == 0x2f) {
        break;
      }
      i++;
    }
    final attribute = html ? names.lower(src.substring(nameStart, i)) : names.of(src.substring(nameStart, i));
    while (i < src.length && _isSpace(src.codeUnitAt(i))) {
      i++;
    }
    var value = '';
    if (i < src.length && src.codeUnitAt(i) == 0x3d) {
      i++;
      while (i < src.length && _isSpace(src.codeUnitAt(i))) {
        i++;
      }
      if (i < src.length) {
        final q = src.codeUnitAt(i);
        final quoted = q == 0x22 || q == 0x27;
        final start = quoted ? i + 1 : i;
        if (quoted) {
          i = src.indexOf(q == 0x22 ? '"' : "'", start);
          if (i == -1) i = src.length;
        } else {
          while (i < src.length && !_isSpace(src.codeUnitAt(i)) && src.codeUnitAt(i) != 0x3e) {
            i++;
          }
        }
        value = src.substring(start, i);
        if (quoted && i < src.length) i++;
      }
    }
    var seen = false;
    for (var k = 0; k < into.length && !seen; k += 2) {
      seen = identical(into[k], attribute);
    }
    if (!seen) {
      into
        ..add(attribute)
        ..add(decode(value));
    }
  }
}

/// The references in [text] decoded by [reference], which reads the one after the `&` at
/// [start] and answers its text and where the text resumes, or `(null, _)` when the `&` is
/// literal. Runs between references are copied whole: 4× faster than walking code units.
String _decodeReferences(String text, (String?, int) Function(String text, int start) reference) {
  var amp = text.indexOf('&');
  if (amp == -1) return text;
  final sb = StringBuffer();
  var last = 0;
  while (amp != -1) {
    final (decoded, end) = reference(text, amp + 1);
    if (decoded == null) {
      amp = text.indexOf('&', amp + 1);
      continue;
    }
    sb
      ..write(text.substring(last, amp))
      ..write(decoded);
    last = end;
    amp = text.indexOf('&', last);
  }
  sb.write(text.substring(last));
  return sb.toString();
}

/// The numeric reference after the `&#` at [start] - 1 (`text[start]` is `#`): decimal or hex,
/// and a code point no character has reads as U+FFFD. HTML takes it without a `;` and reads
/// 0x80–0x9F through [windows1252]; XML ([windows1252] `null`) wants the `;`.
(String?, int) _numericReference(String text, int start, Map<int, int>? windows1252) {
  var i = start + 1;
  final hex = i < text.length && (text.codeUnitAt(i) | 0x20) == 0x78;
  if (hex) i++;
  final from = i;
  var code = 0;
  while (i < text.length) {
    final d = _digit(text.codeUnitAt(i), hex);
    if (d == -1) break;
    if (code <= 0x10ffff) code = code * (hex ? 16 : 10) + d;
    i++;
  }
  if (i == from) return (null, 0);
  final semicolon = i < text.length && text.codeUnitAt(i) == 0x3b;
  if (semicolon) i++;
  if (windows1252 == null && !semicolon) return (null, 0);
  if (code == 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return ('\u{fffd}', i);
  return (String.fromCharCode(windows1252?[code] ?? code), i);
}

const _xmlEntities = {'lt': '<', 'gt': '>', 'amp': '&', 'quot': '"', 'apos': "'"};

/// XML's five predefined references and numeric ones, each with its `;`.
String _decodeXmlEntities(String text) => _decodeReferences(text, _xmlReference);

(String?, int) _xmlReference(String text, int start) {
  if (start < text.length && text.codeUnitAt(start) == 0x23) return _numericReference(text, start, null);
  var i = start;
  while (i < text.length && _isAlnum(text.codeUnitAt(i))) {
    i++;
  }
  if (i == start || i >= text.length || text.codeUnitAt(i) != 0x3b) return (null, 0);
  final full = _xmlEntities[text.substring(start, i)];
  return full == null ? (null, 0) : (full, i + 1);
}

int _digit(int c, bool hex) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (!hex) return -1;
  final l = c | 0x20;
  return l >= 0x61 && l <= 0x66 ? l - 0x57 : -1;
}

bool _isAlnum(int c) => (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);

int _toLower(int c) => (c >= 0x41 && c <= 0x5a) ? c + 0x20 : c;

bool _isAlpha(int c) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c;

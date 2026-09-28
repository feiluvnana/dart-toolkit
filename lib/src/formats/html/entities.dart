// The HTML 4 named character references (252), `apos`, the six upper-case spellings HTML 5
// keeps for compatibility, and HTML 5's punctuation and common symbols (`&lpar;`, `&check;`).
// Numeric references are decoded arithmetically. The long tail of HTML 5 names is not here on
// purpose: this table covers what pages use, and the full list is 2 231 entries of startup
// cost.

part of '../../../formats.dart';

const Map<String, String> _entities = {
  'AElig': '\u{c6}',
  'Aacute': '\u{c1}',
  'Acirc': '\u{c2}',
  'Agrave': '\u{c0}',
  'Alpha': '\u{391}',
  'Aring': '\u{c5}',
  'Atilde': '\u{c3}',
  'Auml': '\u{c4}',
  'Beta': '\u{392}',
  'Ccedil': '\u{c7}',
  'Chi': '\u{3a7}',
  'Dagger': '\u{2021}',
  'Delta': '\u{394}',
  'ETH': '\u{d0}',
  'Eacute': '\u{c9}',
  'Ecirc': '\u{ca}',
  'Egrave': '\u{c8}',
  'Epsilon': '\u{395}',
  'Eta': '\u{397}',
  'Euml': '\u{cb}',
  'Gamma': '\u{393}',
  'Iacute': '\u{cd}',
  'Icirc': '\u{ce}',
  'Igrave': '\u{cc}',
  'Iota': '\u{399}',
  'Iuml': '\u{cf}',
  'Kappa': '\u{39a}',
  'Lambda': '\u{39b}',
  'Mu': '\u{39c}',
  'Ntilde': '\u{d1}',
  'Nu': '\u{39d}',
  'OElig': '\u{152}',
  'Oacute': '\u{d3}',
  'Ocirc': '\u{d4}',
  'Ograve': '\u{d2}',
  'Omega': '\u{3a9}',
  'Omicron': '\u{39f}',
  'Oslash': '\u{d8}',
  'Otilde': '\u{d5}',
  'Ouml': '\u{d6}',
  'Phi': '\u{3a6}',
  'Pi': '\u{3a0}',
  'Prime': '\u{2033}',
  'Psi': '\u{3a8}',
  'Rho': '\u{3a1}',
  'Scaron': '\u{160}',
  'Sigma': '\u{3a3}',
  'THORN': '\u{de}',
  'Tau': '\u{3a4}',
  'Theta': '\u{398}',
  'Uacute': '\u{da}',
  'Ucirc': '\u{db}',
  'Ugrave': '\u{d9}',
  'Upsilon': '\u{3a5}',
  'Uuml': '\u{dc}',
  'Xi': '\u{39e}',
  'Yacute': '\u{dd}',
  'Yuml': '\u{178}',
  'Zeta': '\u{396}',
  'aacute': '\u{e1}',
  'acirc': '\u{e2}',
  'acute': '\u{b4}',
  'aelig': '\u{e6}',
  'agrave': '\u{e0}',
  'alefsym': '\u{2135}',
  'alpha': '\u{3b1}',
  'amp': '\u{26}',
  'and': '\u{2227}',
  'ang': '\u{2220}',
  'aring': '\u{e5}',
  'asymp': '\u{2248}',
  'atilde': '\u{e3}',
  'auml': '\u{e4}',
  'bdquo': '\u{201e}',
  'beta': '\u{3b2}',
  'brvbar': '\u{a6}',
  'bull': '\u{2022}',
  'cap': '\u{2229}',
  'ccedil': '\u{e7}',
  'cedil': '\u{b8}',
  'cent': '\u{a2}',
  'chi': '\u{3c7}',
  'circ': '\u{2c6}',
  'clubs': '\u{2663}',
  'cong': '\u{2245}',
  'copy': '\u{a9}',
  'crarr': '\u{21b5}',
  'cup': '\u{222a}',
  'curren': '\u{a4}',
  'dArr': '\u{21d3}',
  'dagger': '\u{2020}',
  'darr': '\u{2193}',
  'deg': '\u{b0}',
  'delta': '\u{3b4}',
  'diams': '\u{2666}',
  'divide': '\u{f7}',
  'eacute': '\u{e9}',
  'ecirc': '\u{ea}',
  'egrave': '\u{e8}',
  'empty': '\u{2205}',
  'emsp': '\u{2003}',
  'ensp': '\u{2002}',
  'epsilon': '\u{3b5}',
  'equiv': '\u{2261}',
  'eta': '\u{3b7}',
  'eth': '\u{f0}',
  'euml': '\u{eb}',
  'euro': '\u{20ac}',
  'exist': '\u{2203}',
  'fnof': '\u{192}',
  'forall': '\u{2200}',
  'frac12': '\u{bd}',
  'frac14': '\u{bc}',
  'frac34': '\u{be}',
  'frasl': '\u{2044}',
  'gamma': '\u{3b3}',
  'ge': '\u{2265}',
  'gt': '\u{3e}',
  'hArr': '\u{21d4}',
  'harr': '\u{2194}',
  'hearts': '\u{2665}',
  'hellip': '\u{2026}',
  'iacute': '\u{ed}',
  'icirc': '\u{ee}',
  'iexcl': '\u{a1}',
  'igrave': '\u{ec}',
  'image': '\u{2111}',
  'infin': '\u{221e}',
  'int': '\u{222b}',
  'iota': '\u{3b9}',
  'iquest': '\u{bf}',
  'isin': '\u{2208}',
  'iuml': '\u{ef}',
  'kappa': '\u{3ba}',
  'lArr': '\u{21d0}',
  'lambda': '\u{3bb}',
  'lang': '\u{2329}',
  'laquo': '\u{ab}',
  'larr': '\u{2190}',
  'lceil': '\u{2308}',
  'ldquo': '\u{201c}',
  'le': '\u{2264}',
  'lfloor': '\u{230a}',
  'lowast': '\u{2217}',
  'loz': '\u{25ca}',
  'lrm': '\u{200e}',
  'lsaquo': '\u{2039}',
  'lsquo': '\u{2018}',
  'lt': '\u{3c}',
  'macr': '\u{af}',
  'mdash': '\u{2014}',
  'micro': '\u{b5}',
  'middot': '\u{b7}',
  'minus': '\u{2212}',
  'mu': '\u{3bc}',
  'nabla': '\u{2207}',
  'nbsp': '\u{a0}',
  'ndash': '\u{2013}',
  'ne': '\u{2260}',
  'ni': '\u{220b}',
  'not': '\u{ac}',
  'notin': '\u{2209}',
  'nsub': '\u{2284}',
  'ntilde': '\u{f1}',
  'nu': '\u{3bd}',
  'oacute': '\u{f3}',
  'ocirc': '\u{f4}',
  'oelig': '\u{153}',
  'ograve': '\u{f2}',
  'oline': '\u{203e}',
  'omega': '\u{3c9}',
  'omicron': '\u{3bf}',
  'oplus': '\u{2295}',
  'or': '\u{2228}',
  'ordf': '\u{aa}',
  'ordm': '\u{ba}',
  'oslash': '\u{f8}',
  'otilde': '\u{f5}',
  'otimes': '\u{2297}',
  'ouml': '\u{f6}',
  'para': '\u{b6}',
  'part': '\u{2202}',
  'permil': '\u{2030}',
  'perp': '\u{22a5}',
  'phi': '\u{3c6}',
  'pi': '\u{3c0}',
  'piv': '\u{3d6}',
  'plusmn': '\u{b1}',
  'pound': '\u{a3}',
  'prime': '\u{2032}',
  'prod': '\u{220f}',
  'prop': '\u{221d}',
  'psi': '\u{3c8}',
  'quot': '\u{22}',
  'rArr': '\u{21d2}',
  'radic': '\u{221a}',
  'rang': '\u{232a}',
  'raquo': '\u{bb}',
  'rarr': '\u{2192}',
  'rceil': '\u{2309}',
  'rdquo': '\u{201d}',
  'real': '\u{211c}',
  'reg': '\u{ae}',
  'rfloor': '\u{230b}',
  'rho': '\u{3c1}',
  'rlm': '\u{200f}',
  'rsaquo': '\u{203a}',
  'rsquo': '\u{2019}',
  'sbquo': '\u{201a}',
  'scaron': '\u{161}',
  'sdot': '\u{22c5}',
  'sect': '\u{a7}',
  'shy': '\u{ad}',
  'sigma': '\u{3c3}',
  'sigmaf': '\u{3c2}',
  'sim': '\u{223c}',
  'spades': '\u{2660}',
  'sub': '\u{2282}',
  'sube': '\u{2286}',
  'sum': '\u{2211}',
  'sup': '\u{2283}',
  'sup1': '\u{b9}',
  'sup2': '\u{b2}',
  'sup3': '\u{b3}',
  'supe': '\u{2287}',
  'szlig': '\u{df}',
  'tau': '\u{3c4}',
  'there4': '\u{2234}',
  'theta': '\u{3b8}',
  'thetasym': '\u{3d1}',
  'thinsp': '\u{2009}',
  'thorn': '\u{fe}',
  'tilde': '\u{2dc}',
  'times': '\u{d7}',
  'trade': '\u{2122}',
  'uArr': '\u{21d1}',
  'uacute': '\u{fa}',
  'uarr': '\u{2191}',
  'ucirc': '\u{fb}',
  'ugrave': '\u{f9}',
  'uml': '\u{a8}',
  'upsih': '\u{3d2}',
  'upsilon': '\u{3c5}',
  'uuml': '\u{fc}',
  'weierp': '\u{2118}',
  'xi': '\u{3be}',
  'yacute': '\u{fd}',
  'yen': '\u{a5}',
  'yuml': '\u{ff}',
  'zeta': '\u{3b6}',
  'zwj': '\u{200d}',
  'zwnj': '\u{200c}',
  'apos': '\u{27}',
  'AMP': '&',
  'COPY': '\u{a9}',
  'GT': '>',
  'LT': '<',
  'QUOT': '"',
  'REG': '\u{ae}',
  // HTML 5's punctuation and the symbols pages actually write.
  'Tab': '\t',
  'NewLine': '\n',
  'excl': '!',
  'num': '#',
  'dollar': r'$',
  'percnt': '%',
  'lpar': '(',
  'rpar': ')',
  'ast': '*',
  'plus': '+',
  'comma': ',',
  'period': '.',
  'sol': '/',
  'colon': ':',
  'semi': ';',
  'equals': '=',
  'quest': '?',
  'commat': '@',
  'lsqb': '[',
  'lbrack': '[',
  'bsol': r'\',
  'rsqb': ']',
  'rbrack': ']',
  'Hat': '^',
  'lowbar': '_',
  'UnderBar': '_',
  'grave': '`',
  'lcub': '{',
  'lbrace': '{',
  'verbar': '|',
  'vert': '|',
  'rcub': '}',
  'rbrace': '}',
  'hyphen': '\u{2010}',
  'dash': '\u{2010}',
  'hairsp': '\u{200a}',
  'ZeroWidthSpace': '\u{200b}',
  'NoBreak': '\u{2060}',
  'half': '\u{bd}',
  'frac13': '\u{2153}',
  'frac23': '\u{2154}',
  'TRADE': '\u{2122}',
  'check': '\u{2713}',
  'checkmark': '\u{2713}',
  'cross': '\u{2717}',
  'star': '\u{2606}',
  'starf': '\u{2605}',
  'phone': '\u{260e}',
  'female': '\u{2640}',
  'male': '\u{2642}',
  'sung': '\u{266a}',
};

/// The names HTML 5 still decodes without a `;` — the Latin-1 set pages wrote before the
/// semicolon was enforced. Anything else needs its `;`, which is what keeps `?a=1&lang=en`
/// a query string rather than `?a=1〈=en`.
const _legacyEntities = {
  'AElig', 'AMP', 'Aacute', 'Acirc', 'Agrave', 'Aring', 'Atilde', 'Auml', 'COPY', 'Ccedil', 'ETH', 'Eacute', //
  'Ecirc', 'Egrave', 'Euml', 'GT', 'Iacute', 'Icirc', 'Igrave', 'Iuml', 'LT', 'Ntilde', 'Oacute', 'Ocirc',
  'Ograve', 'Oslash', 'Otilde', 'Ouml', 'QUOT', 'REG', 'THORN', 'Uacute', 'Ucirc', 'Ugrave', 'Uuml', 'Yacute',
  'aacute', 'acirc', 'acute', 'aelig', 'agrave', 'amp', 'aring', 'atilde', 'auml', 'brvbar', 'ccedil', 'cedil',
  'cent', 'copy', 'curren', 'deg', 'divide', 'eacute', 'ecirc', 'egrave', 'eth', 'euml', 'frac12', 'frac14',
  'frac34', 'gt', 'iacute', 'icirc', 'iexcl', 'igrave', 'iquest', 'iuml', 'laquo', 'lt', 'macr', 'micro',
  'middot', 'nbsp', 'not', 'ntilde', 'oacute', 'ocirc', 'ograve', 'ordf', 'ordm', 'oslash', 'otilde', 'ouml',
  'para', 'plusmn', 'pound', 'quot', 'raquo', 'reg', 'sect', 'shy', 'sup1', 'sup2', 'sup3', 'szlig', 'thorn',
  'times', 'uacute', 'ucirc', 'ugrave', 'uml', 'uuml', 'yacute', 'yen', 'yuml',
};

/// What a numeric reference to 0x80–0x9F means: the Windows-1252 character a page with
/// that byte meant, as every browser reads it. The five holes in that code page are absent.
const _windows1252 = <int, int>{
  0x80: 0x20ac, 0x82: 0x201a, 0x83: 0x0192, 0x84: 0x201e, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, //
  0x88: 0x02c6, 0x89: 0x2030, 0x8a: 0x0160, 0x8b: 0x2039, 0x8c: 0x0152, 0x8e: 0x017d, 0x91: 0x2018,
  0x92: 0x2019, 0x93: 0x201c, 0x94: 0x201d, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02dc,
  0x99: 0x2122, 0x9a: 0x0161, 0x9b: 0x203a, 0x9c: 0x0153, 0x9e: 0x017e, 0x9f: 0x0178,
};

/// Decodes `&amp;`, `&#38;`, `&#x26;` and the HTML 4 named references in [text], as HTML 5
/// decodes text: a name without its `;` is decoded only when it is one of the legacy names.
String decodeEntities(String text) => _decodeEntities(text, _References.text);

/// How references read where they are found.
enum _References {
  /// HTML text: see [decodeEntities].
  text,

  /// An HTML attribute value: as text, except that a legacy name without its `;` stays
  /// literal before a letter, digit or `=` — there it is a query parameter (`&copy=2`)
  /// far more often than a character.
  attribute,

  /// XML: the five predefined names and numeric references, each with its `;`, and any
  /// other `&` as written.
  xml,
}

const _xmlEntities = {'lt': '<', 'gt': '>', 'amp': '&', 'quot': '"', 'apos': "'"};

String _decodeEntities(String text, _References mode) {
  var amp = text.indexOf('&');
  if (amp == -1) return text;
  // The run between two references is copied in one go. Walking it code unit at a time
  // costs about four times as much, and most text has far more prose than entities.
  final sb = StringBuffer();
  var last = 0;
  while (amp != -1) {
    final (decoded, end) = _reference(text, amp + 1, mode);
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

/// The reference starting after the `&` at [start]: what it decodes to and where the text
/// after it resumes, or `(null, _)` when the `&` is literal.
///
/// Scans only as far as a reference could reach, never to the next `;`: looking for that
/// from every `&` made a document with many bare ampersands quadratic — 8.9 s for 240 KB.
(String?, int) _reference(String text, int start, _References mode) {
  final xml = mode == _References.xml;
  var i = start;
  if (i < text.length && text.codeUnitAt(i) == 0x23) {
    // #: decimal or hex, `;` optional, and a code point no character has reads as U+FFFD.
    i++;
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
    if (xml && !semicolon) return (null, 0);
    if (code == 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return ('\u{fffd}', i);
    return (String.fromCharCode((xml ? null : _windows1252[code]) ?? code), i);
  }
  while (i < text.length && _isAlnum(text.codeUnitAt(i))) {
    i++;
  }
  if (i == start) return (null, 0);
  if (i < text.length && text.codeUnitAt(i) == 0x3b) {
    final full = (xml ? _xmlEntities : _entities)[text.substring(start, i)];
    if (full != null) return (full, i + 1);
  }
  if (xml) return (null, 0);
  // No `;`, or a name the table does not have: the longest legacy name it starts with.
  for (var end = i - start > 6 ? start + 6 : i; end > start + 1; end--) {
    final name = text.substring(start, end);
    if (!_legacyEntities.contains(name)) continue;
    final literal = mode == _References.attribute && end < text.length && (end < i || text.codeUnitAt(end) == 0x3d);
    return literal ? (null, 0) : (_entities[name], end);
  }
  return (null, 0);
}

int _digit(int c, bool hex) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (!hex) return -1;
  final l = c | 0x20;
  return l >= 0x61 && l <= 0x66 ? l - 0x57 : -1;
}

bool _isAlnum(int c) => (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);

// HTML 5's named references: the ones pages use (HTML 4's, `apos`, the upper-case compatibility
// spellings, common punctuation and symbols) as a map, and the rest in one string searched only
// when the map misses, as 1 800 more map entries cost startup and a string literal does not.

part of '../../html.dart';

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
  'lang': '\u{27e8}',
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
  'rang': '\u{27e9}',
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

/// HTML 5's other named references, each `&name;` then its text, searched by [_moreEntity].
const _moreEntities =
    '&Abreve;\u{102}&Acy;\u{410}&Afr;\u{1d504}&Amacr;\u{100}&And;\u{2a53}&Aogon;\u{104}&Aopf;\u{1d538}&ApplyF'
    'unction;\u{2061}&Ascr;\u{1d49c}&Assign;\u{2254}&Backslash;\u{2216}&Barv;\u{2ae7}&Barwed;\u{2306}&Bcy;'
    '\u{411}&Because;\u{2235}&Bernoullis;\u{212c}&Bfr;\u{1d505}&Bopf;\u{1d539}&Breve;\u{2d8}&Bscr;\u{212c}&Bu'
    'mpeq;\u{224e}&CHcy;\u{427}&Cacute;\u{106}&Cap;\u{22d2}&CapitalDifferentialD;\u{2145}&Cayleys;\u{212d}&Cc'
    'aron;\u{10c}&Ccirc;\u{108}&Cconint;\u{2230}&Cdot;\u{10a}&Cedilla;\u{b8}&CenterDot;\u{b7}&Cfr;\u{212d}&Ci'
    'rcleDot;\u{2299}&CircleMinus;\u{2296}&CirclePlus;\u{2295}&CircleTimes;\u{2297}&ClockwiseContourIntegral;'
    '\u{2232}&CloseCurlyDoubleQuote;\u{201d}&CloseCurlyQuote;\u{2019}&Colon;\u{2237}&Colone;\u{2a74}&Congruen'
    't;\u{2261}&Conint;\u{222f}&ContourIntegral;\u{222e}&Copf;\u{2102}&Coproduct;\u{2210}&CounterClockwiseCon'
    'tourIntegral;\u{2233}&Cross;\u{2a2f}&Cscr;\u{1d49e}&Cup;\u{22d3}&CupCap;\u{224d}&DD;\u{2145}&DDotrahd;'
    '\u{2911}&DJcy;\u{402}&DScy;\u{405}&DZcy;\u{40f}&Darr;\u{21a1}&Dashv;\u{2ae4}&Dcaron;\u{10e}&Dcy;\u{414}&'
    'Del;\u{2207}&Dfr;\u{1d507}&DiacriticalAcute;\u{b4}&DiacriticalDot;\u{2d9}&DiacriticalDoubleAcute;\u{2dd}'
    '&DiacriticalGrave;`&DiacriticalTilde;\u{2dc}&Diamond;\u{22c4}&DifferentialD;\u{2146}&Dopf;\u{1d53b}&Dot;'
    '\u{a8}&DotDot;\u{20dc}&DotEqual;\u{2250}&DoubleContourIntegral;\u{222f}&DoubleDot;\u{a8}&DoubleDownArrow'
    ';\u{21d3}&DoubleLeftArrow;\u{21d0}&DoubleLeftRightArrow;\u{21d4}&DoubleLeftTee;\u{2ae4}&DoubleLongLeftAr'
    'row;\u{27f8}&DoubleLongLeftRightArrow;\u{27fa}&DoubleLongRightArrow;\u{27f9}&DoubleRightArrow;\u{21d2}&D'
    'oubleRightTee;\u{22a8}&DoubleUpArrow;\u{21d1}&DoubleUpDownArrow;\u{21d5}&DoubleVerticalBar;\u{2225}&Down'
    'Arrow;\u{2193}&DownArrowBar;\u{2913}&DownArrowUpArrow;\u{21f5}&DownBreve;\u{311}&DownLeftRightVector;'
    '\u{2950}&DownLeftTeeVector;\u{295e}&DownLeftVector;\u{21bd}&DownLeftVectorBar;\u{2956}&DownRightTeeVecto'
    'r;\u{295f}&DownRightVector;\u{21c1}&DownRightVectorBar;\u{2957}&DownTee;\u{22a4}&DownTeeArrow;\u{21a7}&D'
    'ownarrow;\u{21d3}&Dscr;\u{1d49f}&Dstrok;\u{110}&ENG;\u{14a}&Ecaron;\u{11a}&Ecy;\u{42d}&Edot;\u{116}&Efr;'
    '\u{1d508}&Element;\u{2208}&Emacr;\u{112}&EmptySmallSquare;\u{25fb}&EmptyVerySmallSquare;\u{25ab}&Eogon;'
    '\u{118}&Eopf;\u{1d53c}&Equal;\u{2a75}&EqualTilde;\u{2242}&Equilibrium;\u{21cc}&Escr;\u{2130}&Esim;'
    '\u{2a73}&Exists;\u{2203}&ExponentialE;\u{2147}&Fcy;\u{424}&Ffr;\u{1d509}&FilledSmallSquare;\u{25fc}&Fill'
    'edVerySmallSquare;\u{25aa}&Fopf;\u{1d53d}&ForAll;\u{2200}&Fouriertrf;\u{2131}&Fscr;\u{2131}&GJcy;\u{403}'
    '&Gammad;\u{3dc}&Gbreve;\u{11e}&Gcedil;\u{122}&Gcirc;\u{11c}&Gcy;\u{413}&Gdot;\u{120}&Gfr;\u{1d50a}&Gg;'
    '\u{22d9}&Gopf;\u{1d53e}&GreaterEqual;\u{2265}&GreaterEqualLess;\u{22db}&GreaterFullEqual;\u{2267}&Greate'
    'rGreater;\u{2aa2}&GreaterLess;\u{2277}&GreaterSlantEqual;\u{2a7e}&GreaterTilde;\u{2273}&Gscr;\u{1d4a2}&G'
    't;\u{226b}&HARDcy;\u{42a}&Hacek;\u{2c7}&Hcirc;\u{124}&Hfr;\u{210c}&HilbertSpace;\u{210b}&Hopf;\u{210d}&H'
    'orizontalLine;\u{2500}&Hscr;\u{210b}&Hstrok;\u{126}&HumpDownHump;\u{224e}&HumpEqual;\u{224f}&IEcy;'
    '\u{415}&IJlig;\u{132}&IOcy;\u{401}&Icy;\u{418}&Idot;\u{130}&Ifr;\u{2111}&Im;\u{2111}&Imacr;\u{12a}&Imagi'
    'naryI;\u{2148}&Implies;\u{21d2}&Int;\u{222c}&Integral;\u{222b}&Intersection;\u{22c2}&InvisibleComma;'
    '\u{2063}&InvisibleTimes;\u{2062}&Iogon;\u{12e}&Iopf;\u{1d540}&Iscr;\u{2110}&Itilde;\u{128}&Iukcy;\u{406}'
    '&Jcirc;\u{134}&Jcy;\u{419}&Jfr;\u{1d50d}&Jopf;\u{1d541}&Jscr;\u{1d4a5}&Jsercy;\u{408}&Jukcy;\u{404}&KHcy'
    ';\u{425}&KJcy;\u{40c}&Kcedil;\u{136}&Kcy;\u{41a}&Kfr;\u{1d50e}&Kopf;\u{1d542}&Kscr;\u{1d4a6}&LJcy;'
    '\u{409}&Lacute;\u{139}&Lang;\u{27ea}&Laplacetrf;\u{2112}&Larr;\u{219e}&Lcaron;\u{13d}&Lcedil;\u{13b}&Lcy'
    ';\u{41b}&LeftAngleBracket;\u{27e8}&LeftArrow;\u{2190}&LeftArrowBar;\u{21e4}&LeftArrowRightArrow;\u{21c6}'
    '&LeftCeiling;\u{2308}&LeftDoubleBracket;\u{27e6}&LeftDownTeeVector;\u{2961}&LeftDownVector;\u{21c3}&Left'
    'DownVectorBar;\u{2959}&LeftFloor;\u{230a}&LeftRightArrow;\u{2194}&LeftRightVector;\u{294e}&LeftTee;'
    '\u{22a3}&LeftTeeArrow;\u{21a4}&LeftTeeVector;\u{295a}&LeftTriangle;\u{22b2}&LeftTriangleBar;\u{29cf}&Lef'
    'tTriangleEqual;\u{22b4}&LeftUpDownVector;\u{2951}&LeftUpTeeVector;\u{2960}&LeftUpVector;\u{21bf}&LeftUpV'
    'ectorBar;\u{2958}&LeftVector;\u{21bc}&LeftVectorBar;\u{2952}&Leftarrow;\u{21d0}&Leftrightarrow;\u{21d4}&'
    'LessEqualGreater;\u{22da}&LessFullEqual;\u{2266}&LessGreater;\u{2276}&LessLess;\u{2aa1}&LessSlantEqual;'
    '\u{2a7d}&LessTilde;\u{2272}&Lfr;\u{1d50f}&Ll;\u{22d8}&Lleftarrow;\u{21da}&Lmidot;\u{13f}&LongLeftArrow;'
    '\u{27f5}&LongLeftRightArrow;\u{27f7}&LongRightArrow;\u{27f6}&Longleftarrow;\u{27f8}&Longleftrightarrow;'
    '\u{27fa}&Longrightarrow;\u{27f9}&Lopf;\u{1d543}&LowerLeftArrow;\u{2199}&LowerRightArrow;\u{2198}&Lscr;'
    '\u{2112}&Lsh;\u{21b0}&Lstrok;\u{141}&Lt;\u{226a}&Map;\u{2905}&Mcy;\u{41c}&MediumSpace;\u{205f}&Mellintrf'
    ';\u{2133}&Mfr;\u{1d510}&MinusPlus;\u{2213}&Mopf;\u{1d544}&Mscr;\u{2133}&NJcy;\u{40a}&Nacute;\u{143}&Ncar'
    'on;\u{147}&Ncedil;\u{145}&Ncy;\u{41d}&NegativeMediumSpace;\u{200b}&NegativeThickSpace;\u{200b}&NegativeT'
    'hinSpace;\u{200b}&NegativeVeryThinSpace;\u{200b}&NestedGreaterGreater;\u{226b}&NestedLessLess;\u{226a}&N'
    'fr;\u{1d511}&NonBreakingSpace;\u{a0}&Nopf;\u{2115}&Not;\u{2aec}&NotCongruent;\u{2262}&NotCupCap;\u{226d}'
    '&NotDoubleVerticalBar;\u{2226}&NotElement;\u{2209}&NotEqual;\u{2260}&NotEqualTilde;\u{2242}\u{338}&NotEx'
    'ists;\u{2204}&NotGreater;\u{226f}&NotGreaterEqual;\u{2271}&NotGreaterFullEqual;\u{2267}\u{338}&NotGreate'
    'rGreater;\u{226b}\u{338}&NotGreaterLess;\u{2279}&NotGreaterSlantEqual;\u{2a7e}\u{338}&NotGreaterTilde;'
    '\u{2275}&NotHumpDownHump;\u{224e}\u{338}&NotHumpEqual;\u{224f}\u{338}&NotLeftTriangle;\u{22ea}&NotLeftTr'
    'iangleBar;\u{29cf}\u{338}&NotLeftTriangleEqual;\u{22ec}&NotLess;\u{226e}&NotLessEqual;\u{2270}&NotLessGr'
    'eater;\u{2278}&NotLessLess;\u{226a}\u{338}&NotLessSlantEqual;\u{2a7d}\u{338}&NotLessTilde;\u{2274}&NotNe'
    'stedGreaterGreater;\u{2aa2}\u{338}&NotNestedLessLess;\u{2aa1}\u{338}&NotPrecedes;\u{2280}&NotPrecedesEqu'
    'al;\u{2aaf}\u{338}&NotPrecedesSlantEqual;\u{22e0}&NotReverseElement;\u{220c}&NotRightTriangle;\u{22eb}&N'
    'otRightTriangleBar;\u{29d0}\u{338}&NotRightTriangleEqual;\u{22ed}&NotSquareSubset;\u{228f}\u{338}&NotSqu'
    'areSubsetEqual;\u{22e2}&NotSquareSuperset;\u{2290}\u{338}&NotSquareSupersetEqual;\u{22e3}&NotSubset;'
    '\u{2282}\u{20d2}&NotSubsetEqual;\u{2288}&NotSucceeds;\u{2281}&NotSucceedsEqual;\u{2ab0}\u{338}&NotSuccee'
    'dsSlantEqual;\u{22e1}&NotSucceedsTilde;\u{227f}\u{338}&NotSuperset;\u{2283}\u{20d2}&NotSupersetEqual;'
    '\u{2289}&NotTilde;\u{2241}&NotTildeEqual;\u{2244}&NotTildeFullEqual;\u{2247}&NotTildeTilde;\u{2249}&NotV'
    'erticalBar;\u{2224}&Nscr;\u{1d4a9}&Ocy;\u{41e}&Odblac;\u{150}&Ofr;\u{1d512}&Omacr;\u{14c}&Oopf;\u{1d546}'
    '&OpenCurlyDoubleQuote;\u{201c}&OpenCurlyQuote;\u{2018}&Or;\u{2a54}&Oscr;\u{1d4aa}&Otimes;\u{2a37}&OverBa'
    'r;\u{203e}&OverBrace;\u{23de}&OverBracket;\u{23b4}&OverParenthesis;\u{23dc}&PartialD;\u{2202}&Pcy;'
    '\u{41f}&Pfr;\u{1d513}&PlusMinus;\u{b1}&Poincareplane;\u{210c}&Popf;\u{2119}&Pr;\u{2abb}&Precedes;'
    '\u{227a}&PrecedesEqual;\u{2aaf}&PrecedesSlantEqual;\u{227c}&PrecedesTilde;\u{227e}&Product;\u{220f}&Prop'
    'ortion;\u{2237}&Proportional;\u{221d}&Pscr;\u{1d4ab}&Qfr;\u{1d514}&Qopf;\u{211a}&Qscr;\u{1d4ac}&RBarr;'
    '\u{2910}&Racute;\u{154}&Rang;\u{27eb}&Rarr;\u{21a0}&Rarrtl;\u{2916}&Rcaron;\u{158}&Rcedil;\u{156}&Rcy;'
    '\u{420}&Re;\u{211c}&ReverseElement;\u{220b}&ReverseEquilibrium;\u{21cb}&ReverseUpEquilibrium;\u{296f}&Rf'
    'r;\u{211c}&RightAngleBracket;\u{27e9}&RightArrow;\u{2192}&RightArrowBar;\u{21e5}&RightArrowLeftArrow;'
    '\u{21c4}&RightCeiling;\u{2309}&RightDoubleBracket;\u{27e7}&RightDownTeeVector;\u{295d}&RightDownVector;'
    '\u{21c2}&RightDownVectorBar;\u{2955}&RightFloor;\u{230b}&RightTee;\u{22a2}&RightTeeArrow;\u{21a6}&RightT'
    'eeVector;\u{295b}&RightTriangle;\u{22b3}&RightTriangleBar;\u{29d0}&RightTriangleEqual;\u{22b5}&RightUpDo'
    'wnVector;\u{294f}&RightUpTeeVector;\u{295c}&RightUpVector;\u{21be}&RightUpVectorBar;\u{2954}&RightVector'
    ';\u{21c0}&RightVectorBar;\u{2953}&Rightarrow;\u{21d2}&Ropf;\u{211d}&RoundImplies;\u{2970}&Rrightarrow;'
    '\u{21db}&Rscr;\u{211b}&Rsh;\u{21b1}&RuleDelayed;\u{29f4}&SHCHcy;\u{429}&SHcy;\u{428}&SOFTcy;\u{42c}&Sacu'
    'te;\u{15a}&Sc;\u{2abc}&Scedil;\u{15e}&Scirc;\u{15c}&Scy;\u{421}&Sfr;\u{1d516}&ShortDownArrow;\u{2193}&Sh'
    'ortLeftArrow;\u{2190}&ShortRightArrow;\u{2192}&ShortUpArrow;\u{2191}&SmallCircle;\u{2218}&Sopf;\u{1d54a}'
    '&Sqrt;\u{221a}&Square;\u{25a1}&SquareIntersection;\u{2293}&SquareSubset;\u{228f}&SquareSubsetEqual;'
    '\u{2291}&SquareSuperset;\u{2290}&SquareSupersetEqual;\u{2292}&SquareUnion;\u{2294}&Sscr;\u{1d4ae}&Star;'
    '\u{22c6}&Sub;\u{22d0}&Subset;\u{22d0}&SubsetEqual;\u{2286}&Succeeds;\u{227b}&SucceedsEqual;\u{2ab0}&Succ'
    'eedsSlantEqual;\u{227d}&SucceedsTilde;\u{227f}&SuchThat;\u{220b}&Sum;\u{2211}&Sup;\u{22d1}&Superset;'
    '\u{2283}&SupersetEqual;\u{2287}&Supset;\u{22d1}&TSHcy;\u{40b}&TScy;\u{426}&Tcaron;\u{164}&Tcedil;\u{162}'
    '&Tcy;\u{422}&Tfr;\u{1d517}&Therefore;\u{2234}&ThickSpace;\u{205f}\u{200a}&ThinSpace;\u{2009}&Tilde;'
    '\u{223c}&TildeEqual;\u{2243}&TildeFullEqual;\u{2245}&TildeTilde;\u{2248}&Topf;\u{1d54b}&TripleDot;'
    '\u{20db}&Tscr;\u{1d4af}&Tstrok;\u{166}&Uarr;\u{219f}&Uarrocir;\u{2949}&Ubrcy;\u{40e}&Ubreve;\u{16c}&Ucy;'
    '\u{423}&Udblac;\u{170}&Ufr;\u{1d518}&Umacr;\u{16a}&UnderBrace;\u{23df}&UnderBracket;\u{23b5}&UnderParent'
    'hesis;\u{23dd}&Union;\u{22c3}&UnionPlus;\u{228e}&Uogon;\u{172}&Uopf;\u{1d54c}&UpArrow;\u{2191}&UpArrowBa'
    'r;\u{2912}&UpArrowDownArrow;\u{21c5}&UpDownArrow;\u{2195}&UpEquilibrium;\u{296e}&UpTee;\u{22a5}&UpTeeArr'
    'ow;\u{21a5}&Uparrow;\u{21d1}&Updownarrow;\u{21d5}&UpperLeftArrow;\u{2196}&UpperRightArrow;\u{2197}&Upsi;'
    '\u{3d2}&Uring;\u{16e}&Uscr;\u{1d4b0}&Utilde;\u{168}&VDash;\u{22ab}&Vbar;\u{2aeb}&Vcy;\u{412}&Vdash;'
    '\u{22a9}&Vdashl;\u{2ae6}&Vee;\u{22c1}&Verbar;\u{2016}&Vert;\u{2016}&VerticalBar;\u{2223}&VerticalLine;|&'
    'VerticalSeparator;\u{2758}&VerticalTilde;\u{2240}&VeryThinSpace;\u{200a}&Vfr;\u{1d519}&Vopf;\u{1d54d}&Vs'
    'cr;\u{1d4b1}&Vvdash;\u{22aa}&Wcirc;\u{174}&Wedge;\u{22c0}&Wfr;\u{1d51a}&Wopf;\u{1d54e}&Wscr;\u{1d4b2}&Xf'
    'r;\u{1d51b}&Xopf;\u{1d54f}&Xscr;\u{1d4b3}&YAcy;\u{42f}&YIcy;\u{407}&YUcy;\u{42e}&Ycirc;\u{176}&Ycy;'
    '\u{42b}&Yfr;\u{1d51c}&Yopf;\u{1d550}&Yscr;\u{1d4b4}&ZHcy;\u{416}&Zacute;\u{179}&Zcaron;\u{17d}&Zcy;'
    '\u{417}&Zdot;\u{17b}&Zfr;\u{2128}&Zopf;\u{2124}&Zscr;\u{1d4b5}&abreve;\u{103}&ac;\u{223e}&acE;\u{223e}'
    '\u{333}&acd;\u{223f}&acy;\u{430}&af;\u{2061}&afr;\u{1d51e}&aleph;\u{2135}&amacr;\u{101}&amalg;\u{2a3f}&a'
    'ndand;\u{2a55}&andd;\u{2a5c}&andslope;\u{2a58}&andv;\u{2a5a}&ange;\u{29a4}&angle;\u{2220}&angmsd;'
    '\u{2221}&angmsdaa;\u{29a8}&angmsdab;\u{29a9}&angmsdac;\u{29aa}&angmsdad;\u{29ab}&angmsdae;\u{29ac}&angms'
    'daf;\u{29ad}&angmsdag;\u{29ae}&angmsdah;\u{29af}&angrt;\u{221f}&angrtvb;\u{22be}&angrtvbd;\u{299d}&angsp'
    'h;\u{2222}&angst;\u{c5}&angzarr;\u{237c}&aogon;\u{105}&aopf;\u{1d552}&ap;\u{2248}&apE;\u{2a70}&apacir;'
    '\u{2a6f}&ape;\u{224a}&apid;\u{224b}&approx;\u{2248}&approxeq;\u{224a}&ascr;\u{1d4b6}&asympeq;\u{224d}&aw'
    'conint;\u{2233}&awint;\u{2a11}&bNot;\u{2aed}&backcong;\u{224c}&backepsilon;\u{3f6}&backprime;\u{2035}&ba'
    'cksim;\u{223d}&backsimeq;\u{22cd}&barvee;\u{22bd}&barwed;\u{2305}&barwedge;\u{2305}&bbrk;\u{23b5}&bbrktb'
    'rk;\u{23b6}&bcong;\u{224c}&bcy;\u{431}&becaus;\u{2235}&because;\u{2235}&bemptyv;\u{29b0}&bepsi;\u{3f6}&b'
    'ernou;\u{212c}&beth;\u{2136}&between;\u{226c}&bfr;\u{1d51f}&bigcap;\u{22c2}&bigcirc;\u{25ef}&bigcup;'
    '\u{22c3}&bigodot;\u{2a00}&bigoplus;\u{2a01}&bigotimes;\u{2a02}&bigsqcup;\u{2a06}&bigstar;\u{2605}&bigtri'
    'angledown;\u{25bd}&bigtriangleup;\u{25b3}&biguplus;\u{2a04}&bigvee;\u{22c1}&bigwedge;\u{22c0}&bkarow;'
    '\u{290d}&blacklozenge;\u{29eb}&blacksquare;\u{25aa}&blacktriangle;\u{25b4}&blacktriangledown;\u{25be}&bl'
    'acktriangleleft;\u{25c2}&blacktriangleright;\u{25b8}&blank;\u{2423}&blk12;\u{2592}&blk14;\u{2591}&blk34;'
    '\u{2593}&block;\u{2588}&bne;=\u{20e5}&bnequiv;\u{2261}\u{20e5}&bnot;\u{2310}&bopf;\u{1d553}&bot;\u{22a5}'
    '&bottom;\u{22a5}&bowtie;\u{22c8}&boxDL;\u{2557}&boxDR;\u{2554}&boxDl;\u{2556}&boxDr;\u{2553}&boxH;'
    '\u{2550}&boxHD;\u{2566}&boxHU;\u{2569}&boxHd;\u{2564}&boxHu;\u{2567}&boxUL;\u{255d}&boxUR;\u{255a}&boxUl'
    ';\u{255c}&boxUr;\u{2559}&boxV;\u{2551}&boxVH;\u{256c}&boxVL;\u{2563}&boxVR;\u{2560}&boxVh;\u{256b}&boxVl'
    ';\u{2562}&boxVr;\u{255f}&boxbox;\u{29c9}&boxdL;\u{2555}&boxdR;\u{2552}&boxdl;\u{2510}&boxdr;\u{250c}&box'
    'h;\u{2500}&boxhD;\u{2565}&boxhU;\u{2568}&boxhd;\u{252c}&boxhu;\u{2534}&boxminus;\u{229f}&boxplus;'
    '\u{229e}&boxtimes;\u{22a0}&boxuL;\u{255b}&boxuR;\u{2558}&boxul;\u{2518}&boxur;\u{2514}&boxv;\u{2502}&box'
    'vH;\u{256a}&boxvL;\u{2561}&boxvR;\u{255e}&boxvh;\u{253c}&boxvl;\u{2524}&boxvr;\u{251c}&bprime;\u{2035}&b'
    'reve;\u{2d8}&bscr;\u{1d4b7}&bsemi;\u{204f}&bsim;\u{223d}&bsime;\u{22cd}&bsolb;\u{29c5}&bsolhsub;\u{27c8}'
    '&bullet;\u{2022}&bump;\u{224e}&bumpE;\u{2aae}&bumpe;\u{224f}&bumpeq;\u{224f}&cacute;\u{107}&capand;'
    '\u{2a44}&capbrcup;\u{2a49}&capcap;\u{2a4b}&capcup;\u{2a47}&capdot;\u{2a40}&caps;\u{2229}\u{fe00}&caret;'
    '\u{2041}&caron;\u{2c7}&ccaps;\u{2a4d}&ccaron;\u{10d}&ccirc;\u{109}&ccups;\u{2a4c}&ccupssm;\u{2a50}&cdot;'
    '\u{10b}&cemptyv;\u{29b2}&centerdot;\u{b7}&cfr;\u{1d520}&chcy;\u{447}&cir;\u{25cb}&cirE;\u{29c3}&circeq;'
    '\u{2257}&circlearrowleft;\u{21ba}&circlearrowright;\u{21bb}&circledR;\u{ae}&circledS;\u{24c8}&circledast'
    ';\u{229b}&circledcirc;\u{229a}&circleddash;\u{229d}&cire;\u{2257}&cirfnint;\u{2a10}&cirmid;\u{2aef}&cirs'
    'cir;\u{29c2}&clubsuit;\u{2663}&colone;\u{2254}&coloneq;\u{2254}&comp;\u{2201}&compfn;\u{2218}&complement'
    ';\u{2201}&complexes;\u{2102}&congdot;\u{2a6d}&conint;\u{222e}&copf;\u{1d554}&coprod;\u{2210}&copysr;'
    '\u{2117}&cscr;\u{1d4b8}&csub;\u{2acf}&csube;\u{2ad1}&csup;\u{2ad0}&csupe;\u{2ad2}&ctdot;\u{22ef}&cudarrl'
    ';\u{2938}&cudarrr;\u{2935}&cuepr;\u{22de}&cuesc;\u{22df}&cularr;\u{21b6}&cularrp;\u{293d}&cupbrcap;'
    '\u{2a48}&cupcap;\u{2a46}&cupcup;\u{2a4a}&cupdot;\u{228d}&cupor;\u{2a45}&cups;\u{222a}\u{fe00}&curarr;'
    '\u{21b7}&curarrm;\u{293c}&curlyeqprec;\u{22de}&curlyeqsucc;\u{22df}&curlyvee;\u{22ce}&curlywedge;'
    '\u{22cf}&curvearrowleft;\u{21b6}&curvearrowright;\u{21b7}&cuvee;\u{22ce}&cuwed;\u{22cf}&cwconint;'
    '\u{2232}&cwint;\u{2231}&cylcty;\u{232d}&dHar;\u{2965}&daleth;\u{2138}&dashv;\u{22a3}&dbkarow;\u{290f}&db'
    'lac;\u{2dd}&dcaron;\u{10f}&dcy;\u{434}&dd;\u{2146}&ddagger;\u{2021}&ddarr;\u{21ca}&ddotseq;\u{2a77}&demp'
    'tyv;\u{29b1}&dfisht;\u{297f}&dfr;\u{1d521}&dharl;\u{21c3}&dharr;\u{21c2}&diam;\u{22c4}&diamond;\u{22c4}&'
    'diamondsuit;\u{2666}&die;\u{a8}&digamma;\u{3dd}&disin;\u{22f2}&div;\u{f7}&divideontimes;\u{22c7}&divonx;'
    '\u{22c7}&djcy;\u{452}&dlcorn;\u{231e}&dlcrop;\u{230d}&dopf;\u{1d555}&dot;\u{2d9}&doteq;\u{2250}&doteqdot'
    ';\u{2251}&dotminus;\u{2238}&dotplus;\u{2214}&dotsquare;\u{22a1}&doublebarwedge;\u{2306}&downarrow;'
    '\u{2193}&downdownarrows;\u{21ca}&downharpoonleft;\u{21c3}&downharpoonright;\u{21c2}&drbkarow;\u{2910}&dr'
    'corn;\u{231f}&drcrop;\u{230c}&dscr;\u{1d4b9}&dscy;\u{455}&dsol;\u{29f6}&dstrok;\u{111}&dtdot;\u{22f1}&dt'
    'ri;\u{25bf}&dtrif;\u{25be}&duarr;\u{21f5}&duhar;\u{296f}&dwangle;\u{29a6}&dzcy;\u{45f}&dzigrarr;\u{27ff}'
    '&eDDot;\u{2a77}&eDot;\u{2251}&easter;\u{2a6e}&ecaron;\u{11b}&ecir;\u{2256}&ecolon;\u{2255}&ecy;\u{44d}&e'
    'dot;\u{117}&ee;\u{2147}&efDot;\u{2252}&efr;\u{1d522}&eg;\u{2a9a}&egs;\u{2a96}&egsdot;\u{2a98}&el;'
    '\u{2a99}&elinters;\u{23e7}&ell;\u{2113}&els;\u{2a95}&elsdot;\u{2a97}&emacr;\u{113}&emptyset;\u{2205}&emp'
    'tyv;\u{2205}&emsp13;\u{2004}&emsp14;\u{2005}&eng;\u{14b}&eogon;\u{119}&eopf;\u{1d556}&epar;\u{22d5}&epar'
    'sl;\u{29e3}&eplus;\u{2a71}&epsi;\u{3b5}&epsiv;\u{3f5}&eqcirc;\u{2256}&eqcolon;\u{2255}&eqsim;\u{2242}&eq'
    'slantgtr;\u{2a96}&eqslantless;\u{2a95}&equest;\u{225f}&equivDD;\u{2a78}&eqvparsl;\u{29e5}&erDot;\u{2253}'
    '&erarr;\u{2971}&escr;\u{212f}&esdot;\u{2250}&esim;\u{2242}&expectation;\u{2130}&exponentiale;\u{2147}&fa'
    'llingdotseq;\u{2252}&fcy;\u{444}&ffilig;\u{fb03}&fflig;\u{fb00}&ffllig;\u{fb04}&ffr;\u{1d523}&filig;'
    '\u{fb01}&fjlig;fj&flat;\u{266d}&fllig;\u{fb02}&fltns;\u{25b1}&fopf;\u{1d557}&fork;\u{22d4}&forkv;'
    '\u{2ad9}&fpartint;\u{2a0d}&frac15;\u{2155}&frac16;\u{2159}&frac18;\u{215b}&frac25;\u{2156}&frac35;'
    '\u{2157}&frac38;\u{215c}&frac45;\u{2158}&frac56;\u{215a}&frac58;\u{215d}&frac78;\u{215e}&frown;\u{2322}&'
    'fscr;\u{1d4bb}&gE;\u{2267}&gEl;\u{2a8c}&gacute;\u{1f5}&gammad;\u{3dd}&gap;\u{2a86}&gbreve;\u{11f}&gcirc;'
    '\u{11d}&gcy;\u{433}&gdot;\u{121}&gel;\u{22db}&geq;\u{2265}&geqq;\u{2267}&geqslant;\u{2a7e}&ges;\u{2a7e}&'
    'gescc;\u{2aa9}&gesdot;\u{2a80}&gesdoto;\u{2a82}&gesdotol;\u{2a84}&gesl;\u{22db}\u{fe00}&gesles;\u{2a94}&'
    'gfr;\u{1d524}&gg;\u{226b}&ggg;\u{22d9}&gimel;\u{2137}&gjcy;\u{453}&gl;\u{2277}&glE;\u{2a92}&gla;\u{2aa5}'
    '&glj;\u{2aa4}&gnE;\u{2269}&gnap;\u{2a8a}&gnapprox;\u{2a8a}&gne;\u{2a88}&gneq;\u{2a88}&gneqq;\u{2269}&gns'
    'im;\u{22e7}&gopf;\u{1d558}&gscr;\u{210a}&gsim;\u{2273}&gsime;\u{2a8e}&gsiml;\u{2a90}&gtcc;\u{2aa7}&gtcir'
    ';\u{2a7a}&gtdot;\u{22d7}&gtlPar;\u{2995}&gtquest;\u{2a7c}&gtrapprox;\u{2a86}&gtrarr;\u{2978}&gtrdot;'
    '\u{22d7}&gtreqless;\u{22db}&gtreqqless;\u{2a8c}&gtrless;\u{2277}&gtrsim;\u{2273}&gvertneqq;\u{2269}'
    '\u{fe00}&gvnE;\u{2269}\u{fe00}&hamilt;\u{210b}&hardcy;\u{44a}&harrcir;\u{2948}&harrw;\u{21ad}&hbar;'
    '\u{210f}&hcirc;\u{125}&heartsuit;\u{2665}&hercon;\u{22b9}&hfr;\u{1d525}&hksearow;\u{2925}&hkswarow;'
    '\u{2926}&hoarr;\u{21ff}&homtht;\u{223b}&hookleftarrow;\u{21a9}&hookrightarrow;\u{21aa}&hopf;\u{1d559}&ho'
    'rbar;\u{2015}&hscr;\u{1d4bd}&hslash;\u{210f}&hstrok;\u{127}&hybull;\u{2043}&ic;\u{2063}&icy;\u{438}&iecy'
    ';\u{435}&iff;\u{21d4}&ifr;\u{1d526}&ii;\u{2148}&iiiint;\u{2a0c}&iiint;\u{222d}&iinfin;\u{29dc}&iiota;'
    '\u{2129}&ijlig;\u{133}&imacr;\u{12b}&imagline;\u{2110}&imagpart;\u{2111}&imath;\u{131}&imof;\u{22b7}&imp'
    'ed;\u{1b5}&in;\u{2208}&incare;\u{2105}&infintie;\u{29dd}&inodot;\u{131}&intcal;\u{22ba}&integers;'
    '\u{2124}&intercal;\u{22ba}&intlarhk;\u{2a17}&intprod;\u{2a3c}&iocy;\u{451}&iogon;\u{12f}&iopf;\u{1d55a}&'
    'iprod;\u{2a3c}&iscr;\u{1d4be}&isinE;\u{22f9}&isindot;\u{22f5}&isins;\u{22f4}&isinsv;\u{22f3}&isinv;'
    '\u{2208}&it;\u{2062}&itilde;\u{129}&iukcy;\u{456}&jcirc;\u{135}&jcy;\u{439}&jfr;\u{1d527}&jmath;\u{237}&'
    'jopf;\u{1d55b}&jscr;\u{1d4bf}&jsercy;\u{458}&jukcy;\u{454}&kappav;\u{3f0}&kcedil;\u{137}&kcy;\u{43a}&kfr'
    ';\u{1d528}&kgreen;\u{138}&khcy;\u{445}&kjcy;\u{45c}&kopf;\u{1d55c}&kscr;\u{1d4c0}&lAarr;\u{21da}&lAtail;'
    '\u{291b}&lBarr;\u{290e}&lE;\u{2266}&lEg;\u{2a8b}&lHar;\u{2962}&lacute;\u{13a}&laemptyv;\u{29b4}&lagran;'
    '\u{2112}&langd;\u{2991}&langle;\u{27e8}&lap;\u{2a85}&larrb;\u{21e4}&larrbfs;\u{291f}&larrfs;\u{291d}&lar'
    'rhk;\u{21a9}&larrlp;\u{21ab}&larrpl;\u{2939}&larrsim;\u{2973}&larrtl;\u{21a2}&lat;\u{2aab}&latail;'
    '\u{2919}&late;\u{2aad}&lates;\u{2aad}\u{fe00}&lbarr;\u{290c}&lbbrk;\u{2772}&lbrke;\u{298b}&lbrksld;'
    '\u{298f}&lbrkslu;\u{298d}&lcaron;\u{13e}&lcedil;\u{13c}&lcy;\u{43b}&ldca;\u{2936}&ldquor;\u{201e}&ldrdha'
    'r;\u{2967}&ldrushar;\u{294b}&ldsh;\u{21b2}&leftarrow;\u{2190}&leftarrowtail;\u{21a2}&leftharpoondown;'
    '\u{21bd}&leftharpoonup;\u{21bc}&leftleftarrows;\u{21c7}&leftrightarrow;\u{2194}&leftrightarrows;\u{21c6}'
    '&leftrightharpoons;\u{21cb}&leftrightsquigarrow;\u{21ad}&leftthreetimes;\u{22cb}&leg;\u{22da}&leq;'
    '\u{2264}&leqq;\u{2266}&leqslant;\u{2a7d}&les;\u{2a7d}&lescc;\u{2aa8}&lesdot;\u{2a7f}&lesdoto;\u{2a81}&le'
    'sdotor;\u{2a83}&lesg;\u{22da}\u{fe00}&lesges;\u{2a93}&lessapprox;\u{2a85}&lessdot;\u{22d6}&lesseqgtr;'
    '\u{22da}&lesseqqgtr;\u{2a8b}&lessgtr;\u{2276}&lesssim;\u{2272}&lfisht;\u{297c}&lfr;\u{1d529}&lg;\u{2276}'
    '&lgE;\u{2a91}&lhard;\u{21bd}&lharu;\u{21bc}&lharul;\u{296a}&lhblk;\u{2584}&ljcy;\u{459}&ll;\u{226a}&llar'
    'r;\u{21c7}&llcorner;\u{231e}&llhard;\u{296b}&lltri;\u{25fa}&lmidot;\u{140}&lmoust;\u{23b0}&lmoustache;'
    '\u{23b0}&lnE;\u{2268}&lnap;\u{2a89}&lnapprox;\u{2a89}&lne;\u{2a87}&lneq;\u{2a87}&lneqq;\u{2268}&lnsim;'
    '\u{22e6}&loang;\u{27ec}&loarr;\u{21fd}&lobrk;\u{27e6}&longleftarrow;\u{27f5}&longleftrightarrow;\u{27f7}'
    '&longmapsto;\u{27fc}&longrightarrow;\u{27f6}&looparrowleft;\u{21ab}&looparrowright;\u{21ac}&lopar;'
    '\u{2985}&lopf;\u{1d55d}&loplus;\u{2a2d}&lotimes;\u{2a34}&lozenge;\u{25ca}&lozf;\u{29eb}&lparlt;\u{2993}&'
    'lrarr;\u{21c6}&lrcorner;\u{231f}&lrhar;\u{21cb}&lrhard;\u{296d}&lrtri;\u{22bf}&lscr;\u{1d4c1}&lsh;'
    '\u{21b0}&lsim;\u{2272}&lsime;\u{2a8d}&lsimg;\u{2a8f}&lsquor;\u{201a}&lstrok;\u{142}&ltcc;\u{2aa6}&ltcir;'
    '\u{2a79}&ltdot;\u{22d6}&lthree;\u{22cb}&ltimes;\u{22c9}&ltlarr;\u{2976}&ltquest;\u{2a7b}&ltrPar;\u{2996}'
    '&ltri;\u{25c3}&ltrie;\u{22b4}&ltrif;\u{25c2}&lurdshar;\u{294a}&luruhar;\u{2966}&lvertneqq;\u{2268}'
    '\u{fe00}&lvnE;\u{2268}\u{fe00}&mDDot;\u{223a}&malt;\u{2720}&maltese;\u{2720}&map;\u{21a6}&mapsto;'
    '\u{21a6}&mapstodown;\u{21a7}&mapstoleft;\u{21a4}&mapstoup;\u{21a5}&marker;\u{25ae}&mcomma;\u{2a29}&mcy;'
    '\u{43c}&measuredangle;\u{2221}&mfr;\u{1d52a}&mho;\u{2127}&mid;\u{2223}&midast;*&midcir;\u{2af0}&minusb;'
    '\u{229f}&minusd;\u{2238}&minusdu;\u{2a2a}&mlcp;\u{2adb}&mldr;\u{2026}&mnplus;\u{2213}&models;\u{22a7}&mo'
    'pf;\u{1d55e}&mp;\u{2213}&mscr;\u{1d4c2}&mstpos;\u{223e}&multimap;\u{22b8}&mumap;\u{22b8}&nGg;\u{22d9}'
    '\u{338}&nGt;\u{226b}\u{20d2}&nGtv;\u{226b}\u{338}&nLeftarrow;\u{21cd}&nLeftrightarrow;\u{21ce}&nLl;'
    '\u{22d8}\u{338}&nLt;\u{226a}\u{20d2}&nLtv;\u{226a}\u{338}&nRightarrow;\u{21cf}&nVDash;\u{22af}&nVdash;'
    '\u{22ae}&nacute;\u{144}&nang;\u{2220}\u{20d2}&nap;\u{2249}&napE;\u{2a70}\u{338}&napid;\u{224b}\u{338}&na'
    'pos;\u{149}&napprox;\u{2249}&natur;\u{266e}&natural;\u{266e}&naturals;\u{2115}&nbump;\u{224e}\u{338}&nbu'
    'mpe;\u{224f}\u{338}&ncap;\u{2a43}&ncaron;\u{148}&ncedil;\u{146}&ncong;\u{2247}&ncongdot;\u{2a6d}\u{338}&'
    'ncup;\u{2a42}&ncy;\u{43d}&neArr;\u{21d7}&nearhk;\u{2924}&nearr;\u{2197}&nearrow;\u{2197}&nedot;\u{2250}'
    '\u{338}&nequiv;\u{2262}&nesear;\u{2928}&nesim;\u{2242}\u{338}&nexist;\u{2204}&nexists;\u{2204}&nfr;'
    '\u{1d52b}&ngE;\u{2267}\u{338}&nge;\u{2271}&ngeq;\u{2271}&ngeqq;\u{2267}\u{338}&ngeqslant;\u{2a7e}\u{338}'
    '&nges;\u{2a7e}\u{338}&ngsim;\u{2275}&ngt;\u{226f}&ngtr;\u{226f}&nhArr;\u{21ce}&nharr;\u{21ae}&nhpar;'
    '\u{2af2}&nis;\u{22fc}&nisd;\u{22fa}&niv;\u{220b}&njcy;\u{45a}&nlArr;\u{21cd}&nlE;\u{2266}\u{338}&nlarr;'
    '\u{219a}&nldr;\u{2025}&nle;\u{2270}&nleftarrow;\u{219a}&nleftrightarrow;\u{21ae}&nleq;\u{2270}&nleqq;'
    '\u{2266}\u{338}&nleqslant;\u{2a7d}\u{338}&nles;\u{2a7d}\u{338}&nless;\u{226e}&nlsim;\u{2274}&nlt;'
    '\u{226e}&nltri;\u{22ea}&nltrie;\u{22ec}&nmid;\u{2224}&nopf;\u{1d55f}&notinE;\u{22f9}\u{338}&notindot;'
    '\u{22f5}\u{338}&notinva;\u{2209}&notinvb;\u{22f7}&notinvc;\u{22f6}&notni;\u{220c}&notniva;\u{220c}&notni'
    'vb;\u{22fe}&notnivc;\u{22fd}&npar;\u{2226}&nparallel;\u{2226}&nparsl;\u{2afd}\u{20e5}&npart;\u{2202}'
    '\u{338}&npolint;\u{2a14}&npr;\u{2280}&nprcue;\u{22e0}&npre;\u{2aaf}\u{338}&nprec;\u{2280}&npreceq;'
    '\u{2aaf}\u{338}&nrArr;\u{21cf}&nrarr;\u{219b}&nrarrc;\u{2933}\u{338}&nrarrw;\u{219d}\u{338}&nrightarrow;'
    '\u{219b}&nrtri;\u{22eb}&nrtrie;\u{22ed}&nsc;\u{2281}&nsccue;\u{22e1}&nsce;\u{2ab0}\u{338}&nscr;\u{1d4c3}'
    '&nshortmid;\u{2224}&nshortparallel;\u{2226}&nsim;\u{2241}&nsime;\u{2244}&nsimeq;\u{2244}&nsmid;\u{2224}&'
    'nspar;\u{2226}&nsqsube;\u{22e2}&nsqsupe;\u{22e3}&nsubE;\u{2ac5}\u{338}&nsube;\u{2288}&nsubset;\u{2282}'
    '\u{20d2}&nsubseteq;\u{2288}&nsubseteqq;\u{2ac5}\u{338}&nsucc;\u{2281}&nsucceq;\u{2ab0}\u{338}&nsup;'
    '\u{2285}&nsupE;\u{2ac6}\u{338}&nsupe;\u{2289}&nsupset;\u{2283}\u{20d2}&nsupseteq;\u{2289}&nsupseteqq;'
    '\u{2ac6}\u{338}&ntgl;\u{2279}&ntlg;\u{2278}&ntriangleleft;\u{22ea}&ntrianglelefteq;\u{22ec}&ntrianglerig'
    'ht;\u{22eb}&ntrianglerighteq;\u{22ed}&numero;\u{2116}&numsp;\u{2007}&nvDash;\u{22ad}&nvHarr;\u{2904}&nva'
    'p;\u{224d}\u{20d2}&nvdash;\u{22ac}&nvge;\u{2265}\u{20d2}&nvgt;>\u{20d2}&nvinfin;\u{29de}&nvlArr;\u{2902}'
    '&nvle;\u{2264}\u{20d2}&nvlt;<\u{20d2}&nvltrie;\u{22b4}\u{20d2}&nvrArr;\u{2903}&nvrtrie;\u{22b5}\u{20d2}&'
    'nvsim;\u{223c}\u{20d2}&nwArr;\u{21d6}&nwarhk;\u{2923}&nwarr;\u{2196}&nwarrow;\u{2196}&nwnear;\u{2927}&oS'
    ';\u{24c8}&oast;\u{229b}&ocir;\u{229a}&ocy;\u{43e}&odash;\u{229d}&odblac;\u{151}&odiv;\u{2a38}&odot;'
    '\u{2299}&odsold;\u{29bc}&ofcir;\u{29bf}&ofr;\u{1d52c}&ogon;\u{2db}&ogt;\u{29c1}&ohbar;\u{29b5}&ohm;'
    '\u{3a9}&oint;\u{222e}&olarr;\u{21ba}&olcir;\u{29be}&olcross;\u{29bb}&olt;\u{29c0}&omacr;\u{14d}&omid;'
    '\u{29b6}&ominus;\u{2296}&oopf;\u{1d560}&opar;\u{29b7}&operp;\u{29b9}&orarr;\u{21bb}&ord;\u{2a5d}&order;'
    '\u{2134}&orderof;\u{2134}&origof;\u{22b6}&oror;\u{2a56}&orslope;\u{2a57}&orv;\u{2a5b}&oscr;\u{2134}&osol'
    ';\u{2298}&otimesas;\u{2a36}&ovbar;\u{233d}&par;\u{2225}&parallel;\u{2225}&parsim;\u{2af3}&parsl;\u{2afd}'
    '&pcy;\u{43f}&pertenk;\u{2031}&pfr;\u{1d52d}&phiv;\u{3d5}&phmmat;\u{2133}&pitchfork;\u{22d4}&planck;'
    '\u{210f}&planckh;\u{210e}&plankv;\u{210f}&plusacir;\u{2a23}&plusb;\u{229e}&pluscir;\u{2a22}&plusdo;'
    '\u{2214}&plusdu;\u{2a25}&pluse;\u{2a72}&plussim;\u{2a26}&plustwo;\u{2a27}&pm;\u{b1}&pointint;\u{2a15}&po'
    'pf;\u{1d561}&pr;\u{227a}&prE;\u{2ab3}&prap;\u{2ab7}&prcue;\u{227c}&pre;\u{2aaf}&prec;\u{227a}&precapprox'
    ';\u{2ab7}&preccurlyeq;\u{227c}&preceq;\u{2aaf}&precnapprox;\u{2ab9}&precneqq;\u{2ab5}&precnsim;\u{22e8}&'
    'precsim;\u{227e}&primes;\u{2119}&prnE;\u{2ab5}&prnap;\u{2ab9}&prnsim;\u{22e8}&profalar;\u{232e}&profline'
    ';\u{2312}&profsurf;\u{2313}&propto;\u{221d}&prsim;\u{227e}&prurel;\u{22b0}&pscr;\u{1d4c5}&puncsp;'
    '\u{2008}&qfr;\u{1d52e}&qint;\u{2a0c}&qopf;\u{1d562}&qprime;\u{2057}&qscr;\u{1d4c6}&quaternions;\u{210d}&'
    'quatint;\u{2a16}&questeq;\u{225f}&rAarr;\u{21db}&rAtail;\u{291c}&rBarr;\u{290f}&rHar;\u{2964}&race;'
    '\u{223d}\u{331}&racute;\u{155}&raemptyv;\u{29b3}&rangd;\u{2992}&range;\u{29a5}&rangle;\u{27e9}&rarrap;'
    '\u{2975}&rarrb;\u{21e5}&rarrbfs;\u{2920}&rarrc;\u{2933}&rarrfs;\u{291e}&rarrhk;\u{21aa}&rarrlp;\u{21ac}&'
    'rarrpl;\u{2945}&rarrsim;\u{2974}&rarrtl;\u{21a3}&rarrw;\u{219d}&ratail;\u{291a}&ratio;\u{2236}&rationals'
    ';\u{211a}&rbarr;\u{290d}&rbbrk;\u{2773}&rbrke;\u{298c}&rbrksld;\u{298e}&rbrkslu;\u{2990}&rcaron;\u{159}&'
    'rcedil;\u{157}&rcy;\u{440}&rdca;\u{2937}&rdldhar;\u{2969}&rdquor;\u{201d}&rdsh;\u{21b3}&realine;\u{211b}'
    '&realpart;\u{211c}&reals;\u{211d}&rect;\u{25ad}&rfisht;\u{297d}&rfr;\u{1d52f}&rhard;\u{21c1}&rharu;'
    '\u{21c0}&rharul;\u{296c}&rhov;\u{3f1}&rightarrow;\u{2192}&rightarrowtail;\u{21a3}&rightharpoondown;'
    '\u{21c1}&rightharpoonup;\u{21c0}&rightleftarrows;\u{21c4}&rightleftharpoons;\u{21cc}&rightrightarrows;'
    '\u{21c9}&rightsquigarrow;\u{219d}&rightthreetimes;\u{22cc}&ring;\u{2da}&risingdotseq;\u{2253}&rlarr;'
    '\u{21c4}&rlhar;\u{21cc}&rmoust;\u{23b1}&rmoustache;\u{23b1}&rnmid;\u{2aee}&roang;\u{27ed}&roarr;\u{21fe}'
    '&robrk;\u{27e7}&ropar;\u{2986}&ropf;\u{1d563}&roplus;\u{2a2e}&rotimes;\u{2a35}&rpargt;\u{2994}&rppolint;'
    '\u{2a12}&rrarr;\u{21c9}&rscr;\u{1d4c7}&rsh;\u{21b1}&rsquor;\u{2019}&rthree;\u{22cc}&rtimes;\u{22ca}&rtri'
    ';\u{25b9}&rtrie;\u{22b5}&rtrif;\u{25b8}&rtriltri;\u{29ce}&ruluhar;\u{2968}&rx;\u{211e}&sacute;\u{15b}&sc'
    ';\u{227b}&scE;\u{2ab4}&scap;\u{2ab8}&sccue;\u{227d}&sce;\u{2ab0}&scedil;\u{15f}&scirc;\u{15d}&scnE;'
    '\u{2ab6}&scnap;\u{2aba}&scnsim;\u{22e9}&scpolint;\u{2a13}&scsim;\u{227f}&scy;\u{441}&sdotb;\u{22a1}&sdot'
    'e;\u{2a66}&seArr;\u{21d8}&searhk;\u{2925}&searr;\u{2198}&searrow;\u{2198}&seswar;\u{2929}&setminus;'
    '\u{2216}&setmn;\u{2216}&sext;\u{2736}&sfr;\u{1d530}&sfrown;\u{2322}&sharp;\u{266f}&shchcy;\u{449}&shcy;'
    '\u{448}&shortmid;\u{2223}&shortparallel;\u{2225}&sigmav;\u{3c2}&simdot;\u{2a6a}&sime;\u{2243}&simeq;'
    '\u{2243}&simg;\u{2a9e}&simgE;\u{2aa0}&siml;\u{2a9d}&simlE;\u{2a9f}&simne;\u{2246}&simplus;\u{2a24}&simra'
    'rr;\u{2972}&slarr;\u{2190}&smallsetminus;\u{2216}&smashp;\u{2a33}&smeparsl;\u{29e4}&smid;\u{2223}&smile;'
    '\u{2323}&smt;\u{2aaa}&smte;\u{2aac}&smtes;\u{2aac}\u{fe00}&softcy;\u{44c}&solb;\u{29c4}&solbar;\u{233f}&'
    'sopf;\u{1d564}&spadesuit;\u{2660}&spar;\u{2225}&sqcap;\u{2293}&sqcaps;\u{2293}\u{fe00}&sqcup;\u{2294}&sq'
    'cups;\u{2294}\u{fe00}&sqsub;\u{228f}&sqsube;\u{2291}&sqsubset;\u{228f}&sqsubseteq;\u{2291}&sqsup;'
    '\u{2290}&sqsupe;\u{2292}&sqsupset;\u{2290}&sqsupseteq;\u{2292}&squ;\u{25a1}&square;\u{25a1}&squarf;'
    '\u{25aa}&squf;\u{25aa}&srarr;\u{2192}&sscr;\u{1d4c8}&ssetmn;\u{2216}&ssmile;\u{2323}&sstarf;\u{22c6}&str'
    'aightepsilon;\u{3f5}&straightphi;\u{3d5}&strns;\u{af}&subE;\u{2ac5}&subdot;\u{2abd}&subedot;\u{2ac3}&sub'
    'mult;\u{2ac1}&subnE;\u{2acb}&subne;\u{228a}&subplus;\u{2abf}&subrarr;\u{2979}&subset;\u{2282}&subseteq;'
    '\u{2286}&subseteqq;\u{2ac5}&subsetneq;\u{228a}&subsetneqq;\u{2acb}&subsim;\u{2ac7}&subsub;\u{2ad5}&subsu'
    'p;\u{2ad3}&succ;\u{227b}&succapprox;\u{2ab8}&succcurlyeq;\u{227d}&succeq;\u{2ab0}&succnapprox;\u{2aba}&s'
    'uccneqq;\u{2ab6}&succnsim;\u{22e9}&succsim;\u{227f}&supE;\u{2ac6}&supdot;\u{2abe}&supdsub;\u{2ad8}&suped'
    'ot;\u{2ac4}&suphsol;\u{27c9}&suphsub;\u{2ad7}&suplarr;\u{297b}&supmult;\u{2ac2}&supnE;\u{2acc}&supne;'
    '\u{228b}&supplus;\u{2ac0}&supset;\u{2283}&supseteq;\u{2287}&supseteqq;\u{2ac6}&supsetneq;\u{228b}&supset'
    'neqq;\u{2acc}&supsim;\u{2ac8}&supsub;\u{2ad4}&supsup;\u{2ad6}&swArr;\u{21d9}&swarhk;\u{2926}&swarr;'
    '\u{2199}&swarrow;\u{2199}&swnwar;\u{292a}&target;\u{2316}&tbrk;\u{23b4}&tcaron;\u{165}&tcedil;\u{163}&tc'
    'y;\u{442}&tdot;\u{20db}&telrec;\u{2315}&tfr;\u{1d531}&therefore;\u{2234}&thetav;\u{3d1}&thickapprox;'
    '\u{2248}&thicksim;\u{223c}&thkap;\u{2248}&thksim;\u{223c}&timesb;\u{22a0}&timesbar;\u{2a31}&timesd;'
    '\u{2a30}&tint;\u{222d}&toea;\u{2928}&top;\u{22a4}&topbot;\u{2336}&topcir;\u{2af1}&topf;\u{1d565}&topfork'
    ';\u{2ada}&tosa;\u{2929}&tprime;\u{2034}&triangle;\u{25b5}&triangledown;\u{25bf}&triangleleft;\u{25c3}&tr'
    'ianglelefteq;\u{22b4}&triangleq;\u{225c}&triangleright;\u{25b9}&trianglerighteq;\u{22b5}&tridot;\u{25ec}'
    '&trie;\u{225c}&triminus;\u{2a3a}&triplus;\u{2a39}&trisb;\u{29cd}&tritime;\u{2a3b}&trpezium;\u{23e2}&tscr'
    ';\u{1d4c9}&tscy;\u{446}&tshcy;\u{45b}&tstrok;\u{167}&twixt;\u{226c}&twoheadleftarrow;\u{219e}&twoheadrig'
    'htarrow;\u{21a0}&uHar;\u{2963}&ubrcy;\u{45e}&ubreve;\u{16d}&ucy;\u{443}&udarr;\u{21c5}&udblac;\u{171}&ud'
    'har;\u{296e}&ufisht;\u{297e}&ufr;\u{1d532}&uharl;\u{21bf}&uharr;\u{21be}&uhblk;\u{2580}&ulcorn;\u{231c}&'
    'ulcorner;\u{231c}&ulcrop;\u{230f}&ultri;\u{25f8}&umacr;\u{16b}&uogon;\u{173}&uopf;\u{1d566}&uparrow;'
    '\u{2191}&updownarrow;\u{2195}&upharpoonleft;\u{21bf}&upharpoonright;\u{21be}&uplus;\u{228e}&upsi;\u{3c5}'
    '&upuparrows;\u{21c8}&urcorn;\u{231d}&urcorner;\u{231d}&urcrop;\u{230e}&uring;\u{16f}&urtri;\u{25f9}&uscr'
    ';\u{1d4ca}&utdot;\u{22f0}&utilde;\u{169}&utri;\u{25b5}&utrif;\u{25b4}&uuarr;\u{21c8}&uwangle;\u{29a7}&vA'
    'rr;\u{21d5}&vBar;\u{2ae8}&vBarv;\u{2ae9}&vDash;\u{22a8}&vangrt;\u{299c}&varepsilon;\u{3f5}&varkappa;'
    '\u{3f0}&varnothing;\u{2205}&varphi;\u{3d5}&varpi;\u{3d6}&varpropto;\u{221d}&varr;\u{2195}&varrho;\u{3f1}'
    '&varsigma;\u{3c2}&varsubsetneq;\u{228a}\u{fe00}&varsubsetneqq;\u{2acb}\u{fe00}&varsupsetneq;\u{228b}'
    '\u{fe00}&varsupsetneqq;\u{2acc}\u{fe00}&vartheta;\u{3d1}&vartriangleleft;\u{22b2}&vartriangleright;'
    '\u{22b3}&vcy;\u{432}&vdash;\u{22a2}&vee;\u{2228}&veebar;\u{22bb}&veeeq;\u{225a}&vellip;\u{22ee}&vfr;'
    '\u{1d533}&vltri;\u{22b2}&vnsub;\u{2282}\u{20d2}&vnsup;\u{2283}\u{20d2}&vopf;\u{1d567}&vprop;\u{221d}&vrt'
    'ri;\u{22b3}&vscr;\u{1d4cb}&vsubnE;\u{2acb}\u{fe00}&vsubne;\u{228a}\u{fe00}&vsupnE;\u{2acc}\u{fe00}&vsupn'
    'e;\u{228b}\u{fe00}&vzigzag;\u{299a}&wcirc;\u{175}&wedbar;\u{2a5f}&wedge;\u{2227}&wedgeq;\u{2259}&wfr;'
    '\u{1d534}&wopf;\u{1d568}&wp;\u{2118}&wr;\u{2240}&wreath;\u{2240}&wscr;\u{1d4cc}&xcap;\u{22c2}&xcirc;'
    '\u{25ef}&xcup;\u{22c3}&xdtri;\u{25bd}&xfr;\u{1d535}&xhArr;\u{27fa}&xharr;\u{27f7}&xlArr;\u{27f8}&xlarr;'
    '\u{27f5}&xmap;\u{27fc}&xnis;\u{22fb}&xodot;\u{2a00}&xopf;\u{1d569}&xoplus;\u{2a01}&xotime;\u{2a02}&xrArr'
    ';\u{27f9}&xrarr;\u{27f6}&xscr;\u{1d4cd}&xsqcup;\u{2a06}&xuplus;\u{2a04}&xutri;\u{25b3}&xvee;\u{22c1}&xwe'
    'dge;\u{22c0}&yacy;\u{44f}&ycirc;\u{177}&ycy;\u{44b}&yfr;\u{1d536}&yicy;\u{457}&yopf;\u{1d56a}&yscr;'
    '\u{1d4ce}&yucy;\u{44e}&zacute;\u{17a}&zcaron;\u{17e}&zcy;\u{437}&zdot;\u{17c}&zeetrf;\u{2128}&zfr;'
    '\u{1d537}&zhcy;\u{436}&zigrarr;\u{21dd}&zopf;\u{1d56b}&zscr;\u{1d4cf}';

/// The text of HTML 5's reference [name] (without `&` or `;`) that [_entities] does not hold.
String? _moreEntity(String name) => _more[name];

/// [_moreEntities] as a map, split on the first miss: a page that never needs it pays nothing,
/// and one that does pays one pass rather than a scan per reference.
final Map<String, String> _more = () {
  final out = <String, String>{};
  for (var at = 0; at < _moreEntities.length;) {
    final semicolon = _moreEntities.indexOf(';', at + 1);
    var end = _moreEntities.indexOf('&', semicolon + 1);
    if (end < 0) end = _moreEntities.length;
    out[_moreEntities.substring(at + 1, semicolon)] = _moreEntities.substring(semicolon + 1, end);
    at = end;
  }
  return out;
}();

/// The legacy names HTML 5 decodes without a `;`; any other needs it, so `?a=1&lang=en` stays.
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

/// Numeric references 0x80–0x9F read as Windows-1252, as browsers do.
const _windows1252 = <int, int>{
  0x80: 0x20ac, 0x82: 0x201a, 0x83: 0x0192, 0x84: 0x201e, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, //
  0x88: 0x02c6, 0x89: 0x2030, 0x8a: 0x0160, 0x8b: 0x2039, 0x8c: 0x0152, 0x8e: 0x017d, 0x91: 0x2018,
  0x92: 0x2019, 0x93: 0x201c, 0x94: 0x201d, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02dc,
  0x99: 0x2122, 0x9a: 0x0161, 0x9b: 0x203a, 0x9c: 0x0153, 0x9e: 0x017e, 0x9f: 0x0178,
};

/// HTML text's references, decoded as HTML 5 does: without a `;` only a legacy name.
String _decodeText(String text) => MarkupInternals.decode(text, _textReference);

/// An HTML attribute's: as text, but a `;`-less legacy name before a letter, digit or `=` is
/// literal, being far more often a query parameter (`&copy=2`).
String _decodeAttribute(String text) => MarkupInternals.decode(text, _attributeReference);

(String?, int) _textReference(String text, int start) => _reference(text, start, attribute: false);

(String?, int) _attributeReference(String text, int start) => _reference(text, start, attribute: true);

/// The reference after the `&` at [start] and where the text resumes, or `(null, _)` when the
/// `&` is literal. Never scans ahead for a `;`, which made bare ampersands quadratic.
(String?, int) _reference(String text, int start, {required bool attribute}) {
  if (start < text.length && text.codeUnitAt(start) == 0x23) {
    return MarkupInternals.numericReference(text, start, _windows1252);
  }
  var i = start;
  while (i < text.length && MarkupInternals.isAlnum(text.codeUnitAt(i))) {
    i++;
  }
  if (i == start) return (null, 0);
  if (i < text.length && text.codeUnitAt(i) == 0x3b) {
    final name = text.substring(start, i);
    final full = _entities[name] ?? _moreEntity(name);
    if (full != null) return (full, i + 1);
  }
  // No `;`, or a name the table does not have: the longest legacy name it starts with.
  for (var end = i - start > 6 ? start + 6 : i; end > start + 1; end--) {
    final name = text.substring(start, end);
    if (!_legacyEntities.contains(name)) continue;
    final literal = attribute && end < text.length && (end < i || text.codeUnitAt(end) == 0x3d);
    return literal ? (null, 0) : (_entities[name], end);
  }
  return (null, 0);
}

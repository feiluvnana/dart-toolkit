/// # jQuery Selector Engine (internal)
///
/// The evaluator behind [Markup.\$] and [Markup.matching]: everything CSS
/// does, plus the jQuery pseudo-classes a scraper actually reaches for —
/// `:contains`, `:has`, `:eq`, `:first`, `:last`, `:even`, `:odd`, `:gt`,
/// `:lt`, `:header`, `:input` — and `[attr!=val]`.
///
/// Private to the package. It lives in `src` and not beside the cursor
/// because it is 800 lines of parser that nobody calls directly, and because
/// `src/markup.dart` should read as the vocabulary, not the machinery.
library;

import 'package:html/dom.dart';

// ============================================================================
// JQUERY SELECTOR ENGINE (internal)
// ============================================================================

/// Evaluates jQuery-compatible selectors including `:contains`, `:has`, `:eq`,
/// `:first`, `:last`, `:even`, `:odd`, `:gt`, `:lt`, `:header`, `:input`, and
/// `[attr!=val]`.
class JQuery {
  static final _hasJQueryPseudos = RegExp(
    r':(contains|icontains|has|eq|gt|lt|first|last|even|odd|header|input|button'
    r'|checkbox|radio|text|password|submit|reset|empty|parent|selected|visible'
    // The structural pseudo-classes are evaluated here rather than handed to
    // csslib, which matched `:nth-child(n)` against nothing and threw
    // UnimplementedError for `:nth-of-type`.
    r'|hidden|nth-child|nth-last-child|nth-of-type|nth-last-of-type'
    r'|first-of-type|last-of-type|only-of-type|only-child|is|where)\b|!=',
  );

  static final _headerTag = RegExp(r'^h[1-6]$', caseSensitive: false);
  static const _inputTags = {'input', 'select', 'textarea', 'button'};

  /// [element]'s 1-based position among its siblings.
  ///
  /// [ofType] counts only siblings sharing its tag, which is the difference
  /// between `:nth-child` and `:nth-of-type`; [fromEnd] counts backwards, for
  /// the `-last-` pair. An element with no parent is the only child there is.
  static int _position(
    Element element, {
    required bool ofType,
    bool fromEnd = false,
  }) {
    final parent = element.parent;
    if (parent == null) return 1;
    final tag = element.localName;
    var index = 0;
    final siblings = parent.children;
    for (
      var i = fromEnd ? siblings.length - 1 : 0;
      fromEnd ? i >= 0 : i < siblings.length;
      fromEnd ? i-- : i++
    ) {
      final sibling = siblings[i];
      if (ofType && sibling.localName != tag) continue;
      index++;
      if (identical(sibling, element)) return index;
    }
    return index;
  }

  // A crawl runs the same selector across every page, so each distinct
  // selector string is parsed once rather than on every call.
  static final _branchCache = _Memo<List<String>>();
  static final _stepCache = _Memo<List<_Step>>();
  static final _compoundCache = _Memo<_ParsedCompound>();

  static _MatchCache? _ambient;
  static int _depth = 0;

  /// Whether [selector] contains any jQuery extensions beyond CSS.
  static bool extended(String selector) => _hasJQueryPseudos.hasMatch(selector);

  static List<String> _branches(String selector) =>
      _branchCache.of(selector, () => _splitSelectorList(selector));

  static List<_Step> _steps(String branch) =>
      _stepCache.of(branch, () => _splitSteps(branch));

  static _ParsedCompound _compound(String selector) =>
      _compoundCache.of(selector, () => _parseCompound(selector));

  /// Runs [body] with a match cache live for the whole call tree.
  ///
  /// Selector evaluation never mutates the DOM, so results memoised for one
  /// top-level call stay valid for every nested one.
  static T _scope<T>(T Function() body) {
    _ambient ??= _MatchCache();
    _depth++;
    try {
      return body();
    } finally {
      if (--_depth == 0) _ambient = null;
    }
  }

  /// Whether [element] itself matches [selector], jQuery extensions included.
  ///
  /// Tests the element directly rather than querying an ancestor's subtree and
  /// scanning the result for it, which is what keeps `closest`, `not` and the
  /// child combinators linear instead of quadratic.
  static bool matches(Element element, String selector) {
    final trimmed = selector.trim();
    if (trimmed.isEmpty) return false;
    return _scope(() {
      for (final branch in _branches(trimmed)) {
        if (_matchesBranch(element, branch)) return true;
      }
      return false;
    });
  }

  static bool _matchesBranch(Element element, String branch) {
    final steps = _steps(branch);
    if (steps.isEmpty) return false;
    return _matchesFrom(element, steps, steps.length - 1);
  }

  /// Whether [element] satisfies `steps[index]` and everything left of it.
  static bool _matchesFrom(Element element, List<_Step> steps, int index) {
    if (!_matchesCompound(element, steps[index].selector)) return false;
    if (index == 0) return true;
    final next = index - 1;
    switch (steps[index].combinator) {
      case '>':
        final parent = element.parent;
        return parent != null && _matchesFrom(parent, steps, next);
      case '+':
        final prev = element.previousElementSibling;
        return prev != null && _matchesFrom(prev, steps, next);
      case '~':
        for (
          var sib = element.previousElementSibling;
          sib != null;
          sib = sib.previousElementSibling
        ) {
          if (_matchesFrom(sib, steps, next)) return true;
        }
        return false;
      default:
        for (var up = element.parent; up != null; up = up.parent) {
          if (_matchesFrom(up, steps, next)) return true;
        }
        return false;
    }
  }

  static bool _matchesCompound(Element element, String compound) {
    final parsed = _compound(compound);
    if (!_matchesBase(element, parsed.baseCss)) return false;
    for (final filter in parsed.elementFilters) {
      if (!filter(element)) return false;
    }
    // A positional pseudo on a single-element test asks whether the element
    // would survive the filter as the only candidate.
    var candidates = <Element>[element];
    for (final positional in parsed.positionalFilters) {
      candidates = positional(candidates);
      if (candidates.isEmpty) return false;
    }
    return true;
  }

  /// Selects elements matching [selector] within [root].
  static List<Element> select(Object? root, String selector) {
    selector = selector.trim();
    if (selector.isEmpty) return const [];

    // Fast-path pure CSS selectors
    if (!extended(selector)) {
      try {
        if (root is Document) {
          return root.querySelectorAll(selector);
        } else if (root is Element) {
          return root.querySelectorAll(selector);
        } else if (root is List<Element>) {
          final seen = <Element>{};
          for (final el in root) {
            seen.addAll(el.querySelectorAll(selector));
          }
          return seen.toList();
        }
      } catch (_) {}
    }

    return _scope(() {
      final results = <Element>[];
      final seen = <Element>{};

      for (final branch in _branches(selector)) {
        for (final el in _evalBranch(root, branch)) {
          if (seen.add(el)) results.add(el);
        }
      }

      return results;
    });
  }

  static List<String> _splitSelectorList(String selector) {
    final parts = <String>[];
    final buffer = StringBuffer();
    int parenDepth = 0;
    int bracketDepth = 0;
    String? inQuote;

    for (int i = 0; i < selector.length; i++) {
      final char = selector[i];
      if (inQuote != null) {
        buffer.write(char);
        if (char == inQuote && (i == 0 || selector[i - 1] != r'\')) {
          inQuote = null;
        }
        continue;
      }

      if (char == '"' || char == "'") {
        inQuote = char;
        buffer.write(char);
      } else if (char == '(') {
        parenDepth++;
        buffer.write(char);
      } else if (char == ')') {
        if (parenDepth > 0) parenDepth--;
        buffer.write(char);
      } else if (char == '[') {
        bracketDepth++;
        buffer.write(char);
      } else if (char == ']') {
        if (bracketDepth > 0) bracketDepth--;
        buffer.write(char);
      } else if (char == ',' && parenDepth == 0 && bracketDepth == 0) {
        final s = buffer.toString().trim();
        if (s.isNotEmpty) parts.add(s);
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }
    final s = buffer.toString().trim();
    if (s.isNotEmpty) parts.add(s);
    return parts;
  }

  static List<_Step> _splitSteps(String selector) {
    final steps = <_Step>[];
    final buffer = StringBuffer();
    int parenDepth = 0;
    int bracketDepth = 0;
    String? inQuote;
    String nextCombinator = ' ';

    var i = 0;
    while (i < selector.length) {
      final char = selector[i];
      if (inQuote != null) {
        buffer.write(char);
        if (char == inQuote && (i == 0 || selector[i - 1] != r'\')) {
          inQuote = null;
        }
        i++;
        continue;
      }

      if (char == '"' || char == "'") {
        inQuote = char;
        buffer.write(char);
        i++;
      } else if (char == '(') {
        parenDepth++;
        buffer.write(char);
        i++;
      } else if (char == ')') {
        if (parenDepth > 0) parenDepth--;
        buffer.write(char);
        i++;
      } else if (char == '[') {
        bracketDepth++;
        buffer.write(char);
        i++;
      } else if (char == ']') {
        if (bracketDepth > 0) bracketDepth--;
        buffer.write(char);
        i++;
      } else if (parenDepth == 0 &&
          bracketDepth == 0 &&
          (char == '>' || char == '+' || char == '~')) {
        final s = buffer.toString().trim();
        if (s.isNotEmpty) {
          steps.add(_Step(nextCombinator, s));
          buffer.clear();
        }
        nextCombinator = char;
        i++;
      } else if (parenDepth == 0 &&
          bracketDepth == 0 &&
          (char == ' ' || char == '\t' || char == '\n')) {
        var j = i;
        while (j < selector.length &&
            (selector[j] == ' ' ||
                selector[j] == '\t' ||
                selector[j] == '\n')) {
          j++;
        }
        if (j < selector.length &&
            (selector[j] == '>' || selector[j] == '+' || selector[j] == '~')) {
          i = j;
        } else {
          final s = buffer.toString().trim();
          if (s.isNotEmpty) {
            steps.add(_Step(nextCombinator, s));
            buffer.clear();
            nextCombinator = ' ';
          }
          i = j;
        }
      } else {
        buffer.write(char);
        i++;
      }
    }

    final s = buffer.toString().trim();
    if (s.isNotEmpty) {
      steps.add(_Step(nextCombinator, s));
    }
    return steps;
  }

  static List<Element> _evalBranch(Object? root, String branch) {
    final steps = _steps(branch);
    if (steps.isEmpty) return const [];

    List<Element> current;
    if (root is Document) {
      current = [root.documentElement ?? root.body ?? Element.tag('html')];
    } else if (root is Element) {
      current = [root];
    } else if (root is List<Element>) {
      current = root;
    } else {
      return const [];
    }

    for (int stepIdx = 0; stepIdx < steps.length; stepIdx++) {
      final step = steps[stepIdx];
      final isFirst = stepIdx == 0;
      current = _evalStep(current, step, isFirst: isFirst, root: root);
      if (current.isEmpty) break;
    }

    return current;
  }

  static List<Element> _evalStep(
    List<Element> parents,
    _Step step, {
    required bool isFirst,
    required Object? root,
  }) {
    final parsed = _compound(step.selector);
    final candidates = <Element>[];
    final seen = <Element>{};

    void addCandidate(Element el) {
      if (seen.add(el)) {
        candidates.add(el);
      }
    }

    final baseCss = parsed.baseCss;

    if (isFirst) {
      // A document-rooted query can match the root element itself, the way
      // `Document.querySelectorAll('html')` does. An element-rooted one cannot:
      // `find` and `:has` both mean "search below here", so including the
      // context element would make an extended selector behave differently
      // from the plain-CSS fast path.
      final includeSelf = root is Document;
      for (final p in parents) {
        if (includeSelf && _matchesBase(p, baseCss)) {
          addCandidate(p);
        }
        final matches = _queryBase(p, baseCss);
        for (final m in matches) {
          addCandidate(m);
        }
      }
    } else {
      switch (step.combinator) {
        case ' ':
          for (final p in parents) {
            final matches = _queryBase(p, baseCss);
            for (final m in matches) {
              addCandidate(m);
            }
          }
          break;
        case '>':
          for (final p in parents) {
            for (final child in p.children) {
              if (_matchesBase(child, baseCss)) {
                addCandidate(child);
              }
            }
          }
          break;
        case '+':
          for (final p in parents) {
            final next = p.nextElementSibling;
            if (next != null && _matchesBase(next, baseCss)) {
              addCandidate(next);
            }
          }
          break;
        case '~':
          for (final p in parents) {
            var sib = p.nextElementSibling;
            while (sib != null) {
              if (_matchesBase(sib, baseCss)) {
                addCandidate(sib);
              }
              sib = sib.nextElementSibling;
            }
          }
          break;
      }
    }

    var filtered = candidates;
    for (final filter in parsed.elementFilters) {
      filtered = filtered.where(filter).toList();
    }

    for (final posFilter in parsed.positionalFilters) {
      filtered = posFilter(filtered);
    }

    return filtered;
  }

  /// The elements under [root] matching the plain-CSS part of a compound.
  ///
  /// `package:csslib` raises [UnimplementedError] for the selectors it does
  /// not evaluate — `:is`, `:hover`, `:target`, `::marker` and the rest of the
  /// interactive and pseudo-element families. That reached the caller from the
  /// middle of a match, as an [Error] rather than an [Exception], out of a
  /// cursor documented to give the empty result instead. A selector this
  /// cannot evaluate is a problem with the selector, so it is a
  /// [FormatException] naming the part that could not be read.
  static List<Element> _queryBase(Element root, String baseCss) {
    final css = (baseCss == '*' || baseCss.isEmpty) ? '*' : baseCss;
    try {
      return root.querySelectorAll(css);
    } on UnimplementedError catch (error) {
      throw FormatException(_unsupported(error, css), css);
    }
  }

  /// csslib's complaint, restated as a sentence about the selector.
  static String _unsupported(UnimplementedError error, String css) {
    final detail = error.message ?? '';
    final token = RegExp(r"'([^']+)'").firstMatch(detail)?.group(1);
    return token == null
        ? 'this selector is not supported: $css'
        : "'$token' is not a selector this supports";
  }

  static bool _matchesBase(Element el, String baseCss) =>
      (_ambient ?? _MatchCache()).matches(el, baseCss);

  static _ParsedCompound _parseCompound(String selector) {
    final elementFilters = <bool Function(Element)>[];
    final positionalFilters = <List<Element> Function(List<Element>)>[];

    var base = selector;

    // Attribute inequality [attr!=val]
    final notAttrRegex = RegExp(
      r'\[([a-zA-Z0-9_\-]+)!=(?:"([^"]*)"|'
      r"'([^']*)'|"
      r'([^\]]*))\]',
    );
    base = base.replaceAllMapped(notAttrRegex, (m) {
      final attrName = m[1]!;
      final expected = m[2] ?? m[3] ?? m[4] ?? '';
      elementFilters.add((el) {
        final val = el.attributes[attrName];
        return val != expected;
      });
      return '';
    });

    const jqPseudos = {
      'contains',
      'icontains',
      'has',
      'not',
      'header',
      'input',
      'button',
      'checkbox',
      'radio',
      'text',
      'password',
      'submit',
      'reset',
      'empty',
      'parent',
      'selected',
      'checked',
      'disabled',
      'enabled',
      'hidden',
      'visible',
      'first',
      'last',
      'eq',
      'even',
      'odd',
      'gt',
      'lt',
      // Structural, an+b. csslib supports :first-child and :last-child and
      // then stops: `:nth-child(2)` matched nothing at all and
      // `:nth-of-type(2)` threw UnimplementedError out of the middle of a
      // match, from a cursor documented to give the empty result instead.
      'is',
      'where',
      'nth-child',
      'nth-last-child',
      'nth-of-type',
      'nth-last-of-type',
      'first-of-type',
      'last-of-type',
      'only-of-type',
      'only-child',
    };

    final baseBuffer = StringBuffer();
    int i = 0;
    int bracketDepth = 0;
    String? inQuote;

    while (i < base.length) {
      final char = base[i];

      if (inQuote != null) {
        baseBuffer.write(char);
        if (char == inQuote && (i == 0 || base[i - 1] != r'\')) {
          inQuote = null;
        }
        i++;
        continue;
      }

      if (char == '"' || char == "'") {
        inQuote = char;
        baseBuffer.write(char);
        i++;
        continue;
      }

      if (char == '[') {
        bracketDepth++;
        baseBuffer.write(char);
        i++;
        continue;
      } else if (char == ']') {
        if (bracketDepth > 0) bracketDepth--;
        baseBuffer.write(char);
        i++;
        continue;
      }

      if (bracketDepth == 0 && char == ':') {
        if (i + 1 < base.length && base[i + 1] == ':') {
          baseBuffer.write('::');
          i += 2;
          continue;
        }

        var nameStart = i + 1;
        var nameEnd = nameStart;
        while (nameEnd < base.length) {
          final code = base.codeUnitAt(nameEnd);
          if ((code >= 65 && code <= 90) ||
              (code >= 97 && code <= 122) ||
              code == 45) {
            nameEnd++;
          } else {
            break;
          }
        }

        final pseudoName = base.substring(nameStart, nameEnd).toLowerCase();

        if (jqPseudos.contains(pseudoName)) {
          String? arg;
          var cur = nameEnd;
          if (cur < base.length && base[cur] == '(') {
            final argBuffer = StringBuffer();
            int pDepth = 1;
            String? pQuote;
            cur++;
            while (cur < base.length && pDepth > 0) {
              final pc = base[cur];
              if (pQuote != null) {
                argBuffer.write(pc);
                if (pc == pQuote && (cur == 0 || base[cur - 1] != r'\')) {
                  pQuote = null;
                }
                cur++;
                continue;
              }
              if (pc == '"' || pc == "'") {
                pQuote = pc;
                argBuffer.write(pc);
                cur++;
              } else if (pc == '(') {
                pDepth++;
                argBuffer.write(pc);
                cur++;
              } else if (pc == ')') {
                pDepth--;
                if (pDepth > 0) {
                  argBuffer.write(pc);
                }
                cur++;
              } else {
                argBuffer.write(pc);
                cur++;
              }
            }
            arg = argBuffer.toString().trim();
          }

          _applyPseudo(pseudoName, arg, elementFilters, positionalFilters);
          i = cur;
          continue;
        }
      }

      baseBuffer.write(char);
      i++;
    }

    base = baseBuffer.toString().trim();
    if (base.isEmpty) base = '*';

    return _ParsedCompound(base, elementFilters, positionalFilters);
  }

  static void _applyPseudo(
    String name,
    String? arg,
    List<bool Function(Element)> elementFilters,
    List<List<Element> Function(List<Element>)> positionalFilters,
  ) {
    switch (name) {
      case 'contains':
        final text = _unquote(arg ?? '');
        elementFilters.add((el) => el.text.contains(text));
        break;
      case 'icontains':
        final text = _unquote(arg ?? '').toLowerCase();
        elementFilters.add((el) => el.text.toLowerCase().contains(text));
        break;
      case 'has':
        final subSel = _unquote(arg ?? '');
        elementFilters.add((el) => JQuery.select(el, subSel).isNotEmpty);
        break;
      case 'not':
        final subSel = _unquote(arg ?? '');
        elementFilters.add((el) => !JQuery.matches(el, subSel));
        break;
      case 'nth-child':
        final step = _Nth.parse(arg);
        elementFilters.add((el) => step.holds(_position(el, ofType: false)));
        break;
      case 'nth-last-child':
        final step = _Nth.parse(arg);
        elementFilters.add(
          (el) => step.holds(_position(el, ofType: false, fromEnd: true)),
        );
        break;
      case 'nth-of-type':
        final step = _Nth.parse(arg);
        elementFilters.add((el) => step.holds(_position(el, ofType: true)));
        break;
      case 'nth-last-of-type':
        final step = _Nth.parse(arg);
        elementFilters.add(
          (el) => step.holds(_position(el, ofType: true, fromEnd: true)),
        );
        break;
      case 'first-of-type':
        elementFilters.add((el) => _position(el, ofType: true) == 1);
        break;
      case 'last-of-type':
        elementFilters.add(
          (el) => _position(el, ofType: true, fromEnd: true) == 1,
        );
        break;
      case 'only-of-type':
        elementFilters.add(
          (el) =>
              _position(el, ofType: true) == 1 &&
              _position(el, ofType: true, fromEnd: true) == 1,
        );
        break;
      case 'only-child':
        elementFilters.add(
          (el) =>
              _position(el, ofType: false) == 1 &&
              _position(el, ofType: false, fromEnd: true) == 1,
        );
        break;
      // `:is(a, b)` and `:where(a, b)` differ only in specificity, which
      // matters to a stylesheet and not to a match. csslib evaluates neither.
      case 'is':
      case 'where':
        final branches = _branches(_unquote(arg ?? ''));
        elementFilters.add(
          (el) => branches.any((branch) => JQuery.matches(el, branch)),
        );
        break;
      case 'header':
        elementFilters.add((el) => _headerTag.hasMatch(el.localName ?? ''));
        break;
      case 'input':
        elementFilters.add(
          (el) => _inputTags.contains(el.localName?.toLowerCase()),
        );
        break;
      case 'button':
        elementFilters.add((el) {
          final tag = el.localName?.toLowerCase();
          if (tag == 'button') return true;
          if (tag == 'input') {
            final type = el.attributes['type']?.toLowerCase();
            return type == 'button' || type == 'submit' || type == 'reset';
          }
          return false;
        });
        break;
      case 'checkbox':
        elementFilters.add(
          (el) =>
              el.localName?.toLowerCase() == 'input' &&
              el.attributes['type']?.toLowerCase() == 'checkbox',
        );
        break;
      case 'radio':
        elementFilters.add(
          (el) =>
              el.localName?.toLowerCase() == 'input' &&
              el.attributes['type']?.toLowerCase() == 'radio',
        );
        break;
      case 'text':
        elementFilters.add((el) {
          if (el.localName?.toLowerCase() != 'input') return false;
          final type = el.attributes['type']?.toLowerCase();
          return type == null || type == 'text' || type.isEmpty;
        });
        break;
      case 'password':
        elementFilters.add(
          (el) =>
              el.localName?.toLowerCase() == 'input' &&
              el.attributes['type']?.toLowerCase() == 'password',
        );
        break;
      case 'submit':
        elementFilters.add((el) {
          final tag = el.localName?.toLowerCase();
          final type = el.attributes['type']?.toLowerCase();
          return (tag == 'input' || tag == 'button') && type == 'submit';
        });
        break;
      case 'reset':
        elementFilters.add((el) {
          final tag = el.localName?.toLowerCase();
          final type = el.attributes['type']?.toLowerCase();
          return (tag == 'input' || tag == 'button') && type == 'reset';
        });
        break;
      case 'empty':
        elementFilters.add(
          (el) =>
              el.nodes.isEmpty ||
              (el.children.isEmpty && el.text.trim().isEmpty),
        );
        break;
      case 'parent':
        elementFilters.add(
          (el) =>
              el.nodes.isNotEmpty &&
              (el.children.isNotEmpty || el.text.isNotEmpty),
        );
        break;
      case 'selected':
        elementFilters.add(
          (el) =>
              el.localName?.toLowerCase() == 'option' &&
              el.attributes.containsKey('selected'),
        );
        break;
      case 'checked':
        elementFilters.add(
          (el) =>
              el.localName?.toLowerCase() == 'input' &&
              el.attributes.containsKey('checked'),
        );
        break;
      case 'disabled':
        elementFilters.add((el) => el.attributes.containsKey('disabled'));
        break;
      case 'enabled':
        elementFilters.add((el) => !el.attributes.containsKey('disabled'));
        break;
      case 'hidden':
        elementFilters.add(
          (el) =>
              el.attributes.containsKey('hidden') ||
              el.attributes['type']?.toLowerCase() == 'hidden' ||
              (el.attributes['style']?.contains('display: none') ?? false) ||
              (el.attributes['style']?.contains('display:none') ?? false),
        );
        break;
      case 'visible':
        elementFilters.add(
          (el) =>
              !el.attributes.containsKey('hidden') &&
              el.attributes['type']?.toLowerCase() != 'hidden' &&
              !(el.attributes['style']?.contains('display: none') ?? false) &&
              !(el.attributes['style']?.contains('display:none') ?? false),
        );
        break;
      case 'first':
        positionalFilters.add(
          (list) => list.isNotEmpty ? [list.first] : const [],
        );
        break;
      case 'last':
        positionalFilters.add(
          (list) => list.isNotEmpty ? [list.last] : const [],
        );
        break;
      case 'eq':
        final idx = int.tryParse(arg ?? '0') ?? 0;
        positionalFilters.add((list) {
          final i = idx < 0 ? list.length + idx : idx;
          if (i >= 0 && i < list.length) return [list[i]];
          return const [];
        });
        break;
      case 'even':
        positionalFilters.add(
          (list) => [for (var i = 0; i < list.length; i += 2) list[i]],
        );
        break;
      case 'odd':
        positionalFilters.add(
          (list) => [for (var i = 1; i < list.length; i += 2) list[i]],
        );
        break;
      case 'gt':
        final n = int.tryParse(arg ?? '0') ?? 0;
        positionalFilters.add(
          (list) => [for (var i = n + 1; i < list.length; i++) list[i]],
        );
        break;
      case 'lt':
        final n = int.tryParse(arg ?? '0') ?? 0;
        positionalFilters.add(
          (list) => [for (var i = 0; i < n && i < list.length; i++) list[i]],
        );
        break;
    }
  }

  static String _unquote(String s) {
    s = s.trim();
    if ((s.startsWith('"') && s.endsWith('"')) ||
        (s.startsWith("'") && s.endsWith("'"))) {
      if (s.length >= 2) {
        s = s.substring(1, s.length - 1);
        return s.replaceAll(r'\"', '"').replaceAll(r"\'", "'");
      }
    }
    return s;
  }
}

/// A bounded memo that evicts the least recently used entry.
class _Memo<V> {
  static const _limit = 512;
  final Map<String, V> _entries = {};

  V of(String key, V Function() compute) {
    final hit = _entries.remove(key);
    // Reinserting on a hit keeps the map in least-recently-used order, so the
    // handful of selectors a crawl actually reuses survive eviction.
    if (hit != null) return _entries[key] = hit;
    if (_entries.length >= _limit) _entries.remove(_entries.keys.first);
    return _entries[key] = compute();
  }
}

/// Memoises `querySelectorAll` per (root, selector) so testing many elements
/// against one selector costs a single subtree scan instead of one each.
class _MatchCache {
  final Map<Element, Map<String, Set<Element>>> _byRoot = {};

  bool matches(Element element, String css) {
    if (css.isEmpty || css == '*') return true;

    // The overwhelmingly common shape — a tag, some classes, an id, some
    // attribute tests, and no combinator — is answered from the element
    // itself. The general path walks to the document root and runs
    // `querySelectorAll` over the whole tree, which made `matching`, `not`
    // and `closest` cost a full document scan *per element*: testing 500 rows
    // against `.row` was 500 scans of a 500-row page.
    final simple = _Simple.of(css);
    if (simple != null) return simple.matches(element);

    var root = element;
    for (var up = element.parent; up != null; up = up.parent) {
      root = up;
    }
    // querySelectorAll only sees descendants, so the root itself is matched by
    // wrapping a shallow clone — cheap, and no descendant can answer for it.
    if (identical(root, element)) {
      final wrapper = Element.tag('div')..children.add(element.clone(false));
      try {
        return wrapper.querySelectorAll(css).isNotEmpty;
      } catch (_) {
        return false;
      }
    }
    return _byRoot
        .putIfAbsent(root, () => <String, Set<Element>>{})
        .putIfAbsent(css, () {
          try {
            return root.querySelectorAll(css).toSet();
          } catch (_) {
            return <Element>{};
          }
        })
        .contains(element);
  }
}

/// A compound selector with no combinator: a tag, classes, an id, attributes.
///
/// Parsed once per selector string and then answered directly off the
/// element, which is what keeps [JQuery.matches] from being a document scan.
/// Anything more — a descendant, a pseudo-class, a selector list — returns
/// `null` from [of] and takes the general path.
class _Simple {
  const _Simple(this.tag, this.classes, this.id, this.attributes);

  /// The tag name, lower-cased, or `null` for `*`.
  final String? tag;

  /// Every class the element must carry.
  final List<String> classes;

  /// The required `id`, if the selector named one.
  final String? id;

  /// Attribute tests, as (name, operator, value); the operator is `''` for a
  /// bare presence test.
  final List<(String, String, String)> attributes;

  static final _cache = _Memo<_Simple?>();

  /// A tag name, `.class`, `#id` or `[attr...]`, and nothing else.
  static final _token = RegExp(
    r'^(?:([*]|[A-Za-z][\w-]*)'
    r'|\.([\w-]+)'
    r'|#([\w-]+)'
    r'|\[\s*([\w-]+)\s*(?:([~^$*|]?=)\s*'
    r"""(?:"([^"]*)"|'([^']*)'|([^\]]*?))\s*)?\])""",
  );

  /// [css] as a simple compound, or `null` when it is anything more.
  static _Simple? of(String css) => _cache.of(css, () => _parse(css));

  static _Simple? _parse(String css) {
    final text = css.trim();
    if (text.isEmpty) return null;
    String? tag;
    String? id;
    final classes = <String>[];
    final attributes = <(String, String, String)>[];

    var at = 0;
    var first = true;
    while (at < text.length) {
      final m = _token.firstMatch(text.substring(at));
      if (m == null) return null;
      if (m.group(1) case final name?) {
        // A tag name is only a tag name in the leading position; anywhere
        // else it is a descendant, which this does not handle.
        if (!first) return null;
        if (name != '*') tag = name.toLowerCase();
      } else if (m.group(2) case final cls?) {
        classes.add(cls);
      } else if (m.group(3) case final ident?) {
        id = ident;
      } else if (m.group(4) case final attr?) {
        final op = m.group(5) ?? '';
        final value = m.group(6) ?? m.group(7) ?? m.group(8) ?? '';
        attributes.add((attr.toLowerCase(), op, value));
      }
      at += m.end;
      first = false;
    }
    return _Simple(tag, classes, id, attributes);
  }

  /// Whether [element] satisfies every part of this compound.
  bool matches(Element element) {
    if (tag != null && element.localName?.toLowerCase() != tag) return false;
    if (id != null && element.id != id) return false;
    for (final cls in classes) {
      if (!element.classes.contains(cls)) return false;
    }
    for (final (name, op, want) in attributes) {
      final have = element.attributes[name];
      if (have == null) return false;
      final ok = switch (op) {
        '' => true,
        '=' => have == want,
        '^=' => want.isNotEmpty && have.startsWith(want),
        r'$=' => want.isNotEmpty && have.endsWith(want),
        '*=' => want.isNotEmpty && have.contains(want),
        '~=' => want.isNotEmpty && have.split(RegExp(r'\s+')).contains(want),
        '|=' => have == want || have.startsWith('$want-'),
        _ => false,
      };
      if (!ok) return false;
    }
    return true;
  }
}

/// One `an+b` step, as `:nth-child` and its three siblings are written.
///
/// `2n+1`, `odd`, `even`, `3`, `-n+3` and a bare `n` all parse. An argument
/// that is not an `an+b` expression is a [FormatException] naming it, raised
/// while the selector is being parsed — the position a selector error belongs
/// in, rather than an `UnimplementedError` from the middle of a match.
class _Nth {
  /// The coefficient of `n`.
  final int a;

  /// The constant offset.
  final int b;

  const _Nth(this.a, this.b);

  static final _pattern = RegExp(
    // The coefficient may be a bare sign — '-n+3' is a = -1 — so the digits
    // are optional inside the group as well as the group being optional.
    r'^([+-]?\d*)n\s*(?:([+-])\s*(\d+))?$|^([+-]?\d+)$',
  );

  static _Nth parse(String? arg) {
    final text = (arg ?? '').trim().toLowerCase().replaceAll(' ', '');
    if (text == 'odd') return const _Nth(2, 1);
    if (text == 'even') return const _Nth(2, 0);

    final match = _pattern.firstMatch(text);
    if (match == null) {
      throw FormatException(
        "'$arg' is not an an+b expression; write a number, 'odd', 'even', "
        "or a form like '2n+1'",
        arg,
      );
    }
    // The fourth group is the bare-number branch: ':nth-child(3)' is 0n+3.
    if (match.group(4) case final only?) return _Nth(0, int.parse(only));

    final coefficient = match.group(1);
    final a = switch (coefficient) {
      null || '' || '+' => 1,
      '-' => -1,
      _ => int.parse(coefficient),
    };
    final sign = match.group(2) == '-' ? -1 : 1;
    final b = int.parse(match.group(3) ?? '0') * sign;
    return _Nth(a, b);
  }

  /// Whether the 1-based [position] satisfies this step.
  bool holds(int position) {
    if (position < 1) return false;
    if (a == 0) return position == b;
    final offset = position - b;
    // n counts from zero, so the offset has to be a non-negative multiple.
    return offset % a == 0 && offset ~/ a >= 0;
  }

  @override
  String toString() => '${a}n${b >= 0 ? '+' : ''}$b';
}

class _Step {
  final String combinator;
  final String selector;
  _Step(this.combinator, this.selector);
}

class _ParsedCompound {
  final String baseCss;
  final List<bool Function(Element)> elementFilters;
  final List<List<Element> Function(List<Element>)> positionalFilters;
  _ParsedCompound(this.baseCss, this.elementFilters, this.positionalFilters);
}

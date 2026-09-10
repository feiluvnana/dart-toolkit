/// # jQuery Selector Engine (internal)
///
/// The evaluator behind [Markup.find] and [Markup.matching]: everything CSS
/// does, plus the jQuery pseudo-classes a scraper actually reaches for —
/// `:contains`, `:has`, `:eq`, `:first`, `:last`, `:even`, `:odd`, `:gt`,
/// `:lt`, `:header`, `:input` — and `[attr!=val]`.
///
/// Private to the package. It lives in `src` and not beside the cursor
/// because it is 800 lines of parser that nobody calls directly, and because
/// `util/markup.dart` should read as the vocabulary, not the machinery.
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
    r':(contains|icontains|has|eq|gt|lt|first|last|even|odd|header|input|button|checkbox|radio|text|password|submit|reset|empty|parent|selected|visible|hidden)\b|!=',
  );

  static final _headerTag = RegExp(r'^h[1-6]$', caseSensitive: false);
  static const _inputTags = {'input', 'select', 'textarea', 'button'};

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

  static List<Element> _queryBase(Element root, String baseCss) {
    if (baseCss == '*' || baseCss.isEmpty) {
      return root.querySelectorAll('*');
    }
    return root.querySelectorAll(baseCss);
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

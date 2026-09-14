/// Guards the shape 9.0.0 was built for.
///
/// Two rules, both of which 8.1.0 stated and neither of which anything
/// checked:
///
/// 1. **Top level is for what has no receiver.** There are fourteen such
///    names. A fifteenth is a decision, not an accident, so adding one has to
///    come with a line here.
/// 2. **Documentation is written in the language this package targets.** Where
///    a leading dot resolves, the doc says `.html`, not `DocumentFormat.html`.
///    Nothing enforced this before and every doc comment in the package was a
///    minor version behind the language.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Everything the package puts in a script's global scope.
///
/// `$` and `$xpath` are not here: they are the one deliberate global, and they
/// stay behind the opt-in `package:dart_toolkit/html.dart` import.
const _topLevel = {
  'cpuCount',
  'crawl',
  'delay',
  'env',
  'loadEnv',
  'logger',
  'onExit',
  'retry',
  'run',
  'runStream',
  'serve',
  'serveOnce',
  'shutdown',
  'which',
};

/// Names this package must not put at top level, because `package:http`,
/// `package:collection` and `rxdart` already do.
///
/// Through 8.1.0 the README instructed readers to write an eight-name `hide`
/// clause to import `package:http` beside this one.
const _mustNotCollide = {
  'get',
  'post',
  'put',
  'patch',
  'delete',
  'head',
  'readBytes',
  'send',
  'download',
  'settle',
  'parallelMap',
  'sorted',
  'sortedBy',
  'zip',
  'unzip',
};

/// Every `///` line and every markdown line that documentation is written on.
Iterable<(String where, String line)> _documentation() sync* {
  for (final file in Directory('lib').listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.dart')) continue;
    var n = 0;
    for (final line in file.readAsLinesSync()) {
      n++;
      if (line.trimLeft().startsWith('///')) yield ('${file.path}:$n', line);
    }
  }
  for (final name in ['README.md', 'example/README.md']) {
    var n = 0;
    for (final line in File(name).readAsLinesSync()) {
      n++;
      yield ('$name:$n', line);
    }
  }
}

/// Public top-level declarations, read off the source rather than guessed.
Set<String> _declaredTopLevel() {
  final found = <String>{};
  final decl = RegExp(
    r'^[A-Za-z_][A-Za-z0-9_<>,?\[\] .]*\s+(?:get\s+)?([a-zA-Z$][A-Za-z0-9_$]*)\s*[(<=]',
  );
  for (final file in Directory('lib').listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.dart')) continue;
    // The opt-in `$` library is not on the default surface.
    if (file.path.endsWith('format/html.dart')) continue;
    for (final line in file.readAsLinesSync()) {
      if (RegExp(
        r'^(class|enum|extension|mixin|typedef|abstract|final|sealed|base|part|import|export|library|const|var)\b',
      ).hasMatch(line)) {
        continue;
      }
      final match = decl.firstMatch(line);
      if (match == null) continue;
      final name = match.group(1)!;
      if (!name.startsWith('_')) found.add(name);
    }
  }
  return found;
}

/// Every public member name declared under `lib/`, and whether it is static.
///
/// A static is constructor-like — it has no receiver to copy — so the
/// copy-versus-mutate rule does not reach it: `Maps.merge(a, b)` is
/// `Map.fromEntries`, not `Map.addAll`.
Iterable<(String where, String name, bool isStatic)> _members() sync* {
  final decl = RegExp(
    r'^  (?:static\s+)?(?!final |var |const |return |assert)'
    r'[A-Za-z_][A-Za-z0-9_<>,?\[\] .]*\s+'
    r'(?:get\s+)?([a-zA-Z][A-Za-z0-9_]*)\s*[(<;=]',
  );
  for (final file in Directory('lib').listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.dart')) continue;
    var n = 0;
    for (final line in file.readAsLinesSync()) {
      n++;
      if (line.trimLeft().startsWith('///')) continue;
      final match = decl.firstMatch(line);
      if (match != null) {
        yield (
          '${file.path}:$n',
          match.group(1)!,
          line.trimLeft().startsWith('static '),
        );
      }
    }
  }
}

void main() {
  group('the public surface', () {
    test('is fourteen top-level names, and no more', () {
      // Names the barrel deliberately hides, and the opt-in `$` library.
      const hidden = {
        'coerce',
        'jitterOf',
        'onceOn',
        'serveOn',
        'sharedConsoleWriter',
        'sharedEnv',
        r'$',
        r'$xpath',
        'Function',
      };
      final actual = _declaredTopLevel().difference(hidden);
      expect(
        actual,
        equals(_topLevel),
        reason:
            'Top level is for what has no receiver. Anything else belongs on '
            'the value it acts on.',
      );
    });

    test('does not collide with the packages a scraper imports beside it', () {
      for (final name in _mustNotCollide) {
        expect(
          _topLevel,
          isNot(contains(name)),
          reason:
              '$name is also exported by package:http, package:collection or '
              'rxdart. A script that imports one of those must not need a '
              'hide clause for this package.',
        );
      }
    });

    test('carries no Sync twin at top level', () {
      expect(
        _topLevel.where((n) => n.endsWith('Sync')),
        isEmpty,
        reason: 'Blocking calls live under `path.sync`.',
      );
    });

    test('every one of the fourteen is reachable from the one import', () {
      // A name in the list that the barrel does not actually export would
      // make this file a wish rather than a guard.
      final exported = File('lib/dart_toolkit.dart').readAsStringSync();
      expect(exported, contains('library;'));
      for (final name in _topLevel) {
        expect(
          _declaredTopLevel(),
          contains(name),
          reason: '\$name is listed here but not declared under lib/.',
        );
      }
    });
  });

  group('member names follow dart:core', () {
    /// Names `dart:core` already owns for the same operation, and the ones
    /// this package borrowed from Kotlin, lodash and rxdart instead.
    ///
    /// Every one of these was a member of this package at 8.1.0.
    const foreign = {
      'filter': 'where',
      'flatMap': 'expand or asyncExpand',
      'mapNotNull': 'map(...).nonNulls',
      'whereNotNull': 'nonNulls',
      'nonNull': 'nonNulls',
      'associateBy': 'toMapBy',
      'concatWith': 'followedBy',
      'filterKeys': 'whereKey',
      'filterValues': 'whereValue',
      'omit': 'except',
      'invert': 'inverted',
      'elementList': 'elements',
      'prev': 'previous',
      'jsonpath': 'jsonPath — lowerCamelCase',
      'randomItem': 'randomElement',
      'jsonDecoded': 'decodeJson',
      'picks': 'pickMany',
      'sweep': 'deleteFiles — say that it deletes',
      'intersect': 'intersection',
      'minus': 'difference',
      'flow': 'stream',
      // A copy must not be spelled like the mutator it sits beside.
      'merge': 'merged — Map.addAll is the one that mutates',
    };

    test('uses no name dart:core already spells differently', () {
      final offenders = [
        for (final (where, name, isStatic) in _members())
          if (foreign.containsKey(name) &&
              !(isStatic && const {'merge', 'flatten'}.contains(name)))
            '$where: $name -> ${foreign[name]}',
      ];
      expect(offenders, isEmpty);
    });

    test('spells a count `length` and an emptiness check `isEmpty`', () {
      final offenders = [
        for (final (where, name, _) in _members())
          // `count(test)` takes a predicate and is not `length`; RateLimiter's
          // `count` is a rate, not a size.
          if (name == 'empty') where,
      ];
      expect(
        offenders,
        isEmpty,
        reason: '`dart:core` calls it isEmpty everywhere it has one.',
      );
    });

    test('returns nullable maxima under an OrNull name', () {
      // `package:collection` spells the throwing version `max` and the
      // nullable one `maxOrNull`. Sharing the name with the opposite contract
      // is the trap this guards.
      final offenders = [
        for (final (where, name, _) in _members())
          if (const {'max', 'min', 'maxBy', 'minBy'}.contains(name)) where,
      ];
      expect(offenders, isEmpty);
    });
  });

  group('documentation is written in Dart 3.10', () {
    test('uses a leading dot where one resolves', () {
      // Only where the prefix is an *argument*: `f(DocumentFormat.html)` or
      // `f(x, HttpMethod.get)` or `name: Algo.sha256`. A `[DocumentFormat.html]`
      // dartdoc link names the member and is right as it is, and so is a
      // receiver — `DocumentFormat.yaml.format(x)` has no context type to
      // resolve a dot against.
      final asArgument = RegExp(
        r'[(,:]\s*(DocumentFormat|HttpMethod|Algo)\.'
        r'(html|json|yaml|toml|csv|robots|sitemap|get|post|put|patch|delete'
        r'|head|sha256|md5)\s*[,)]',
      );
      final offenders = <String>[];
      for (final (where, line) in _documentation()) {
        final match = asArgument.firstMatch(line);
        if (match != null) offenders.add('$where: ${match.group(0)!.trim()}');
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Dart 3.10 resolves these from the parameter type. Write `.html`, '
            'not `DocumentFormat.html`.',
      );
    });

    test('names nothing 9.0.0 deleted', () {
      const gone = [
        'consoleWriter.',
        'consoleReader.',
        'ProgressBar(',
        'crawler.flow',
        '.seq,',
        'Sequence<',
        'Dictionary<',
        'Flow<',
      ];
      final offenders = <String>[];
      for (final (where, line) in _documentation()) {
        // A line that explains what a name *used to be* is allowed to say it.
        if (line.contains('8.1.0') ||
            line.contains('through 7') ||
            line.contains('through 6') ||
            line.contains('through 5')) {
          continue;
        }
        for (final name in gone) {
          if (line.contains(name)) offenders.add('$where: $name');
        }
      }
      expect(offenders, isEmpty);
    });

    test('has no `no-compile` escape hatch left under lib/', () {
      final offenders = [
        for (final (where, line) in _documentation())
          if (line.contains('no-compile') && where.startsWith('lib/')) where,
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'Every snippet under lib/ compiles. The hatch is where stale docs '
            'survived two major versions.',
      );
    });
  });
}

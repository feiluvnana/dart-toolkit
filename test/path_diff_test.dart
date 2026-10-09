// The in-house path grammar against `package:path`, which it replaced, in both styles: known
// edge cases and seeded random paths.
import 'dart:math';

import 'package:dart_toolkit/src/path.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const posixCases = [
    '',
    '.',
    '..',
    '/',
    '//',
    'a',
    'a/',
    'a//',
    '/a',
    '//a',
    'a/b',
    'a//b',
    'a/./b',
    'a/../b',
    '../a',
    '../../a/..',
    'a/b/..',
    'a/b/../..',
    'a/b/../../..',
    '/..',
    '/../a',
    './a',
    'a/.',
    '.a',
    'a/.b',
    'a.b.c',
    'a/b.c/',
    'a/..b',
    'a/b..',
    '...',
    'a/.../b',
    '/a/b/c.tar.gz',
    r'a\b',
    'C:/x',
  ];
  const windowsCases = [
    '',
    '.',
    '..',
    r'\',
    '/',
    r'\\',
    r'a',
    r'a\',
    r'a\\',
    r'\a',
    r'a\b',
    r'a/b',
    r'a\\b',
    r'a\.\b',
    r'a\..\b',
    r'..\a',
    r'C:\',
    'C:/',
    'C:',
    'c:',
    r'C:a',
    r'C:\a',
    'C:/a/b',
    r'C:\a\..\..',
    r'C:\..',
    r'c:\A\b.TXT',
    r'\\server\share',
    r'\\server\share\',
    r'\\server\share\a\b',
    r'\\server',
    r'\\server\share\..',
    r'\a\b',
    r'/a\b/',
    r'1:\a',
    r'a\.b',
    r'a\b.c\',
    r'a\b..',
    r'\\?\C:\a',
    r'..\..\a\..',
    r'a/./b/../c\.\',
  ];

  for (final (windows, cases, current) in [(false, posixCases, '/cwd/sub'), (true, windowsCases, r'C:\cwd\sub')]) {
    final ctx = p.Context(style: windows ? p.Style.windows : p.Style.posix, current: current);
    final style = windows ? 'windows' : 'posix';
    T run<T>(T Function() body) => PathInternals.styled(body, windows: windows, cwd: current);
    final failures = <String>[];
    void check(Object? actual, Object? expected, String what) {
      if (actual.toString() != expected.toString()) failures.add('$what: $actual, package:path $expected');
    }

    final random = Random(7);
    final alphabet = windows
        ? ['a', 'b.c', '.', '..', r'\', '/', 'C:', r'\\', '.x', 'y.']
        : ['a', 'b.c', '.', '..', '/', '.x', 'y.'];
    final fuzz = [
      for (var i = 0; i < 400; i++)
        [for (var j = random.nextInt(6); j >= 0; j--) alphabet[random.nextInt(alphabet.length)]].join(),
    ];
    final all = [...cases, ...fuzz];

    test('$style: parts match package:path', () {
      for (final s in all) {
        final path = Path(s);
        String? safe(String Function() f) {
          try {
            return f();
          } on p.PathException {
            return null;
          }
        }

        run(() {
          check(path.normalized, s.isEmpty ? '.' : ctx.normalize(s), 'normalize($s)');
          check(path.name, ctx.basename(s), 'basename($s)');
          check(path.stem, ctx.basenameWithoutExtension(s), 'stem($s)');
          check(path.ext, ctx.extension(s).replaceFirst('.', ''), 'ext($s)');
          check(path.parent, ctx.dirname(s), 'dirname($s)');
          check(path.isAbsolute, ctx.isAbsolute(s), 'isAbsolute($s)');
          check(PathInternals.absolute(s), ctx.absolute(s), 'absolute($s)');
          check(path.absolute, ctx.normalize(ctx.absolute(s)), 'absolute.normalized($s)');
          check(path.segments, ctx.split(s), 'split($s)');
          if (!s.endsWith('/') && !s.endsWith(r'\')) {
            check(path.withExt('md'), ctx.setExtension(s, '.md'), 'withExt($s)');
          }
          if (safe(() => ctx.relative(s)) case final expected?) {
            check(path.relativeTo(), expected, 'relative($s)');
          }
        });
      }
      expect(failures, isEmpty);
    });

    test('$style: join, relative, equals and isWithin match package:path', () {
      final pairs = [
        for (final a in cases.take(24))
          for (final b in cases.take(24)) (a, b),
        for (var i = 0; i + 1 < fuzz.length; i += 2) (fuzz[i], fuzz[i + 1]),
      ];
      for (final (a, b) in pairs) {
        run(() {
          if (a.isNotEmpty) check(Path(a) / b, ctx.normalize(ctx.join(a, b)), 'join($a, $b)');
          check(PathInternals.equals(a, b), ctx.equals(a, b), 'equals($a, $b)');
          check(
            PathInternals.isWithin(a, b),
            ctx.isWithin(ctx.normalize(ctx.absolute(a)), ctx.normalize(ctx.absolute(b))),
            'isWithin($a, $b)',
          );
          String? expected;
          try {
            expected = ctx.relative(b, from: a);
          } on p.PathException {
            return;
          }
          check(Path(b).relativeTo(a), expected, 'relative($b, from: $a)');
        });
      }
      expect(failures, isEmpty);
    });
  }

  test('windows: a root-relative part keeps the drive or share', () {
    PathInternals.styled(
      () {
        expect(Path(r'C:\a\b') / r'\x', r'C:\x');
        expect(Path(r'\\srv\share\a') / '/x', r'\\srv\share\x');
        expect(Path(r'C:\a') / r'D:\y', r'D:\y');
        expect(Path(r'\x').absolute, r'C:\x');
        expect(Path(r'D:\a').relativeTo(r'C:\b'), r'D:\a');
        expect(Path(r'c:\A\B\f.txt').relativeTo(r'C:\a'), r'B\f.txt');
      },
      windows: true,
      cwd: r'C:\cwd',
    );
  });
}

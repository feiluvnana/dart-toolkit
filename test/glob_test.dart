import 'package:dart_toolkit/src/glob.dart';
import 'package:test/test.dart';

void main() {
  test('globs: classes, negation, a leading ], braces, escapes and the separator', () {
    final cases = <(String, String, bool)>[
      ('*.jpg', 'a.jpg', true),
      ('*.jpg', 'd/a.jpg', false),
      ('**/*.jpg', 'd/e/a.jpg', true),
      ('**/*.jpg', 'a.jpg', true),
      ('*.{jpg,png}', 'a.png', true),
      ('[abc].txt', 'b.txt', true),
      ('[!abc].txt', 'b.txt', false),
      ('[!abc].txt', 'z.txt', true),
      ('[]a]', ']', true), // a leading ] is a member
      ('[]a]', 'a', true),
      ('[!]a]', 'b', true),
      ('[!]a]', ']', false),
      ('a[/]b', 'a/b', false), // a class never crosses folders
      ('a[!x]b', 'a/b', false),
      ('{a,b', '{a,b', true), // an unmatched brace is literal
      (r'\*.txt', '*.txt', true),
      (r'\*.txt', 'a.txt', false),
    ];
    for (final (pattern, path, want) in cases) {
      expect(glob(pattern).hasMatch(path), want, reason: '$pattern ~ $path');
    }
    expect(glob('a[/]b', paths: false).hasMatch('a/b'), isTrue);
  });
}

import 'dart:io';
import 'package:test/test.dart';

/// Every public name each `lib/<name>.dart` exports, one `library: Name` per line, sorted.
///
/// A diff against `test/api_names.txt` is a change to the public surface: review it, then
/// regenerate with `UPDATE_API_NAMES=1 dart test test/api_names_test.dart`.
void main() {
  test('the public names are the reviewed list', () {
    final lines = <String>[
      for (final file in Directory('lib').listSync().whereType<File>().where((f) => f.path.endsWith('.dart')))
        for (final name in _exported(file.path, {})) '${file.uri.pathSegments.last.replaceAll('.dart', '')}: $name',
    ]..sort();
    final actual = '${lines.join('\n')}\n';
    final golden = File('test/api_names.txt');
    if (Platform.environment['UPDATE_API_NAMES'] == '1') golden.writeAsStringSync(actual);
    expect(
      actual,
      golden.existsSync() ? golden.readAsStringSync() : '',
      reason:
          'The public surface changed. Review the diff, then run UPDATE_API_NAMES=1 dart test test/api_names_test.dart',
    );
  });
}

final _directive = RegExp(r'''^(part|export)\s+'([^']+)'([^;]*);''', multiLine: true);
final _combinator = RegExp(r'\b(show|hide)\s+([\w\s,]+)');
final _type = RegExp(
  r'^(?:(?:abstract|base|final|interface|sealed|mixin)\s+)*(?:class|enum|mixin|extension type|extension|typedef)\s+(?:const\s+)?([A-Za-z_]\w*)',
);
final _skip = RegExp(r'^(?:\s|//|/\*|\*|}|\)|]|@|import\b|export\b|part\b|library\b|extension on\b|$)');
final _multiline = RegExp(
  r"'''|"
  '"""',
);
final _functionType = RegExp(r'Function\s*\([^()]*\)\??');
final _generic = RegExp(r'<[^<>]*>');
final _end = RegExp(r'[(=;{]');
final _lastWord = RegExp(r'([A-Za-z_]\w*)\??\s*$');

/// The public names of the library at [path]: its own and its parts' declarations, plus what
/// its `export`s let through.
Set<String> _exported(String path, Set<String> seen) {
  if (!seen.add(path)) return {};
  final dir = File(path).parent.path;
  final source = File(path).readAsStringSync();
  final names = _declared(source);
  for (final m in _directive.allMatches(source)) {
    if (m[2]!.contains(':')) continue; // dart: and package: exports are not this package's names
    final target = '$dir/${m[2]}';
    if (m[1] == 'part') {
      names.addAll(_declared(File(target).readAsStringSync()));
      continue;
    }
    final combinator = _combinator.firstMatch(m[3]!);
    final listed = {...?combinator?[2]?.split(',').map((n) => n.trim()).where((n) => n.isNotEmpty)};
    final from = _exported(target, {...seen});
    names.addAll(switch (combinator?[1]) {
      'show' => from.where(listed.contains),
      'hide' => from.where((n) => !listed.contains(n)),
      _ => from,
    });
  }
  return names;
}

/// Top-level public declarations in [source]: formatted code starts each at column 0, outside
/// a multi-line string.
Set<String> _declared(String source) {
  final names = <String>{};
  var inString = false;
  for (final line in source.split('\n')) {
    final skip = inString || _skip.hasMatch(line);
    if (_multiline.allMatches(line).length.isOdd) inString = !inString;
    if (skip) continue;
    final name = _type.firstMatch(line)?[1] ?? _memberName(line);
    if (name != null && !name.startsWith('_')) names.add(name);
  }
  return names;
}

/// The name a top-level function, getter or variable declares: the last word before its
/// parameters or initializer, once generics and function types are taken out.
String? _memberName(String line) {
  var s = line.replaceAll(_functionType, 'Fn');
  for (var before = ''; before != s;) {
    before = s;
    s = s.replaceAll(_generic, '');
  }
  final end = s.indexOf(_end);
  return end < 0 ? null : _lastWord.firstMatch(s.substring(0, end))?[1];
}

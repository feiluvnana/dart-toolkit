import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Every library a script may import; each example sees them all.
const _libraries = [
  'archive',
  'async',
  'chrome',
  'cli',
  'collection',
  'core',
  'hash',
  'html',
  'http',
  'image',
  'json',
  'native',
  'path',
  'process',
  'scrape',
  'torrent',
  'tui',
  'xml',
];

/// The documents whose ` ```dart ` blocks must compile.
const _documents = ['README.md'];

/// Compiles every ` ```dart ` block of README.md.
///
/// Each block becomes one file: its `import`s and its type declarations (`class`, `enum`,
/// `extension`, `mixin`, `typedef`, from a line that starts at the block's margin) at the top
/// level, everything else the body of an `async` function, so a block reads as a script does.
/// What a block uses without declaring it comes from `doc_examples_prelude.dart`, which gives
/// each free name one type. A relative import resolves against `test/`.
///
/// A block that cannot compile (an outline, a signature) is fenced ` ```dart skip `; keep them
/// rare. The files are checked by `dart analyze`; an error fails the test, named by the
/// document line it came from.
void main() {
  test('every dart example in README.md compiles', () async {
    final examples = [for (final doc in _documents) ..._examples(doc)];
    expect(examples, isNotEmpty);
    final dir = Directory.systemTemp.createTempSync('doc_examples_');
    addTearDown(() => dir.deleteSync(recursive: true));
    _packageConfig(dir);
    final origins = <String, List<String>>{};
    for (final (i, example) in examples.indexed) {
      final name = 'example_$i.dart';
      final (source, lines) = _program(example);
      File('${dir.path}/$name').writeAsStringSync(source);
      origins[name] = lines;
    }
    final result = await Process.run(Platform.resolvedExecutable, ['analyze', '--format=machine', dir.path]);
    final errors = [
      for (final line in LineSplitter.split('${result.stdout}\n${result.stderr}'))
        if (line.startsWith('ERROR|')) _located(line, origins),
    ];
    if (errors.isNotEmpty) fail('${errors.length} errors in the examples:\n${errors.join('\n')}');
    expect(result.exitCode, lessThan(4), reason: '${result.stderr}');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a block is split into declarations and a body', () {
    final (source, _) = _program((
      doc: 'X.md',
      line: 1,
      lines: [
        "import 'package:x/y.dart';",
        'enum Stage { dev, production }',
        'final class Thing {',
        "  final s = '}';",
        '}',
        'final n = Stage.dev;',
        'Future<void> main() async {}',
      ],
    ));
    final body = source.substring(source.indexOf('Future<dynamic> example() async {'));
    expect(source.indexOf("import 'package:x/y.dart';"), lessThan(source.indexOf('example()')));
    expect(source.indexOf('final class Thing {'), lessThan(source.indexOf('example()')));
    expect(body, contains('final n = Stage.dev;'));
    expect(body, contains('Future<void> main() async {}'));
    expect(body, isNot(contains('enum Stage')));
  });
}

/// One fenced block: where it starts and its lines, the fence's indent removed.
typedef _Example = ({String doc, int line, List<String> lines});

final _fence = RegExp(r'^(\s*)```dart(\s+skip)?\s*$');
final _close = RegExp(r'^\s*```\s*$');
final _topLevel = RegExp(
  r'^(@\w|import |export |typedef |extension type |((abstract|sealed|final|base|interface|mixin) )*(class|enum|mixin|extension) )',
);

Iterable<_Example> _examples(String doc) sync* {
  final lines = File(doc).readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final open = _fence.firstMatch(lines[i]);
    if (open == null) continue;
    final indent = open[1]!.length;
    final start = i + 1;
    final body = <String>[];
    for (i++; i < lines.length && !_close.hasMatch(lines[i]); i++) {
      body.add(lines[i].length >= indent ? lines[i].substring(indent) : lines[i].trimLeft());
    }
    if (open[2] == null) yield (doc: doc, line: start + 1, lines: body);
  }
}

/// [example] as a library, and the document line of each of its lines (`''` for generated ones).
(String, List<String>) _program(_Example example) {
  final top = <(String, String)>[];
  final body = <(String, String)>[];
  var depth = 0;
  var declaring = false;
  for (final (i, line) in example.lines.indexed) {
    final origin = '${example.doc}:${example.line + i}';
    if (!declaring && depth == 0 && _topLevel.hasMatch(line)) declaring = true;
    (declaring ? top : body).add((_imported(line), origin));
    depth += _braces(line);
    if (declaring && depth == 0 && (line.trimRight().endsWith('}') || line.trimRight().endsWith(';'))) {
      declaring = false;
    }
  }
  final out = <(String, String)>[
    ('// ignore_for_file: type=lint, unused_import, unused_local_variable, unused_element', ''),
    for (final lib in ['async', 'convert', 'io', 'typed_data']) ("import 'dart:$lib';", ''),
    for (final lib in _libraries) ("import 'package:dart_toolkit/$lib.dart';", ''),
    ("import '${Uri.file(File('test/doc_examples_prelude.dart').absolute.path)}';", ''),
    ...top,
    ('Future<dynamic> example() async {', ''),
    ...body,
    ('}', ''),
  ];
  return (out.map((l) => l.$1).join('\n'), out.map((l) => l.$2).toList());
}

/// [line], with a relative import resolved against `test/`.
String _imported(String line) {
  final relative = RegExp(r"^import '([\w/]+\.dart)';").firstMatch(line);
  if (relative == null) return line;
  return "import '${Uri.file(File('test/${relative[1]}').absolute.path)}';";
}

/// How many more `{` than `}` [line] holds outside strings and comments.
int _braces(String line) {
  var n = 0;
  String? quote;
  var raw = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == r'\' && !raw) {
        i++;
      } else if (c == quote) {
        quote = null;
      }
    } else if (c == "'" || c == '"') {
      quote = c;
      raw = i > 0 && line[i - 1] == 'r';
    } else if (c == '/' && i + 1 < line.length && line[i + 1] == '/') {
      break;
    } else if (c == '{') {
      n++;
    } else if (c == '}') {
      n--;
    }
  }
  return n;
}

/// A `.dart_tool/package_config.json` in [dir] that resolves this package's dependencies, so
/// the examples import `package:dart_toolkit` from outside the package.
void _packageConfig(Directory dir) {
  final source = File('.dart_tool/package_config.json');
  final config = jsonDecode(source.readAsStringSync()) as Map<String, Object?>;
  for (final package in (config['packages']! as List<Object?>).cast<Map<String, Object?>>()) {
    package['rootUri'] = '${source.absolute.uri.resolve(package['rootUri']! as String)}';
  }
  File('${dir.path}/.dart_tool/package_config.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(config));
}

/// An analyzer error line, named by the document line it came from.
String _located(String line, Map<String, List<String>> origins) {
  final [_, _, code, file, row, _, _, ...message] = line.split('|');
  final name = file.split(Platform.pathSeparator).last;
  final origin = origins[name]?[int.parse(row) - 1];
  return '${origin == null || origin.isEmpty ? '$name:$row' : origin}: ${message.join('|')} ($code)';
}

// Enforces the per-module third-party dependency budget.
//
// A member belongs to the module that owns its dependency, not the module that
// reads nicest at the call site. This check is what stops the graph re-tangling:
// adding an import that busts a budget fails CI until the budget is changed on
// purpose.
import 'dart:io';

const budgets = <String, Set<String>>{
  'archive': {'archive', 'path'},
  'async': {},
  'cli': {},
  'collection': {},
  'core': {},
  'fs': {'path'},
  'hash': {'crypto', 'path'},
  'html': {'http', 'path'},
  'http': {'http', 'path'},
  'process': {'path'},
  'util': {},
  'xml': {'http', 'path', 'xml'},
};

final _directive = RegExp(r"""^\s*(?:import|export|part)\s+'([^']+)'""", multiLine: true);

Set<String> closure(File entry) {
  final seen = <String>{};
  final packages = <String>{};
  final stack = <File>[entry];

  while (stack.isNotEmpty) {
    final file = stack.removeLast();
    if (!seen.add(file.path) || !file.existsSync()) continue;

    for (final match in _directive.allMatches(file.readAsStringSync())) {
      final uri = match.group(1)!;
      if (uri.startsWith('dart:')) continue;
      if (uri.startsWith('package:dart_toolkit/')) {
        stack.add(File('lib/${uri.substring('package:dart_toolkit/'.length)}'));
      } else if (uri.startsWith('package:')) {
        packages.add(uri.substring('package:'.length).split('/').first);
      } else {
        stack.add(File(Uri.file('${file.parent.path}/').resolve(uri).toFilePath()));
      }
    }
  }
  return packages;
}

/// Programs import modules, not the barrel: under `dart run` the front end compiles
/// the whole transitive closure on every invocation, and the barrel's closure is every
/// module and every dependency. Measured at ~1.4 s per run against ~0.3 s.
bool barrelFreePrograms() {
  var ok = true;
  for (final dir in ['bin', 'example']) {
    final root = Directory(dir);
    if (!root.existsSync()) continue;
    for (final file in root.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      if (file.readAsStringSync().contains("package:dart_toolkit/dart_toolkit.dart")) {
        stderr.writeln('BARREL   ${file.path} imports dart_toolkit.dart; import the modules it uses');
        ok = false;
      }
    }
  }
  if (ok) stdout.writeln('ok       programs    no barrel imports');
  return ok;
}

void main() {
  var failed = !barrelFreePrograms();

  for (final entry in budgets.entries) {
    final barrel = File('lib/${entry.key}.dart');
    if (!barrel.existsSync()) {
      stderr.writeln('MISSING  ${barrel.path}');
      failed = true;
      continue;
    }

    final actual = closure(barrel);
    final extra = actual.difference(entry.value).toList()..sort();
    if (extra.isEmpty) {
      stdout.writeln('ok       ${entry.key.padRight(11)} ${actual.length} dep(s)');
    } else {
      stderr.writeln('OVER     ${entry.key.padRight(11)} unbudgeted: ${extra.join(', ')}');
      failed = true;
    }
  }

  if (failed) exit(1);
}

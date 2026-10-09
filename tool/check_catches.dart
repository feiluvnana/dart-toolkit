/// Refuses a silent catch: every empty `catch (_) {}` and `.catchError((Object _) {})` under
/// `lib/` carries a `//` or `/* */` reason on its line, so swallowing an error is always a
/// decision someone wrote down. A typed `on FileSystemException catch (_) {}` needs one too.
///
/// `make check` runs this.
library;

import 'dart:io';

final _empty = RegExp(r'catch \(_\) \{\}|catchError\(\(Object _\) \{\}\)');

void main() {
  final silent = <String>[];
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final lines = entity.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!_empty.hasMatch(line)) continue;
      // The reason sits on the catch's own line, or on the line a formatter moved it to.
      final next = i + 1 < lines.length ? lines[i + 1].trimLeft() : '';
      if (line.contains('//') || line.contains('/*') || next.startsWith('//')) continue;
      silent.add('${entity.path}:${i + 1}: ${line.trim()}');
    }
  }
  if (silent.isEmpty) return;
  stderr
    ..writeln('Empty catch without a reason — add `// why` on the same line, or handle the error:')
    ..writeAll(silent.map((s) => '  $s\n'));
  exitCode = 1;
}

import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('a library imports only the libraries its layer allows', () {
    const allowedImports = <String, Set<String>>{
      'archive': {'core', 'native', 'path'},
      'async': {'core'},
      'chrome': {'async', 'core', 'html', 'http', 'json', 'message', 'path'},
      'cli': {'core', 'terminal'},
      'collection': {'core'},
      'core': {},
      'hash': {'core', 'native'},
      'html': {},
      'http': {'async', 'core', 'hash', 'message', 'native', 'path'},
      'image': {'core', 'native', 'path'},
      'json': {'collection', 'core', 'message'},
      'markup': {'collection', 'core', 'message'},
      'message': {},
      'native': {'core'},
      'path': {'core', 'native'},
      'process': {'core'},
      'scrape': {'core', 'html', 'http', 'json', 'markup', 'message', 'path'},
      'terminal': {'core'},
      'torrent': {'core', 'hash', 'native', 'path'},
      'tui': {'core', 'terminal'},
      'xml': {},
    };

    final libDir = Directory('lib');
    final importPattern = RegExp(r'''^\s*import\s+['"](?:\.\.\/|\.\/|src\/)?([a-zA-Z0-9_]+)\.dart['"]''');

    for (final entity in [...libDir.listSync(), ...Directory('lib/src').listSync()]) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final libName = entity.uri.pathSegments.last.replaceAll('.dart', '');
      final allowed = allowedImports[libName];
      expect(allowed, isNotNull, reason: 'Unrecognized library lib/$libName.dart not in layering table');

      final lines = entity.readAsLinesSync();
      for (final line in lines) {
        final match = importPattern.firstMatch(line);
        if (match != null) {
          final target = match.group(1)!;
          expect(
            allowed!.contains(target),
            isTrue,
            reason: 'lib/$libName.dart imports "$target.dart" which is not in the allowed list: ${allowed.toList()}',
          );
        }
      }
    }

    final internal = Directory('lib/src').listSync().whereType<File>().where((f) => f.path.endsWith('.dart'));
    for (final f in internal) {
      expect(
        allowedImports.containsKey(f.uri.pathSegments.last.replaceAll('.dart', '')),
        isTrue,
        reason: '${f.path} is a new internal library: add it to the table',
      );
    }
  });

  test('scrape shares its libraries\' helpers instead of copying them', () {
    final copied = {
      'lib/src/http/scrape.dart': ['_timedSend', '_drain', '_readCapped', '_BodyTooLarge', '_hostKey', '_replayable'],
    };
    for (final MapEntry(key: path, value: names) in copied.entries) {
      final src = File(path).readAsStringSync();
      for (final name in names) {
        final declared = RegExp(
          '^(?:final class |[A-Za-z][\\w<>?, ]* )$name\\b *[(<]|^final class $name\\b',
          multiLine: true,
        );
        expect(declared.hasMatch(src), isFalse, reason: '$path declares its own $name; use the shared one');
      }
    }
  });
}

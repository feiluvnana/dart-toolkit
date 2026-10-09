import 'dart:io';
import 'package:test/test.dart';

/// Every name here is internal: no public library may export it.
const hidden = {
  'html.dart': [
    'Selector',
    'TextRun',
    'parseHtml',
    'parseXml',
    'nameEnd',
    'scanAttributes',
    'inOrder',
    'rootOf',
    'MarkupInternals',
    'ElementInternals',
  ],
  'core.dart': [
    'CoerceBridge',
    'DetachableBridge',
    'FileBridge',
    'IoBridge',
    'ProcessBridge',
    'StatusInternals',
    'StoreInternals',
    'TaskInternals',
    'TextBridge',
    'TimeoutBridge',
  ],
  'process.dart': ['ShellInternals'],
  'cli.dart': ['TerminalBridge'],
  'tui.dart': ['TerminalBridge'],
  'http.dart': ['HttpBridge', 'HttpInternals', 'MessageInternals'],
  'path.dart': ['NativeBridge'],
};

void main() {
  test('internal names are not exported, and the tree has no public setters', () async {
    final dir = Directory.systemTemp.createTempSync('hidden');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/.dart_tool').createSync();
    final config = File(
      '.dart_tool/package_config.json',
    ).readAsStringSync().replaceFirst('"rootUri": "../"', '"rootUri": "${Directory.current.uri}"');
    File('${dir.path}/.dart_tool/package_config.json').writeAsStringSync(config);
    final probe = File('${dir.path}/probe.dart');
    Future<String> analyze(String source) async {
      probe.writeAsStringSync(source);
      return '${(await Process.run(Platform.resolvedExecutable, ['analyze', probe.path])).stdout}';
    }

    for (final MapEntry(key: lib, value: names) in hidden.entries) {
      final out = await analyze(
        "import 'package:dart_toolkit/$lib';\n"
        "void main() {\n${names.map((n) => '  print($n);').join('\n')}\n}\n",
      );
      for (final n in names) {
        expect(out, contains("'$n'"), reason: '$lib still exports $n');
      }
    }
    final out = await analyze(
      "import 'package:dart_toolkit/html.dart';\n"
      "void main() { final e = Element('a'); e.parent = null; e.slot = 0; print(e.internalNodes); }\n",
    );
    expect(out, allOf(contains("'parent'"), contains("'slot'"), contains("'internalNodes'")));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

import 'dart:io';
import 'package:test/test.dart';

/// The import graph stays shallow: a topic imports `dart:` and its own
/// `src/` tree only — never `package:` (rule 50: only what a program uses should
/// compile), and `src/` files import `dart:` plus relative paths only.
void main() {
  test('lib/ imports dart: and itself only', () {
    final packageImport = RegExp(r'''^\s*import\s+'package:''', multiLine: true);
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      expect(packageImport.hasMatch(src), isFalse, reason: '${entity.path} imports package: — use a relative path');
    }
  });

  test('dart:ffi compiles only behind the native seams', () {
    final ffiImport = RegExp(r'''^\s*import\s+'dart:ffi''', multiLine: true);
    // The three seams plus the modules that bind native symbols through them,
    // and the job runner they all share: nothing purely Dart may compile FFI
    // (rule 50).
    final allowed = {
      'lib/src/core/jobs.dart',
      'lib/src/core/native.dart',
      'lib/src/chrome/native.dart',
      'lib/src/tui/native.dart',
      'lib/src/archive/archive.dart',
      'lib/src/fs/io.dart',
      'lib/src/hash/hash.dart',
      'lib/src/process/process.dart',
      'lib/src/image/image.dart',
      'lib/src/chrome/chrome.dart',
      'lib/src/tui/term.dart',
    };
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (!ffiImport.hasMatch(entity.readAsStringSync())) continue;
      final normalized = entity.path.replaceAll(r'\', '/');
      expect(
        allowed.contains(normalized),
        isTrue,
        reason: '${entity.path} compiles dart:ffi outside a native seam (rule 43)',
      );
    }
  });
}

import 'dart:io';

import 'package:dart_toolkit/native.dart';
import 'package:test/test.dart';

void main() {
  test('the prebuilt library loads, and says so', () {
    expect(NativeLib.reason, isNull);
    expect(NativeLib.isAvailable, isTrue);
  }, skip: NativeLib.isAvailable ? null : 'dart_toolkit_native did not load: ${NativeLib.reason}');

  test('DART_TOOLKIT_NATIVE is the only place looked when set, and a failure says why', () async {
    Future<String> reason(String override) async {
      final r = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/fixtures/native_reason.dart'],
        environment: {'DART_TOOLKIT_NATIVE': override},
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return '${r.stdout}'.trim();
    }

    final notFoundReason = await reason('/nonexistent/lib.dylib');
    expect(notFoundReason, allOf(contains('not found: '), contains('nonexistent')));
    // A file that is not a library, rather than the bundled copy loading in its place.
    // Made absolute: the loader would search its own path for a relative name.
    expect(
      await reason('pubspec.yaml'),
      startsWith('${Directory.current.path}${Platform.pathSeparator}pubspec.yaml: '),
    );
  });

  test('DART_TOOLKIT_NATIVE empty is unset, and relative is against the working directory', () async {
    Future<String> reason(String override) async {
      final r = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/fixtures/native_reason.dart'],
        environment: {'DART_TOOLKIT_NATIVE': override},
      );
      return '${r.stdout}'.trim();
    }

    expect(await reason(''), 'null');
    expect(await reason('native/prebuilt/${NativeBridge.target}/${NativeBridge.fileName}'), 'null');
  }, skip: NativeLib.isAvailable ? null : 'dart_toolkit_native did not load');

  test('require hands over the library, or says why it cannot', () {
    if (NativeLib.isAvailable) {
      expect(NativeBridge.require(), isNotNull);
    } else {
      expect(() => NativeBridge.require(), throwsA(isA<UnsupportedError>()));
    }
  });

  test('the file name and target are this platform\'s', () {
    expect(NativeBridge.fileName, contains('dart_toolkit_native'));
    expect(NativeBridge.target, matches(RegExp(r'^(macos|linux|windows)_(arm64|x64)$')));
  });
}

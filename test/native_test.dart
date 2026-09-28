import 'package:dart_toolkit/native.dart';
import 'package:test/test.dart';

void main() {
  test('the prebuilt library loads, and says so', () {
    expect(NativeLib.reason, isNull);
    expect(NativeLib.isAvailable, isTrue);
  }, skip: NativeLib.isAvailable ? null : 'dart_toolkit_native did not load: ${NativeLib.reason}');

  test('version is read once', () {
    expect(NativeLib.version, greaterThan(0));
    expect(NativeLib.version, NativeLib.version);
  }, skip: NativeLib.isAvailable ? null : 'dart_toolkit_native did not load');

  test('require hands over the library, or says why it cannot', () {
    if (NativeLib.isAvailable) {
      expect(NativeBridge.require('x'), isNotNull);
    } else {
      expect(() => NativeBridge.require('hashing'), throwsA(isA<UnsupportedError>()));
    }
  });

  test('the file name and target are this platform\'s', () {
    expect(NativeBridge.fileName, contains('dart_toolkit_native'));
    expect(NativeBridge.target, matches(RegExp(r'^(macos|linux|windows)_(arm64|x64)$')));
  });
}

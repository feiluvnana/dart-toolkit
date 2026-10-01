// Prints why dart_toolkit_native did not load, for native_test.dart, which runs this with
// DART_TOOLKIT_NATIVE set: the variable is read once, when the library is first asked for.
import 'package:dart_toolkit/native.dart';

void main() => print(NativeLib.reason);

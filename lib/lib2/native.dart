/// # Native seam (`lib2`)
///
/// [Lib2Native] over the `dart_toolkit_native` cdylib (ABI 1), the only way
/// past the seam. Import this topic — never `dart:ffi`
/// directly — so only programs that make a native call compile FFI (r56).
library;

export 'src/core/native.dart';

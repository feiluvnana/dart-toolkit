/// # Native seam (`dart_toolkit_native`)
///
/// [Native] tells whether the native libraries load; the loader itself lives
/// in `src/core/native.dart` for the other seam files only. Import this topic
/// — never `dart:ffi` directly — so only programs that make a native call
/// compile FFI (rule 50).
library;

export 'src/core/errors.dart';
export 'src/core/native.dart' show Native;
export 'src/core/pipe.dart';
export 'src/core/traits.dart';

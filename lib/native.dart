/// # Native
///
/// `Native`: the package's Rust libraries behind `hash`, `archive`, `http` and `image`.
/// `Native.check()` says whether they load (it reads files only); `Native.install()` is the one
/// thing that downloads or compiles them.
///
/// {@category Native}
library;

export 'src/native.dart' show Native, NativeCheck, NativeException;

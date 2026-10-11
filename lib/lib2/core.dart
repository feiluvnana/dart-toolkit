/// # Core
///
/// The Rust-like base traits every module stands on ([Reader], [Writer], [Closer],
/// [Seeker]) and the universal [pipe] primitive that connects them. No dependencies.
library;

export 'src/core/pipe.dart';
export 'src/core/traits.dart';

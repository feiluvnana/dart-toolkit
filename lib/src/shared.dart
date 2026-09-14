/// Shared instances used across libraries.
///
/// The [Environment] lives here, outside the domain files, so that `cli` can
/// read it without importing `system` and `system` can expose it without
/// importing `cli`: `cli` resolves an option's `env:` fallback through the same
/// instance that [env] exposes.
library;

import '../system/env.dart';

/// The single [Environment] behind the top-level `env`.
final Environment sharedEnv = Environment();

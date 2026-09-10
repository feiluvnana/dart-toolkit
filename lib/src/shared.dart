/// Shared accessor instances used across domains.
///
/// The [EnvAccessor] lives here, outside the domain files, so that `cli` can
/// read it without importing `system` and `system` can expose it without
/// importing `cli`: `cli` resolves an option's `env:` fallback through the same
/// accessor that `system.env` mutates.
library;

import '../system/env.dart';

/// The single [EnvAccessor] behind `system.env`.
final EnvAccessor sharedEnv = EnvAccessor();

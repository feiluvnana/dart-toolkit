/// Shared accessor instances used across the `system` domain.
///
/// These live here, outside the domain files, so that sub-namespaces can reach
/// one another's state without importing each other: `system.cli` resolves
/// option defaults through the same [EnvAccessor] that `system.env` mutates.
library;

import '../system/env.dart';

/// The single [EnvAccessor] behind `system.env`.
final EnvAccessor sharedEnv = EnvAccessor();

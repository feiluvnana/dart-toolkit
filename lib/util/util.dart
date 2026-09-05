import 'console/console.dart';
import 'git.dart';
import 'time.dart';

export 'console/console.dart';
export 'git.dart';
export 'time.dart';

// ============================================================================
// UTIL DOMAIN (util.*) - Time, Git, Terminal & Console Tools
// ============================================================================

/// Top-level Utilities accessor singleton (`util.*`).
///
/// Provides unified access to time/delays, Git operations, and console/terminal formatting.
///
/// ```dart
/// // Delays and timestamps
/// await util.time.wait(100);
/// final stamp = util.time.stamp();
///
/// // Terminal & logging
/// util.console.logger.ok('Task done');
///
/// // Git inspection
/// final branch = await util.git.branch();
/// ```
const UtilAccessor util = UtilAccessor();

/// Top-level Utilities domain accessor.
class UtilAccessor {
  const UtilAccessor();

  /// Sub-namespace for time, delays, benchmarks, and timestamps (`util.time.*`).
  TimeAccessor get time => const TimeAccessor();

  /// Sub-namespace for Git version control automation (`util.git.*`).
  GitAccessor get git => const GitAccessor();

  /// Sub-namespace for terminal output, logging, tables, and prompts (`util.console.*`).
  ConsoleAccessor get console => const ConsoleAccessor();
}

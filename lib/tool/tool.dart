/// # Tool Domain (`tool.*`)
///
/// Wrappers around capabilities that exist outside Dart: an executable, or a
/// file format. One name per tool — `tool.git`, `tool.zip` — because each of
/// them would pass every other test for a top-level name and they arrive with
/// siblings. See Rule 2 in `NAMESPACE.md`.
///
/// ```dart
/// if (await tool.git.dirty()) return;
/// await tool.zip.pack('site', 'site.zip');
/// ```
library;

import 'git.dart';
import 'zip.dart';

export 'git.dart';
export 'zip.dart';

// ============================================================================
// TOOL DOMAIN (tool.*) - Wrapped Executables & Formats
// ============================================================================

/// The `tool` domain: wrapped executables and file formats.
const ToolAccessor tool = ToolAccessor();

/// Entry point for the wrapped tools, reachable as [tool].
///
/// Each tool keeps its own vocabulary; this type only holds the names, so
/// adding one is a getter here and a file beside this one.
///
/// ```dart
/// final branch = await tool.git.branch();
/// await tool.zip.unpack('release.tar.gz', 'out');
/// ```
class ToolAccessor {
  /// Creates the accessor. Prefer the shared [tool] instance.
  const ToolAccessor();

  /// The `git` executable: branch, hash, tags, cleanliness, and [GitAccessor.run]
  /// for everything else.
  GitAccessor get git => const GitAccessor();

  /// Archives: packing, unpacking, inspecting and raw (de)compression.
  ZipAccessor get zip => const ZipAccessor();
}

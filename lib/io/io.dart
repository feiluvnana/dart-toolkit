import 'csv.dart';
import 'file.dart';
import 'store.dart';

export 'csv.dart';
export 'file.dart';
export 'store.dart';

// ============================================================================
// IO DOMAIN (io.*) - File System, Paths, CSV, Store & Archives
// ============================================================================

final StoreAccessor _ioStore = StoreAccessor();

/// Top-level Input/Output accessor singleton (`io.*`).
///
/// Provides unified access to file operations, CSV processing, key-value storage, and archives.
///
/// ```dart
/// // File operations
/// await io.write('data.txt', 'content');
/// final exists = io.has('data.txt');
///
/// // Sub-namespaces
/// final records = await io.csv.read('users.csv');
/// io.store.set('key', 'value');
/// final arch = io.archive('backup.7z');
/// ```
const IoAccessor io = IoAccessor();

/// Top-level Input/Output domain accessor extending [FsAccessor].
class IoAccessor extends FsAccessor {
  const IoAccessor();

  /// Sub-namespace for file and path operations (`io.file.*`).
  FsAccessor get file => this;

  /// Sub-namespace for CSV parsing, serialization, and file I/O (`io.csv.*`).
  CsvAccessor get csv => const CsvAccessor();

  /// Sub-namespace for persistent JSON key-value storage (`io.store.*`).
  StoreAccessor get store => _ioStore;
}

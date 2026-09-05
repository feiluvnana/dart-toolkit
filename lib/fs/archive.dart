import 'dart:io';

import '../console/console.dart';
import '../sys/sys.dart';
import 'fs.dart';

// ============================================================================
// ARCHIVE COMPRESSION & INTEGRITY (7-Zip)
// ============================================================================

/// Archive compression, integrity testing, and volume management utility.
///
/// Wraps 7-Zip CLI (`7z`) with 1-word methods (`check`, `zip`, `wipe`, `sync`).
/// Automatically discovers `7z.exe` in `PATH` or standard installation locations.
///
/// ```dart
/// final arch = Archive('releases/dist.7z');
/// if (await arch.check()) {
///   print('Archive is valid');
/// } else {
///   await arch.zip('build/');
/// }
/// ```
class Archive {
  /// Target archive file path.
  final String path;

  /// Creates an [Archive] bound to [path].
  Archive(this.path);

  /// Whether the archive file exists and is non-empty.
  bool get exists => Fs.has(File(path));

  /// Locates the 7-Zip (`7z`) binary in `PATH` or standard program directories.
  static String? which({List<String>? paths}) {
    return Proc.which('7z', paths: [
      r'D:\dev\winget\7zip.7zip\7z.exe',
      r'C:\Program Files\7-Zip\7z.exe',
      r'C:\Program Files (x86)\7-Zip\7z.exe',
      ...?paths,
    ]);
  }

  /// Tests the structural integrity of [archivePath] using 7-Zip's test command (`7z t`).
  static Future<bool> test(String archivePath, {String? exe}) async {
    final bin = exe ?? which();
    if (bin == null) return false;
    final res = await Proc.run(bin, ['t', archivePath]);
    return res.ok;
  }

  /// Compresses [sourcePath] into [archivePath] with compression [level] (0-9).
  static Future<ProcResult> pack(
    String archivePath,
    String sourcePath, {
    int level = 5,
    bool inherit = true,
    String? exe,
  }) async {
    final bin = exe ?? which();
    if (bin == null) {
      return ProcResult(code: 1, stdout: '', stderr: '7z executable not found');
    }
    return Proc.run(
      bin,
      ['a', '-mx=$level', '-bsp1', archivePath, sourcePath],
      inherit: inherit,
    );
  }

  /// Deletes [archivePath] and any matching split multi-volume parts (e.g. `.7z.001`, `.7z.002`).
  static int clean(String archivePath) {
    final file = File(archivePath);
    final dir = file.parent;
    final name = file.uri.pathSegments.last;
    return Fs.delete(
      dir,
      pattern: RegExp(
        '^${RegExp.escape(name)}(\\.\\d+)?\$',
        caseSensitive: false,
      ),
    );
  }

  /// Verifies the integrity of this archive file.
  Future<bool> check({String? exe}) => Archive.test(path, exe: exe);

  /// Compresses [sourcePath] into this archive file.
  Future<ProcResult> zip(
    String sourcePath, {
    int level = 5,
    bool inherit = true,
    String? exe,
  }) =>
      Archive.pack(
        path,
        sourcePath,
        level: level,
        inherit: inherit,
        exe: exe,
      );

  /// Wipes this archive file and any split volume segments.
  int wipe() => Archive.clean(path);

  /// Synchronizes [source] directory into this archive.
  ///
  /// Checks whether an existing archive is intact before rebuilding unless [force] is true.
  /// Automatically displays progress in the console.
  ///
  /// ```dart
  /// await arch.sync('data/', force: false);
  /// ```
  Future<String> sync(
    String source, {
    bool force = false,
    bool changed = true,
    int level = 5,
  }) async {
    final sourceDir = Directory(source);
    if (!sourceDir.existsSync()) {
      Console.warn('"$source" directory not found, skipping compression.');
      return 'Source folder missing';
    }

    final bin = which();
    if (bin == null) {
      Console.error('7z.exe not found in PATH or standard folders.');
      return '7z not found';
    }

    final file = File(path);
    if (!force && !changed && file.existsSync()) {
      Console.write('Checking existing archive ($path)... ');
      if (await check(exe: bin)) {
        Console.ok('Archive is intact and up-to-date, skipping compression.');
        return 'Intact (up to date)';
      }
      Console.warn('Archive check failed. Recreating archive...');
    }

    Console.step(7, 7, 'Compressing "$source" into $path (1 volume)...');
    wipe();

    final res = await zip(source, level: level, exe: bin, inherit: true);
    if (res.ok) {
      Console.ok('Successfully compressed $path into project root.');
      return 'Created / Updated';
    } else {
      Console.error('Compression failed with exit code ${res.code}.');
      return 'Failed (${res.code})';
    }
  }
}

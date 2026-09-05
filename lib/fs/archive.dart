import 'dart:io';

import '../console/console.dart';
import '../sys/sys.dart';
import 'fs.dart';

// ============================================================================
// ARCHIVE COMPRESSION & INTEGRITY (7-Zip)
// ============================================================================

/// Archive compression and integrity testing utility with 1-word methods.
class Archive {
  final String path;

  Archive(this.path);

  bool get exists => Fs.has(File(path));

  static String? which({List<String>? paths}) {
    return Proc.which('7z', paths: [
      r'D:\dev\winget\7zip.7zip\7z.exe',
      r'C:\Program Files\7-Zip\7z.exe',
      r'C:\Program Files (x86)\7-Zip\7z.exe',
      ...?paths,
    ]);
  }

  static Future<bool> test(String archivePath, {String? exe}) async {
    final bin = exe ?? which();
    if (bin == null) return false;
    final res = await Proc.run(bin, ['t', archivePath]);
    return res.ok;
  }

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

  Future<bool> check({String? exe}) => Archive.test(path, exe: exe);

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

  int wipe() => Archive.clean(path);

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

/// The `PATH` walk shared by `ShellUtils.which`, `tool()` and `chrome`'s browser lookup
/// (chrome cannot import shell).
library;

import 'dart:io' as io;

/// The first of [programs] on `PATH` (with `PATHEXT` on Windows): the
/// folders in order, each name in each folder; null when none is
/// installed. A name with a path separator is checked as that path.
/// Starts no process.
Future<String?> which(List<String> programs) async {
  final windows = io.Platform.isWindows;
  final pathext = windows
      ? (io.Platform.environment['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD')
          .split(';')
          .where((e) => e.isNotEmpty)
          .toList()
      : const <String>[];
  Future<String?> probe(String base) async {
    final exts = !windows
        ? const ['']
        : (base.contains('.') ? ['', ...pathext] : [...pathext, '']);
    for (final ext in exts) {
      final path = '$base$ext';
      final st = await io.FileStat.stat(path);
      if (st.type != io.FileSystemEntityType.file) continue;
      if (windows || st.mode & 0x49 != 0) return path; // any execute bit (0o111)
    }
    return null;
  }

  bool isPath(String program) => program.contains('/') || (windows && program.contains(r'\'));
  for (final path in programs.where(isPath)) {
    final hit = await probe(path);
    if (hit != null) return hit;
  }
  final names = programs.where((program) => !isPath(program)).toList();
  if (names.isEmpty) return null;
  for (final dir in (io.Platform.environment['PATH'] ?? '').split(windows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    for (final name in names) {
      final hit = await probe('$dir${windows ? r'\' : '/'}$name');
      if (hit != null) return hit;
    }
  }
  return null;
}

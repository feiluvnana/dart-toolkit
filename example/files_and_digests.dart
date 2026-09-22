import 'package:dart_toolkit/dart_toolkit.dart';

/// Tidying a directory: find the files, hash them to spot duplicates, archive the result and
/// verify it. Everything happens under a temporary directory that is removed at the end.
Future<void> main() async {
  final root = Path.temp / 'toolkit_files_demo';
  final zip = Path.temp / 'toolkit_files_demo.zip';
  final restored = Path.temp / 'toolkit_files_restored';

  try {
    Console.rule('Writing a small tree');

    // Writes create the parent directories, so a tree does not need laying out first.
    await (root / 'a/notes.txt').writeText('same content\n');
    await (root / 'b/notes-copy.txt').writeText('same content\n');
    await (root / 'b/other.txt').writeText('different content\n');
    await (root / 'c/nested/deep.md').writeText('# heading\n\nbody\n');
    Console.ok('four files under $root');

    Console.rule('Finding them');

    // `glob` understands `*`, `**` and `?`. `files` walks without a pattern.
    final texts = await root.glob('**/*.txt').toList();
    final everything = await root.files(recursive: true).toList();
    Console.info('*.txt      ${texts.map((f) => f.name).join(', ')}');
    Console.info('every file ${everything.length}, total ${await root.size()} bytes');

    Console.rule('Duplicates by content, not by name');

    // Hash them all at once, then group by digest. Two modules meeting: `parallelize` from
    // async, `groupBy` from collection, digests from hash.
    final hashed = await everything.parallelize((f) async => (digest: await f.hash(Hash.sha256), file: f));
    final groups = hashed.rights.sequence.groupBy((h) => h.digest);

    for (final group in groups.where((g) => g.length > 1)) {
      Console.warn(
        '${group.length} copies of ${group.key.substring(0, 12)}…: '
        '${group.map((h) => h.file.relativeTo(root)).join(' = ')}',
      );
    }
    Console.info('${groups.length} distinct contents in ${everything.length} files');

    Console.rule('Archiving');

    // The archive lives outside the tree it packs. The format comes from the extension.
    await root.archiveTo(zip);
    final entries = await zip.archiveEntries();
    Console.ok('${zip.name}: ${await zip.size()} bytes, ${entries.where((e) => !e.isDir).length} files');
    for (final entry in entries.where((e) => !e.isDir)) {
      Console.info('  ${entry.name} (${entry.size} B)');
    }

    await zip.extractTo(restored);
    Console.ok('restored ${await restored.files(recursive: true).length} files into ${restored.name}');

    // A single-stream codec, when there is one file rather than a tree. The destination has
    // to be kept in a variable: these operations answer with a dart:io File, not a Path.
    final gz = root / 'c/nested/deep.md.gz';
    await (root / 'c/nested/deep.md').compressTo(gz);
    Console.info('gzip: ${gz.name} is ${await gz.size()} bytes');

    Console.rule('Verifying, the way a release does');

    final digest = await zip.hash(Hash.sha256);
    Console.info('sha256 ${digest.substring(0, 24)}…');
    // Compare a digest against one from elsewhere without leaking where it first differs.
    Console.ok('matches a second pass: ${Secure.equals(digest.hexBytes, await zip.hashBytes(Hash.sha256))}');
    Console.info('crc32 of the same file: ${await zip.checksum(Hash.crc32)} (a checksum, not a signature)');

    Console.rule('Paths are strings, with the parts named');

    final report = 'reports/2025/Q3 summary.final.md'.path;
    Console.info('name ${report.name} · stem ${report.stem} · ext ${report.ext}');
    Console.info('parent ${report.parent} · as PDF ${report.withExt('pdf')}');
    Console.info('segments ${report.segments.join(' › ')}');
    // A title from a page or a user is one component, never a path.
    Console.info("a scraped title: ${'AC/DC: Live at Donington'.filename}");
  } finally {
    for (final path in [root, zip, restored]) {
      await path.delete(recursive: true);
    }
    Console.info('cleaned up');
  }
}

/// # I/O & Filesystem
///
/// [File] and [Dir] with dead-simple one-word methods: a file is a [Source]
/// and a [Target], so readings (`text`, `bytes`, `lines`) and [pipe] work on
/// it directly. Writes replace atomically.
library;

export 'src/fs/io.dart' hide renameFile, sandbox;
export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';

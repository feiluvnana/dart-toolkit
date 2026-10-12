/// # I/O & Filesystem
///
/// [File] and [Dir] objects: a file is a [Source] and a [Target], so readings (`text`,
/// `bytes`, `lines`) and `pipe` work on it directly. Writes replace atomically and keep the
/// file's mode; copies and moves complete the destination before the source goes.
library;

export 'src/fs/io.dart' hide renameFile, sandbox;
export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';

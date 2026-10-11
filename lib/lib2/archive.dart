/// # Archives
///
/// `Archive.pack`, `unpack`, `list`, `extract` and `open` for ZIP, TAR and
/// gzip — plus in-memory `zip`/`unzip` and `gzip`/`gunzip`. `open` streams a
/// single member as a `Reader`; every member is sandbox-checked before
/// anything is written.
library;

export 'src/archive/archive.dart';
export 'src/core/errors.dart';

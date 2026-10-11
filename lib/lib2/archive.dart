/// # Archives
///
/// `Archive.pack`, `unpack`, `list`, `extract` and `open` for ZIP, TAR,
/// compressed tars (`.tar.gz`, `.tar.xz`, `.tar.zst`, `.tar.bz2`) and gzip —
/// plus in-memory `zip`/`unzip` and `gzip`/`gunzip` (7z/rar read, never
/// written). `open` streams a single member as a `Reader`; every member is
/// sandbox-checked before anything is written.
library;

export 'src/archive/archive.dart';
export 'src/core/errors.dart';

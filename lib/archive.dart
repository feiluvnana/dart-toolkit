/// # Archives
///
/// `dir.pack`, `source.unpack` and `file.entries`/`entry` for ZIP, TAR,
/// compressed tars (`.tar.gz`, `.tar.xz`, `.tar.zst`, `.tar.bz2`) and gzip —
/// plus in-memory `Archive.zip`/`unzip` and `gzip`/`gunzip` (7z/rar read,
/// never written). `entry` streams a single member as a `Source`; every
/// member is sandbox-checked before anything is written. Unpacking a download
/// streams through the native unpack sink.
library;

export 'src/archive/archive.dart';
export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';

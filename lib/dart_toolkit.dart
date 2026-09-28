/// # Dart Toolkit
///
/// Everything, in one import. The parsers and the client are in-house, so this costs about the
/// same as the five modules a scraper would list by hand (measured: within 70 ms); a program
/// that wants less imports `core.dart`, `fs.dart`, `http.dart`… individually.
///
/// One module is deliberately not here: `ffi.dart`, which calls C libraries in one line. Its
/// names — `Ffi`, `C`, `Lib`, `Fn` — are short enough to be worth having only where a program
/// asked for them, so it is imported on its own.
library;

export 'async.dart';
export 'cli.dart';
export 'collection.dart';
export 'core.dart';
export 'formats.dart';
export 'fs.dart';
export 'hash.dart';
export 'http.dart';
export 'native.dart';
export 'process.dart';

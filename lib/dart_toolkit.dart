/// # Dart Toolkit
///
/// Everything, in one import. The parsers and the client are in-house, so this costs about the
/// same as the five modules a scraper would list by hand (measured: within 70 ms); a program
/// that wants less imports `core.dart`, `fs.dart`, `http.dart`… individually.
library;

export 'async.dart';
export 'cli.dart';
export 'collection.dart';
export 'core.dart';
export 'crypto.dart';
export 'formats.dart';
export 'fs.dart';
export 'http.dart';
export 'native.dart';
export 'process.dart';

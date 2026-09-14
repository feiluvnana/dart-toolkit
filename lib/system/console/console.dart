/// # Console
///
/// Terminal output and input, split into sub-namespaces: [ConsoleLogger] for
/// status lines, [ConsoleWriter] for tables, boxes and rules, [ConsoleReader]
/// for prompts, plus [Terminal] and [Cursor] for raw control.
library;

import 'ansi.dart';
import 'logger.dart';
import 'progress.dart';
import 'reader.dart';
import 'terminal.dart';
import 'writer.dart';

export 'ansi.dart';
export 'logger.dart';
export 'progress.dart';
export 'reader.dart';
export 'spinner.dart';
export 'table.dart';
export 'terminal.dart';
export 'writer.dart';

final ConsoleWriter _writer = sharedConsoleWriter;
final ConsoleLogger _logger = ConsoleLogger(_writer);
final ConsoleReader _reader = ConsoleReader();

/// The shared status logger.
ConsoleLogger get logger => _logger;

/// The shared terminal console writer.
ConsoleWriter get consoleWriter => _writer;

/// The shared terminal reader.
ConsoleReader get consoleReader => _reader;

/// Progress bar for tracking multi-step terminal tasks.
typedef ProgressBar = Progress;

/// ANSI styling helper.
const Ansi ansi = Ansi();

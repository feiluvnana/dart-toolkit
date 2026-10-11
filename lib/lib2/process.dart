/// # Processes
///
/// `Process.run` for one-shot commands with captured output, or the `Process`
/// constructor for a streaming child: a `Reader` over stdout and a `Writer`
/// into stdin, with `line()`/`lines()` streaming, `wait(timeout:)` and
/// `cancel()` — both of which kill the whole process tree.
library;

export 'src/process/process.dart';

/// # Processes & Shell
///
/// Running programs: `Command` values and pipelines, `Shell.run`/`sh`/`interact`/`open`/`which`,
/// the `Run` task and its readings, and `Runner.fake` for tests.
///
/// {@category System}
library;

export 'core.dart';
export 'src/process/process.dart' hide ShellInternals;

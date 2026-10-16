/// Every `Console.log` line of the run, for `Region.log` to draw and
/// `Console.logged()` to save: shared by `console` and `tui`, which never
/// import each other.
library;

/// One logged line.
typedef LogLine = ({DateTime at, String text, bool failed});

/// The run's lines, oldest first.
final logbook = <LogLine>[];

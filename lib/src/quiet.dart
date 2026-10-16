/// Programs whose stderr the toolkit keeps to itself: `Shell.read` shows a
/// program's stderr as it runs, but an engine run (ffmpeg's progress pass)
/// marks its reader here, so its stderr is only captured for the error.
library;

/// `Shell.read` readers whose stderr is captured, never shown.
final quiet = Expando<bool>();

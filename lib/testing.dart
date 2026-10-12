/// Test seams: fakes and in-memory readers/writers. Never needed by a script.
library;

export 'src/cli/cli.dart' show CliFake;
export 'src/core/native_status.dart' show NativeReset;
export 'src/testing/buffers.dart';
export 'src/testing/fake_terminal.dart' show FakeBackend, FakeTerminal;
export 'src/tui/buffer.dart' show ColorLevel;

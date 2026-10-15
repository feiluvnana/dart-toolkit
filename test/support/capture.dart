import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Run [body] with `print`, `stdout` and `stderr` captured, so a test can
/// assert what a command prints instead of leaking it into the test log.
Future<({T value, String out, String err})> capture<T>(FutureOr<T> Function() body) async {
  final out = _Sink(), err = _Sink();
  final value = await IOOverrides.runZoned(
    () => runZoned(body, zoneSpecification: ZoneSpecification(print: (_, _, _, line) => out.writeln(line))),
    stdout: () => out,
    stderr: () => err,
  );
  return (value: value, out: out.text, err: err.text);
}

class _Sink implements Stdout {
  final _buf = StringBuffer();
  String get text => _buf.toString();

  @override
  Encoding encoding = utf8;
  @override
  String lineTerminator = '\n';
  @override
  bool get hasTerminal => false;
  @override
  bool get supportsAnsiEscapes => false;
  @override
  int get terminalColumns => throw const StdoutException('not a terminal');
  @override
  int get terminalLines => throw const StdoutException('not a terminal');
  @override
  IOSink get nonBlocking => this;
  @override
  void write(Object? object) => _buf.write(object);
  @override
  void writeln([Object? object = '']) => _buf.writeln(object);
  @override
  void writeAll(Iterable<Object?> objects, [String sep = '']) => _buf.writeAll(objects, sep);
  @override
  void writeCharCode(int charCode) => _buf.writeCharCode(charCode);
  @override
  void add(List<int> data) => _buf.write(encoding.decode(data));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done => Future.value();
}

import 'dart:convert';
import 'dart:io';

import 'package:dart_toolkit/core.dart';
import 'package:test/test.dart';

/// A [Reader] over [text] encoded as UTF-8, with an optional [Origin].
final class Mem with Reader {
  Mem(String text, [Origin origin = const Origin()]) : this.bytes(utf8.encode(text), origin);

  /// A [Reader] over [bytes] in one chunk.
  Mem.bytes(this._bytes, [this._origin = const Origin()]);

  final List<int> _bytes;
  final Origin _origin;

  @override
  Origin origin() => _origin;

  @override
  Stream<List<int>> stream() => Stream.value(_bytes);
}

/// A [Reader] that yields [first], then fails with a [StateError].
final class BoomReader with Reader {
  BoomReader([this.first = const [1, 2, 3]]);

  final List<int> first;

  @override
  Stream<List<int>> stream() async* {
    yield first;
    throw StateError('reader blew up mid-write');
  }
}

/// A [Pipe] that fails with a [StateError] on its first chunk.
final class BoomPipe implements Pipe {
  @override
  Stream<List<int>> transform(Stream<List<int>> input) async* {
    await for (final _ in input) {
      throw StateError('boom');
    }
  }

  @override
  void abort(Object error) {}
}

/// A [Writer] that keeps every byte it is given in [data].
final class Collect with Writer {
  final data = <int>[];

  @override
  Future<void> consume(Stream<List<int>> input) async {
    await for (final c in input) {
      data.addAll(c);
    }
  }
}

/// A [Writer] that fails with a [StateError] on chunk number [at] (1-based).
final class BoomWriter with Writer {
  BoomWriter({this.at = 1});

  final int at;

  @override
  Future<void> consume(Stream<List<int>> input) async {
    var n = 0;
    await for (final _ in input) {
      if (++n == at) throw StateError('writer blew up mid-write');
    }
  }
}

/// A loopback HTTP server answering with [answer], closed when the test (or,
/// from `setUpAll`, the group) ends; returns it and its `http://127.0.0.1:port`.
Future<(HttpServer, String)> serve(void Function(HttpRequest request) answer) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen(answer);
  return (server, 'http://127.0.0.1:${server.port}');
}

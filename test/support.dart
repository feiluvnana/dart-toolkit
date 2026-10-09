/// The fixtures every test file shares: a temporary folder and a loopback server, each
/// cleaned up when the test that made it ends.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_toolkit/core.dart';
import 'package:test/test.dart';

/// A new, empty folder under the system temp, deleted with its contents when the test ends.
///
/// Called in `setUp`, it is one folder per test.
Path tempDir([String prefix = 'tk_test_']) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return Path(dir.path);
}

/// A loopback server handing each request to [route], then closing its response; the server
/// closes when the test ends. Answers the server and its URL, which ends in `/`.
///
/// A route that never completes leaves its request open: a stalled server.
Future<(HttpServer, Uri)> serve(FutureOr<void> Function(HttpRequest r) route) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((r) async {
    await route(r);
    try {
      await r.response.close();
    } catch (_) {
      // The route closed it, cut its socket, or the client left: nothing is left to close.
    }
  });
  addTearDown(() => server.close(force: true));
  return (server, Uri.parse('http://127.0.0.1:${server.port}/'));
}

/// Answers [r] with the headers of a [length]-byte body (an `etag` of `"v1"`, and
/// [range] as its `content-range`), sends [bytes] of it, and cuts the connection.
Future<void> cut(HttpRequest r, List<int> bytes, {required int length, int status = 200, String? range}) async {
  r.response
    ..statusCode = status
    ..contentLength = length;
  if (range != null) r.response.headers.set('content-range', range);
  r.response.headers.set('etag', '"v1"');
  final socket = await r.response.detachSocket();
  socket.add(bytes);
  await socket.flush();
  socket.destroy();
}

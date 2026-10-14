/// http: verbs return a Response (a 404 is a value); bodies stream, `check: true` throws on non-2xx.
/// A loopback server keeps this offline.
///
/// `dart run examples/http.dart`
library;

import 'dart:io' show ContentType, HttpException, HttpServer;

import 'package:dart_toolkit/http.dart';
import 'package:dart_toolkit/json.dart';

Future<void> main() async {
  final server = await HttpServer.bind('localhost', 0);
  server.listen((req) async {
    final body = await req.fold<int>(0, (n, c) => n + c.length);
    req.response.headers.contentType = ContentType.json;
    if (req.uri.path == '/missing') req.response.statusCode = 404;
    req.response.write('{"path":"${req.uri.path}","bytes":$body}');
    await req.response.close();
  });
  final url = 'http://localhost:${server.port}';

  print(await Http.get('$url/hello').json().$('path').or('?'));
  print(await Http.post('$url/echo', body: Body.json({'a': 1})).json().$('bytes').or(0));
  final res = await Http.get('$url/missing');
  print('missing: ${res.status()} ok=${res.ok()}');
  await res.close();
  try {
    await Http.get('$url/missing', check: true);
  } on HttpException catch (e) {
    print('check: ${e.message.split(' GET').first}');
  }
  await server.close(force: true);
}

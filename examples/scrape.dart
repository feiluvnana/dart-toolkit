/// scrape: a polite crawl: a queue, limits per host, retries; handlers route with `follow` and `emit` records.
/// A loopback site keeps this offline (point it at any URL instead).
///
/// `dart run examples/scrape.dart`
library;

import 'dart:io' show HttpServer, ContentType;

import 'package:dart_toolkit/scrape.dart';

Future<void> listing(Visit<String> v) async => v.follow((await v.html()).$('a.item').attrs('href'), album);

Future<void> album(Visit<String> v) async => v.emit((await v.html()).$('h1').text());

Future<void> main() async {
  final server = await HttpServer.bind('localhost', 0);
  server.listen((req) async {
    req.response.headers.contentType = ContentType.html;
    req.response.write(
      req.uri.path == '/'
          ? '<a class=item href="/a">A</a><a class=item href="/b">B</a>'
          : '<h1>Album ${req.uri.path.substring(1)}</h1>',
    );
    await req.response.close();
  });
  final base = 'http://localhost:${server.port}/';

  print(await Scrape.crawl<String>([base], listing, delay: Duration(milliseconds: 20)).toList());
  await server.close(force: true);
}

/// scrape + html + json + fs: crawl a listing, follow each item, emit records, store them as JSON.
/// A loopback shop keeps this offline; swap in a real site and selectors.
///
/// `dart run examples/combo_scrape_to_json.dart`
library;

import 'dart:io' show Directory, HttpServer, ContentType;

import 'package:dart_toolkit/fs.dart';
import 'package:dart_toolkit/json.dart';
import 'package:dart_toolkit/scrape.dart';

typedef Product = ({String name, double price, String url});

Future<void> listing(Visit<Product> v) async {
  final doc = await v.html();
  v.follow(doc.$('a.product').attrs('href'), product).follow(doc.$('a.next').attrs('href'), listing);
}

Future<void> product(Visit<Product> v) async {
  final doc = await v.html();
  v.emit((name: doc.$('h1').text(), price: double.parse(doc.$('.price').text().substring(1)), url: v.url()));
}

Future<void> main() async {
  final server = await HttpServer.bind('localhost', 0);
  server.listen((req) async {
    final path = req.uri.path;
    req.response.headers.contentType = ContentType.html;
    req.response.write(switch (path) {
      '/' => '<a class=product href="/p1">A</a><a class=product href="/p2">B</a><a class=next href="/page2">next</a>',
      '/page2' => '<a class=product href="/p3">C</a>',
      _ => '<h1>Product ${path.substring(2)}</h1><span class=price>\$${path.substring(2)}.50</span>',
    });
    await req.response.close();
  });

  final items = await Scrape.crawl<Product>(['http://localhost:${server.port}/'], listing).toList();
  final out = Fs.dir(Directory.systemTemp.createTempSync('combo_scrape').path).file('products.json');
  await out.write(
    Json.encode([
      for (final p in items) {'name': p.name, 'price': p.price},
    ], pretty: true),
  );
  final saved = await out.json();
  print('${saved.length} products, total ${saved.$('*.price').asList<double>().fold(0.0, (a, b) => a + b)}');
  await out.parent().delete();
  await server.close(force: true);
}

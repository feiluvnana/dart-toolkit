import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  Logger.info('Starting Web Scraper Example');

  // Scraping pipeline with typed ScrapeContext<T>
  final stream = 'https://news.ycombinator.com'.url.scrape<({String title, String? link})>((ctx) {
    for (final row in ctx.response.html().$('tr.athing')) {
      final titleSpan = row.$('.titleline > a').firstOrNull;
      if (titleSpan != null) {
        ctx.emit((title: titleSpan.text, link: titleSpan.attr('href')));
      }
    }
  });

  await for (final item in stream.take(5)) {
    Logger.ok('${item.title} -> ${item.link}');
  }
}

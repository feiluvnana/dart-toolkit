import 'package:dart_toolkit/cli/cli.dart';
import 'package:dart_toolkit/core/core.dart';
import 'package:dart_toolkit/html/html.dart';
import 'package:dart_toolkit/http/http.dart';

typedef Story = ({String title, Uri link});

void main() async {
  Logger.info('Starting Web Scraper Example');

  // One client for every request inside the session, closed when it returns.
  await Http.session(() async {
    // Every decision is the handler's: what to emit, what to follow, when to stop.
    // follow() stays on news.ycombinator.com by itself; a failed page is a Left, not a crash.
    final stories = 'https://news.ycombinator.com'.url.scrape<Story>((ctx) {
      final html = ctx.response.html();
      for (final row in html.$('tr.athing')) {
        if (row.$('.titleline > a').firstOrNull case final a?) {
          ctx.emit((title: a.text, link: ctx.resolve(a.attr('href')!)));
        }
      }
      for (final a in html.$('a[href]')) {
        ctx.follow(a.attr('href')!);
      }
      if (ctx.pages >= 5) ctx.stop();
    });

    await for (final story in stories) {
      switch (story) {
        case Right(:final value):
          Logger.ok('${value.title} -> ${value.link}');
        case Left(:final value):
          Logger.warn('$value');
      }
    }
  });
}

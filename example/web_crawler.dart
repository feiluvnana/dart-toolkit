import 'package:dart_toolkit/cli/cli.dart';
import 'package:dart_toolkit/core/core.dart';
import 'package:dart_toolkit/html/html.dart';
import 'package:dart_toolkit/http/http.dart';

typedef Story = ({String title, Uri link});

void main() async {
  Logger.info('Starting Web Scraper Example');

  // One client for every request inside the session, closed when it returns.
  await Http.session(() async {
    final front = await 'https://news.ycombinator.com'.url.get();
    if (!front.ok) await die('Hacker News returned ${front.statusCode}');

    // ctx.url is where the response came from; ctx.resolve uses it, as follow() does.
    final stream = 'https://news.ycombinator.com'.url.scrape<Story>((ctx) {
      for (final row in ctx.response.html().$('tr.athing')) {
        if (row.$('.titleline > a').firstOrNull?.attr('href') case final href?) {
          ctx.emit((title: row.$('.titleline > a').first.text, link: ctx.resolve(href)));
        }
      }
    });

    await for (final story in stream.take(5)) {
      Logger.ok('${story.title} -> ${story.link}');
    }
  });
}

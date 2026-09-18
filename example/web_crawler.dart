import 'package:dart_toolkit/cli/cli.dart';
import 'package:dart_toolkit/core/core.dart';
import 'package:dart_toolkit/html/html.dart';
import 'package:dart_toolkit/http/http.dart';
import 'package:dart_toolkit/util/util.dart';

typedef Story = ({String title, Uri link});

void main() async {
  Logger.info('Starting Web Scraper Example');

  // One client for every request inside the session, closed when it returns.
  await Http.session(() async {
    // A crawl is a chain: limits, then hooks. It is also the stream of what the hooks emit.
    // follow() stays on news.ycombinator.com by itself; a failed page is a Left, not a crash.
    final stories = 'https://news.ycombinator.com'.url
        .scrape<Story>()
        .concurrency(8)
        .delay(200.ms)
        .maxPages(5)
        .onRequest((ctx) => ctx.request.headers['accept-language'] = 'en')
        .onResponse((ctx) {
          final html = ctx.response.html();
          for (final row in html.$('tr.athing')) {
            if (row.$('.titleline > a').firstOrNull case final a?) {
              ctx.emit((title: a.text, link: ctx.resolve(a.attr('href')!)));
            }
          }
          for (final a in html.$('a[href]')) {
            ctx.follow(a.attr('href')!);
          }
        })
        .onError((ctx) => Logger.warn('${ctx.failure}'))
        .onFinish((summary) => Logger.info('$summary'));

    await for (final story in stories.rights) {
      Logger.ok('${story.title} -> ${story.link}');
    }
  });
}

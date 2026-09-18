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
    // A crawl is a chain of hooks, and the stream of what they emit. Every setting is on
    // onInit's context; follow() stays on news.ycombinator.com by itself; a failed page is a
    // Left, not a crash.
    final stories = 'https://news.ycombinator.com'.url
        .scrape<Story>()
        .onInit((ctx) {
          ctx.concurrency = 8;
          ctx.delay = 200.ms;
          ctx.pages = 5;
        })
        .onRequest((ctx) => ctx.request.headers['accept-language'] = 'en')
        .onResponse((ctx) {
          final html = ctx.response.html;
          for (final row in html.$('tr.athing')) {
            final a = row.$('.titleline > a');
            if (a.attr('href') case final href?) ctx.emit((title: a.text, link: ctx.resolve(href)));
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

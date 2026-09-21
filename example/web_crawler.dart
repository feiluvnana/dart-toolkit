import 'package:dart_toolkit/dart_toolkit.dart';

/// Scraping, from the one-line case to a bounded crawl. Needs network.
typedef Story = ({int rank, String title, Uri link, String site});

Future<void> main() async {
  // One client for every request inside the session, with a timeout and default headers, and
  // closed when the session returns. Without this each call would build its own client and
  // throw away the connection.
  await Http.session(timeout: 20.s, headers: {'user-agent': 'dart-toolkit example'}, () async {
    Console.rule('One request, when one is all you need');

    // Fetch and parse in a single call. `json()`, `html()` and `xml()` each throw unless the
    // status is 2xx, so an error page cannot quietly match nothing.
    final item = await 'https://hacker-news.firebaseio.com/v0/item/1.json'.url.json();
    Logger.info('item 1: "${item['title'].to<String>()}" by ${item['by'].to<String>()}');

    // Or keep the response and decide for yourself.
    final res = await 'https://news.ycombinator.com'.url.get();
    Logger.info('GET / → ${res.statusCode}, ${res.bytes.length} bytes, ok=${res.isOk}');

    Console.rule('Querying a page');

    final page = res.html;
    // `$` is CSS and answers with a list whose `text` and `attr` speak for the first match.
    Logger.info('title: ${page.$('title').text}');
    Logger.info('first story: ${page.$('.titleline > a').text}');
    Logger.info('links on the page: ${page.$('a[href]').length}');

    // `$x` is XPath, for the questions CSS cannot ask — here, a link chosen by its own text.
    final more = page.$x('//a[text()="More"]/@href').texts;
    Logger.info('the "More" link: ${more.join()}');

    Console.rule('A crawl: five hooks and a stream');

    final stories = 'https://news.ycombinator.com'.url
        .scrape<Story>()
        // Every crawl-wide setting lives here, once, on the context.
        .onInit((ctx) {
          ctx.concurrency = 4;
          ctx.perHost = 2;
          ctx.delay = 300.ms; // polite: one request per host per 300 ms
          ctx.pages = 3; // stop after three handled pages
          ctx.retries = 1;
        })
        // Anything per request. `ctx.skip()` drops one without sending it.
        .onRequest((ctx) {
          if (ctx.url.path.contains('/login')) return ctx.skip();
          ctx.request.headers['accept-language'] = 'en';
        })
        // Runs on every 2xx. Emit what you came for, follow what is worth following.
        .onResponse((ctx) {
          final html = ctx.response.html;
          for (final row in html.$('tr.athing')) {
            final link = row.$('.titleline > a');
            if (link.attr('href') case final href?) {
              ctx.emit((
                rank: int.tryParse(row.$('.rank').text.replaceAll('.', '')) ?? 0,
                title: link.text,
                link: ctx.resolve(href),
                site: row.$('.sitestr').isEmpty ? '—' : row.$('.sitestr').text,
              ));
            }
          }
          // `follow` returns whether it was scheduled: out of scope, already seen, or too
          // deep all answer false. Only the next page is worth having here.
          if (html.$x('//a[text()="More"]/@href').texts.firstOrNull case final next?) {
            ctx.follow(next);
          }
        })
        // The engine has already given up by the time this runs. Acting on it — retry,
        // ignore, emit, follow — keeps the failure off the stream; doing nothing lets it
        // through as a Left.
        .onError((ctx) {
          Logger.warn('${ctx.failure}');
          if (ctx.failure case RequestFailed() when ctx.attempt < 3) return ctx.retry(after: 1.s);
          ctx.ignore();
        })
        .onFinish((summary) => Logger.info('$summary'));

    // The crawl is a Stream<Either<ScrapeFailure, Story>>, so `rights`, `lefts`, `unwrap`,
    // `take` and `cancelWith` all apply. Nothing is sent until it is listened to.
    final collected = await stories.rights.toList();
    Logger.ok('${collected.length} stories');

    // Which is collection's problem now, not http's. `Table.records` builds rows from any
    // objects; `.table` itself is the conversion on documents and HTML, not on plain maps.
    Table.records(
      collected.sequence.sortedBy((s) => s.rank).take(8),
      (s) => {'#': s.rank, 'title': s.title, 'site': s.site},
    ).show();

    final busiest = collected.sequence.countBy((s) => s.site).sortedByValue(descending: true).take(3);
    Logger.info('most linked: ${busiest.map((p) => '${p.$1} (${p.$2})').join(', ')}');

    Console.rule('Downloading, with progress');

    final into = Path.temp / 'toolkit_crawl_demo';
    try {
      // A download is atomic: it writes `<name>.part` and renames on success, verifies
      // Content-Length, and resumes an interrupted transfer on the next attempt.
      final last = await {
        'https://news.ycombinator.com/favicon.ico'.url: into / 'favicon.ico',
        'https://news.ycombinator.com/y18.svg'.url: into / 'y18.svg',
      }.downloadAll(concurrency: 2).show(message: 'Fetching assets', done: 'Assets fetched');

      Logger.ok('${last?.written ?? 0} written of ${last?.total ?? 0}');
      await for (final f in into.files()) {
        Logger.info('${f.name}  ${await f.size()} B  sha256 ${(await f.sha256()).substring(0, 12)}…');
      }
    } finally {
      await into.delete(recursive: true);
    }
  });
}

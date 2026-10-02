/// `books` — public-domain ebooks from Standard Ebooks, by title.
///
///   dart run bin/books.dart "pride and prejudice" frankenstein
///   dart run bin/books.dart dracula -f kepub -o ~/shelf
///   dart run bin/books.dart "moby dick" --browser        # rendered and clicked in Chrome
///
/// Two routes to one file. The plain one reads the pages and downloads every book at once. The
/// browser one does what a person does — open the page, click the link — and that is not the
/// same request: a Standard Ebooks download link answers with a thank-you page whose
/// `<meta refresh>` starts the real transfer, which only a browser follows.
library;

import 'package:dart_toolkit/chrome.dart';
import 'package:dart_toolkit/dart_toolkit.dart';

/// What a book page offers, by the end of each link's file name.
enum Format {
  epub('.epub'),
  kepub('.kepub.epub'),
  azw3('.azw3'),
  advanced('_advanced.epub');

  final String suffix;
  const Format(this.suffix);
}

final titles = Arg.text('titles', 'One search per book').many().required();
final format = Opt.among('format', Format.values).abbr('f').or(Format.epub);
final into = Opt.text('to', 'Where the files land').abbr('o').or('books');
final browser = Opt.flag('browser', 'Click each download in Chrome').abbr('b');
final proxy = Opt.text('proxy', 'Send everything through this proxy').env('HTTPS_PROXY');

final site = 'https://standardebooks.org'.url;

void main(List<String> args) => Cli(
  description: 'Download public-domain ebooks from Standard Ebooks.',
  values: [titles, format, into, browser, proxy],
  handler: run,
).run(args);

Future<void> run(CliContext ctx) async {
  final dir = ctx(into).path;
  final via = ctx(proxy)?.url;
  final client = ctx(browser) ? await ChromeClient.launch(proxy: via) : IoClient(proxy: via);
  try {
    // One second between two requests to the site, and a flaky answer is asked again.
    await Http.scope(client: client, retries: 2, delay: 1.s, () async {
      final settled = await ctx(titles).parallelize((title) => link(title, ctx(format))).toList();
      settled.lefts.forEach(Console.warn);
      final found = settled.rights;
      if (found.isEmpty) throw 'nothing found';
      if (client case final ChromeClient chrome) {
        for (final (:page, :file) in found) {
          final saved = await Console.spin(
            file,
            () => chrome.page(page, (tab) => tab.waitForDownload(() => tab.click('a[href\$="$file"]'), to: dir)),
          );
          if (saved == null) Console.warn('$file never started');
        }
      } else {
        // The link itself is the thank-you page; `?source=download` is where it refreshes to.
        await {
          for (final (:page, :file) in found)
            page.resolve('downloads/$file').replace(query: 'source=download'): dir / file,
        }.download().show(message: 'Downloading', done: 'Saved ${found.length} to $dir');
      }
    });
  } finally {
    await client.close();
  }
}

/// The first book [title] finds, and the file name its [format] link points at.
Future<({Uri page, String file})> link(String title, Format format) async {
  final results = await (site / 'ebooks').withQuery({'query': title}).get().html;
  final about = results.$('li[typeof="schema:Book"]').attrOrNull('about');
  if (about == null) throw 'no book matches "$title"';
  final page = site.resolve('$about/');
  final links = (await page.get().html).$('a[property="schema:contentUrl"][href\$="${format.suffix}"]');
  final files = [for (final href in links.attrs('href')) href.split('/').last]..sort((a, b) => a.length - b.length);
  // `.epub` also ends the kepub and the advanced epub; the plain one is the shortest.
  if (files.isEmpty) throw '"$title" has no ${format.name}';
  Console.info('${about.split('/').skip(2).join(' / ')} → ${files.first}');
  return (page: page, file: files.first);
}

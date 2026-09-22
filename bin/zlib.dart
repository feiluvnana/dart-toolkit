/// `zlib` — one book from z-library, by its id, through a proxy it finds for itself.
///
///   dart run bin/zlib.dart 9KQ4bZjMr0
///   dart run bin/zlib.dart 9KQ4bZjMr0 -f pdf -o ~/shelf
///   dart run bin/zlib.dart 9KQ4bZjMr0 --direct        # straight out from here
///
/// The browser is this program's own, with a profile it keeps: log in once by hand and every
/// run after it is that session. It has to own the browser, because the file is fetched by
/// Chrome and a browser only takes the route it was started with — so changing proxy means
/// starting another one, which is exactly what rotating does.
library;

import 'package:dart_toolkit/dart_toolkit.dart';

/// The formats a book page may offer. It has no format control: it carries one download
/// link per format it holds, labelled with it, so a format is chosen by picking a link.
enum Format { epub, pdf, mobi, azw3, fb2, txt, djvu, rtf, lit }

final id = Arg.text('id', description: 'The book id, as it appears in its URL').required();
final format = Opt.among('format', Format.values, abbr: 'f').or(Format.epub);
final into = Opt.text('to', abbr: 'o', description: 'Where the file lands').or('books');
final direct = Opt.flag('direct', abbr: 'd', description: 'Skip the proxies and go out from here');
final tries = Opt.number('tries', abbr: 't', description: 'Proxies to rotate through').or(5);

const site = 'https://z-library.biz';

/// ProxyScrape's free list, asked for the only protocol this program can use.
///
/// Filtered at the source rather than here: `protocol=http` is half a megabyte where the whole
/// list is one and a half, and every record it returns is one the service has just seen alive.
/// Each also says whether it does SSL and how steady it has been, which is what turns picking
/// a proxy from a guess into a sort.
const list =
    'https://api.proxyscrape.com/v4/free-proxy-list/get'
    '?request=display_proxies&proxy_format=protocolipport&format=json&protocol=http';

/// What a proxy is tried against — a neutral host, not the site.
///
/// The one thing worth testing in advance is whether a proxy will `CONNECT` at all, which is
/// what HTTPS needs and what most of a free list will not do. Testing against the site itself
/// means a few hundred requests at it before a single book is asked for, which is both rude
/// and a good way to be refused; whether *this* site will talk to *this* proxy is what the
/// rotation below is for.
const probe = 'https://example.com/';

/// The browser's own directory, so the login survives a rotation and the next run.
final profile = Path.home / '.dart_toolkit' / 'zlib';

void main(List<String> args) => Cli(
  name: 'zlib',
  description: 'Download a book from z-library by its id.',
  args: [id],
  options: [format, into, tries, direct],
  handler: run,
).run(args);

Future<void> run(CliContext ctx) async {
  final routes = ctx(direct) ? <Uri?>[null] : [...await candidates(ctx(tries)), null];

  for (final (attempt, proxy) in routes.indexed) {
    final how = proxy == null ? 'directly' : 'through ${proxy.host}:${proxy.port}';
    Console.info('${attempt + 1}/${routes.length}: $how');

    switch (await attempt_(ctx, proxy)) {
      case Right(value: final file):
        Console.ok('saved ${file.name} (${await file.size()} bytes) $how');
        return;
      // A refusal is this route's answer, not the book's: the next one may be told otherwise.
      case Left(value: final why):
        Console.warn('$how: $why');
    }
  }
  await Lifecycle.exit('every route was refused');
}

/// One whole attempt down one route: a browser, a page, a click, a file.
///
/// The browser is started per attempt because that is the only moment its proxy can be set,
/// and torn down at the end of one whether it worked or not — two Chromes cannot share the
/// profile, and the profile is what carries the login.
Future<Either<String, Path>> attempt_(CliContext ctx, Uri? proxy) async {
  final chrome = await ChromeClient.launch(
    profile: profile,
    proxy: proxy,
    headless: false,
    tabs: 1,
    wait: ChromeWait.dom,
  );
  final release = Lifecycle.onExit(chrome.close);
  try {
    final page = await chrome.open('$site/book/${ctx(id)}'.url);

    // The page builds itself, so no lifecycle event is when it is ready — the button appearing
    // is. A mutation observer returns the moment it arrives, and running out of time is an
    // answer rather than an exception, so a route that shows no button says so and is dropped.
    if (!await page.waitFor('.addDownloadedBook')) {
      return Left('no download link (${page.url})');
    }
    Console.info(await page.text('h1') ?? ctx(id));

    // Mark the link for the format asked for, so the click has a selector, and answer with
    // every format the page does offer for the message when it has none.
    final want = ctx(format).name;
    final offered = await page.eval('''(() => {
  const links = [...document.querySelectorAll('a.addDownloadedBook, a[href*="/dl/"]')];
  const hit = links.find((a) => a.textContent.toLowerCase().includes('$want'));
  if (hit) hit.dataset.tkPick = '1';
  return links.map((a) => a.textContent.trim().split(',')[0].toLowerCase()).join(', ');
})()''');

    // A format this book does not have is the book's answer and no proxy will change it.
    if (!await page.has('[data-tk-pick]')) {
      if (offered != null && '$offered'.isNotEmpty) {
        await Lifecycle.exit('no $want here; ${ctx(id)} has $offered');
      }
      return const Left('the page offered nothing to download');
    }

    // The click, not the link. A `/dl/` URL's last segment is an opaque id, so downloading it
    // directly writes a file with no name and no extension; the name the site gave it is in
    // `content-disposition`, which only the browser reads.
    final file = await page.downloading(() => page.click('[data-tk-pick]'), to: ctx(into).path);
    return file == null ? const Left('the download never started') : Right(file);
  } on ClientException catch (e) {
    return Left('$e');
  } finally {
    release();
    await chrome.close();
  }
}

/// Up to [wanted] proxies from the list that answer, best-first, each already proven to reach
/// the site — so a rotation moves between routes that worked a moment ago rather than guesses.
Future<List<Uri>> candidates(int wanted) async {
  final all = await catalogue();
  if (all.isEmpty) {
    Console.warn('no usable proxies in the list');
    return const [];
  }

  // One wide wave rather than many narrow ones: these are sockets, and the ones that fail do
  // it by timing out, so a wave costs about what its slowest member does. Half of this list
  // answers — 52 of 100 when it was measured, against 5 of 100 for a list that says nothing
  // about itself — so one wave of fifty is already more routes than a rotation will use.
  final found = <Uri>[];
  var tested = 0;
  await Console.spin('Testing proxies', () async {
    for (final wave in all.take(150).sequence.chunk(50)) {
      tested += wave.length;
      found.addAll((await wave.parallelize(reaches, concurrency: wave.length)).rights);
      if (found.length >= wanted) return;
    }
  }, done: 'Proxies tested');

  Console.info('${found.length} of $tested proxies answered');
  return found.take(wanted).toList();
}

/// Every proxy in the list worth trying, steadiest first.
///
/// Two filters and a sort. The protocol has to be HTTP, which the URL above asks for: Chrome
/// speaks SOCKS and `dart:io` does not, so a SOCKS proxy would carry the pages while the file
/// — the thing actually being fetched — went straight out. `ssl` has to be true, because an
/// HTTPS target means asking the proxy to `CONNECT` and most will not: the flagged ones answer
/// about half the time and the rest about one in seven. Then by uptime, so the steadiest is
/// tried first rather than whichever the shuffle happened to put there.
Future<List<Uri>> catalogue() async {
  await profile.parent.mkdir();
  final cache = profile.parent / 'proxies.json';

  // Which proxies are alive is the freshest thing about the list, so an hour, not a day.
  final age = await cache.exists() ? DateTime.now().difference(await cache.modified()) : null;
  if (age == null || age > 1.h) {
    await Console.spin(
      'Fetching the proxy list',
      () => cache.download(list.url, overwrite: true).drain<void>(),
      done: 'Proxy list is current',
    );
  }

  final rows = [
    for (final entry in (await cache.readText()).json['proxies'].list)
      if (entry['ssl'].to<bool>() ?? false) entry,
  ]..sort((a, b) => (b['uptime'].to<num>() ?? 0).compareTo(a['uptime'].to<num>() ?? 0));

  return [for (final row in rows) ?row['proxy'].to<String>()?.url];
}

/// [proxy] if it will tunnel, and a throw otherwise — which is what makes `parallelize` settle
/// it into a `Left` and lets every `Right` be a route worth trying.
///
/// The list already says which proxies tunnel and how steady they have been, so this is a
/// check rather than a search: it asks the ones that claim to whether they still do. Twelve
/// seconds rather than five because a free proxy that answers at all is usually slow, and
/// cutting them off at five threw away nearly all of the ones that work.
Future<Uri> reaches(Uri proxy) async {
  final client = IoClient(proxy: proxy, connectTimeout: 12.s);
  try {
    final res = await client.head(probe.url).timeout(12.s);
    if (res.statusCode >= 500) throw ClientException('answered ${res.statusCode}', proxy);
    return proxy;
  } finally {
    await client.close();
  }
}

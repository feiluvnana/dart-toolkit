import 'package:dart_toolkit/dart_toolkit.dart';

/// The formats a book page may offer. It has no format control: it carries one download
/// link per format it holds, labelled with it, so a format is chosen by picking a link.
enum Format { epub, pdf, mobi, azw3, fb2, txt, djvu, rtf, lit }

final id = Arg.text('id', description: 'The book id, as it appears in its URL').required();
final format = Opt.among('format', Format.values, abbr: 'f').or(Format.epub);
final into = Opt.text('to', abbr: 'o', description: 'Where the file lands').or('books');

/// Downloads one book by its id: `zlib 9KQ4bZjMr0 -f pdf -o ~/shelf`.
void main(List<String> args) => Cli(
  name: 'zlib',
  description: 'Download a book from z-library by its id.',
  args: [id],
  options: [format, into],
  handler: fetch,
).run(args);

Future<void> fetch(CliContext ctx) async {
  final book = ctx(id);
  final want = ctx(format).name;

  // `connect`, not `launch`: the browser and its profile outlive the run, so a session
  // logged into by hand once is still the session on every run after it.
  final chrome = await ChromeClient.connect(wait: ChromeWait.dom);
  Lifecycle.onExit(chrome.close);

  final page = await chrome.open('https://z-library.biz/book/$book'.url);

  // The page builds itself, so no lifecycle event is when it is ready — the button appearing
  // is. Waiting for the thing wanted is both surer and faster than waiting for the network to
  // go quiet: a mutation observer returns the moment it arrives, and running out of time is an
  // answer rather than an exception, so a page that never has one says so.
  if (!await page.waitFor('.addDownloadedBook')) {
    await Lifecycle.exit('no download link at $book; the page is ${page.url}');
  }

  Console.info(await page.text('h1') ?? book);

  // Mark the link for the format that was asked for, so the click has a selector, and
  // answer with every format the page does offer for the message when it has none.
  final offered = await page.eval('''(() => {
  const links = [...document.querySelectorAll('a.addDownloadedBook, a[href*="/dl/"]')];
  const hit = links.find((a) => a.textContent.toLowerCase().includes('$want'));
  if (hit) hit.dataset.tkPick = '1';
  return links.map((a) => a.textContent.trim().split(',')[0].toLowerCase()).join(', ');
})()''');

  if (!await page.has('[data-tk-pick]')) {
    await Lifecycle.exit(
      offered == '' || offered == null ? 'nothing to download at $book' : 'no $want here; $book has $offered',
    );
  }

  // The click, not the link. A `/dl/` URL's last segment is an opaque id, so downloading it
  // directly writes a file with no name and no extension; the name the site gave it is in
  // `content-disposition`, which only the browser reads.
  final file = await page.downloading(() => page.click('[data-tk-pick]'), to: ctx(into).path);
  if (file == null) await Lifecycle.exit('nothing downloaded; the page is ${page.url}');

  Console.ok('saved ${file.name} (${await file.size()} bytes)');
  await page.close();
}

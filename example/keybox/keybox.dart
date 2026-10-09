import 'package:dart_toolkit/archive.dart';
import 'package:dart_toolkit/cli.dart';
import 'package:dart_toolkit/scrape.dart';

const keyBase = 'https://key.visualarts.gr.jp/key20th/';
const khinsider = 'https://downloads.khinsider.com/game-soundtracks/album/key-box-for-two-decades-2019';
const baseName = 'Key BOX -for two decades- (2019)';
const formats = ['mp3' /*, 'flac'*/];

/// The patterns, built once: every one of them is read inside a loop over a page.
final discTitle = RegExp(r'DISC\.(\d+)');
final discLabel = RegExp(r'DISC(\d+)');
final trackLine = RegExp(r'^(\d+)\.(.*)$');
final hrefDisc = RegExp(r'/(\d+)-');
final hrefTrack = RegExp(r'-(\d+)\.');
final digits = RegExp(r'\d+');

/// One file of the box: where it comes from, and where it goes.
typedef Asset = ({Uri url, Path to});

/// Downloads the whole box set (artwork, documents, every track in every format) and zips it.
/// A rerun downloads only what is new, and the zip is rebuilt only once every file is there.
void main(List<String> args) => Cli(
  'Key BOX Scraper & Downloader',
  version: '0.1.0',
  handler: (ctx) => Http.scope(
    run,
    timeout: 60.s,
    retry: Retry(3),
    perHost: 4,
    headers: {
      'accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
      'accept-language': 'en-US,en;q=0.9,vi;q=0.8',
      'cache-control': 'max-age=0',
      'priority': 'u=0, i',
      'upgrade-insecure-requests': '1',
    },
  ),
).run(args);

Future<void> run() async {
  final began = Clock.current.elapsed;
  final base = Path.here.parent / baseName;
  final site = keyBase.url;
  final artwork = <Asset>[];
  final discNames = <int, Path>{};
  final tracks = <int, Map<int, Path>>{};

  // Every asset is one href and one place under the box, so the lists below carry only the
  // part that differs. An absolute href resolves to itself, which is how the two off-site
  // scans join the same list; `images` adds the one prefix the bulk of them share.
  void grab(String href, Path to) => artwork.add((url: site / href, to: to));
  void images(String into, List<String> names) {
    for (final name in names) {
      grab('common/image/${name.url.name}', base / into / name);
    }
  }

  // Stage 1: Official metadata & images, one spinner per page, each ending with what it found.
  Console.rule('Scraping official album metadata and artworks');
  await Task.run('key_box.html', (_) async {
    final doc = await (site / 'key_box.html').get().html;
    for (final li in doc.$('.key_cd_track_box ul li')) {
      final title = li.$('.track_disc_title').first.text;
      final d = int.parse(discTitle.firstMatch(title)![1]!);
      discNames[d] = title.filename;
      tracks[d] = {
        for (final line in li.$('.track_disc_text_style1').first.lines)
          if (trackLine.firstMatch(line) case final m?)
            int.parse(m[1]!): (d == 22 && m[1] == '13') ? '小さなてのひら'.filename : m[2]!.filename,
      };
    }

    for (final e in doc.$('.key_cd_artworks_box')) {
      final href = e.$('a').first.attr('href');
      if (discLabel.firstMatch(e.text)?[1] case final d?) {
        grab(href, base / discNames[int.parse(d)]! / (site / href).name);
      } else if (e.text.contains('ALL')) {
        grab(href, base / 'Others/KeyBOX' / (site / href).name);
      }
    }
  }).show('Reading key_box.html', done: 'Tracklist and disc artworks');
  Console.info('${discNames.length} discs, ${tracks.values.fold(0, (n, t) => n + t.length)} tracks');

  final before = artwork.length;
  grab('common/album_jacket/keybox_image.png', base / 'Others/KeyBOX/keybox_image.png');
  const jetta = 'https://jetta.vgmtreasurechest.com/soundtracks/key-box-for-two-decades-2019';
  grab('$jetta/00%20Contents.jpg', base / 'Others/KeyBOX/00_Contents.jpg');
  grab('$jetta/01%20Box%20sample.png', base / 'Others/KeyBOX/01_Box_sample.png');

  images('Others/KeyBOX', [
    '20th_box_image.jpg',
    'key_box_main_image.png',
    'sp_key_box_main_image.png',
    'key_box_bg.jpg',
    'key_box_onsale_title3.jpg',
    'sp_20th_banner_keybox.png',
  ]);
  images('Others/Key 20th Anniversary', [
    '20th_main_image.jpg',
    '20th_main_bg.jpg',
    '20th_top_main_banner_1.png',
    '20th_menu_logo.png',
    'sp_20th_top_title.png',
    'sp_20th_main_image_1.jpg',
    'sp_20th_main_image_2.jpg',
    'sp_20th_main_image_3.jpg',
  ]);
  images('Others/Events & Topics', [
    'Stamp Rally/key20th_stamp_poster_1.jpg',
    'Stamp Rally/key20th_stamp_poster_1_a.jpg',
    'movie_image_0712.jpg',
    'history_image_50.jpg',
    'topics_image_20191217_2.jpg',
    for (var i = 1; i <= 8; i++) 'General Election/key_election_$i.jpg',
    for (final name in 'kai tanaka minami na-ga suzukikeiko sakurai kohara orito suzuki yurika'.split(' '))
      'Live Streams/profile_$name.jpg',
  ]);

  await Task.run('message.html', (_) async {
    final msgDoc = await (site / 'message.html').get().html;
    const categories = ['Anime Staff', 'Voice Cast', 'Guest Tributes', 'Key Staff & Creators'];
    for (final (i, box) in msgDoc.$('.message_white_box').take(4).indexed) {
      for (final (n, a) in box.$('a[href*="message_"]').indexed) {
        final href = a.attr('href');
        final tag = href.contains('wfs') ? 'WFS_' : (href.contains('cygames') ? 'Cygames_' : '');
        final pfx = '${n + 1}'.padLeft(2, '0');
        final name = (a.attributes['title'] ?? a.text.replaceAll('[New Message]', '')).filename;
        grab(href, base / 'Others/Messages & Tributes' / categories[i] / '$tag${pfx}_$name.jpg');
      }
    }
  }).show('Reading message.html', done: 'Messages and tributes');
  await Task.run('topics.html', (_) async {
    final topicsDoc = await (site / 'topics.html').get().html;
    for (final img in topicsDoc.$('.topics_box img')) {
      final src = img.attr('src');
      grab(src, base / 'Others/Events & Topics' / (site / src).name);
    }
  }).show('Reading topics.html', done: 'Event and topic images');
  Console.info('${artwork.length} artworks and documents (${artwork.length - before} beyond the discs)');

  // Stage 2: Track links and downloads, merged: tracks resolve while artwork transfers.
  Console.rule('Resolving tracks and downloading assets');
  final songs = khinsider.url.crawl<Asset>(
    onResponse: (ctx) async {
      for (final tr in ctx.html.$('#songlist tr')) {
        final tds = tr.$('td').toList();
        if (tds.length < 4) continue;
        final href = tds[3].$('a').first.attr('href');
        // The numbers come from the link where it has them, and from the columns where it does not.
        final d = int.parse(hrefDisc.firstMatch(href)?[1] ?? digits.firstMatch(tds[1].text)![0]!);
        final t = int.parse(hrefTrack.firstMatch(href)?[1] ?? digits.firstMatch(tds[2].text)![0]!);
        final title = tracks[d]?[t] ?? tds[3].text.filename;
        // A song whose files are all here costs no request.
        final missing = {
          for (final ext in formats)
            if (base / discNames[d]! / ext / '$t. $title.$ext' case final to when !await to.exists()) ext: to,
        };
        if (missing.isEmpty) continue;

        ctx.follow(
          ctx.resolve(href),
          hooks: Hooks(
            onResponse: (song) {
              for (final MapEntry(key: ext, value: to) in missing.entries) {
                // A song page need not carry every format; one that does not is skipped.
                if (song.html.$('a[href*=".$ext"]').firstOrNull?.link case final url?) song.emit((url: url, to: to));
              }
            },
          ),
        );
      }
    },
  );
  songs.progress('Song pages');

  final downloading = Batch.merge([artwork.parallelize(_download), songs.items.parallelize(_download)]);
  final saved = await downloading.show('Downloading', done: 'All assets downloaded.');
  // A song page that failed has no download to fail: the crawl says so itself.
  await songs;

  // Stage 3: Archive; built beside the old zip and renamed over it.
  Console.rule('Creating zip archive');
  final zip = await base
      .archive(to: '$base.zip', conflict: Conflict.overwrite)
      .show('Compressing', done: 'Archive created.');

  final fresh = (await downloading.settled).whereType<Done<Asset, Path>>().where((d) => d.fresh).length;
  Table.cells(
    ['Result', 'Value'],
    [
      ['Discs', discNames.length],
      ['Assets', saved.length],
      ['Downloaded now', fresh],
      ['Archive', '${zip.name} (${(await zip.size()).humanBytes})'],
      ['Time', (Clock.current.elapsed - began).humanized],
    ],
  ).show();
}

Task<Path> _download(Asset asset) => asset.url.download(to: asset.to);
